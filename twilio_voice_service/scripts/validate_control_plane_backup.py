#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import json
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from backup_utils import (  # noqa: E402
    CONTROL_PLANE_REQUIRED_TABLES,
    collect_table_metrics,
    existing_tables,
)

SQLITE_TIMEOUT_SECONDS = 30.0
SQLITE_BUSY_TIMEOUT_MS = 30000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate a Vicall control-plane backup DB.")
    parser.add_argument("backup_path", help="Path to a .sqlite3 or .sqlite3.gz backup artifact.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print the JSON result.")
    return parser.parse_args()


def open_sqlite_connection(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(str(path), timeout=SQLITE_TIMEOUT_SECONDS)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
    return connection


def validate_backup_database(path: Path) -> dict[str, object]:
    with open_sqlite_connection(path) as conn:
        quick_check = str(conn.execute("PRAGMA quick_check").fetchone()[0])
        if quick_check.lower() != "ok":
            raise RuntimeError(f"SQLite quick_check failed: {quick_check}")

        known_tables = existing_tables(conn)
        missing_tables = sorted(table for table in CONTROL_PLANE_REQUIRED_TABLES if table not in known_tables)
        if missing_tables:
            raise RuntimeError(f"Backup is missing required tables: {', '.join(missing_tables)}")

        metrics = collect_table_metrics(conn, table_names=CONTROL_PLANE_REQUIRED_TABLES)
        return {
            "quick_check": quick_check,
            "required_tables": list(CONTROL_PLANE_REQUIRED_TABLES),
            "table_counts": metrics["table_counts"],
            "latest_timestamps": metrics["latest_timestamps"],
        }


def main() -> int:
    args = parse_args()
    backup_path = Path(args.backup_path).expanduser()
    if not backup_path.exists():
        raise FileNotFoundError(f"Backup artifact does not exist: {backup_path}")

    decompressed_for_validation = backup_path.suffix == ".gz"
    if backup_path.suffix == ".gz":
        with tempfile.TemporaryDirectory(dir=backup_path.parent, prefix="control-plane-validate-") as temp_dir:
            extracted_path = Path(temp_dir) / backup_path.with_suffix("").name
            with gzip.open(backup_path, "rb") as compressed_file:
                with extracted_path.open("wb") as extracted_file:
                    while True:
                        chunk = compressed_file.read(1024 * 1024)
                        if not chunk:
                            break
                        extracted_file.write(chunk)
            result = validate_backup_database(extracted_path)
    else:
        extracted_path = backup_path
        result = validate_backup_database(extracted_path)

    output = {
        "status": "ok",
        "backup_path": str(backup_path),
        "decompressed_for_validation": decompressed_for_validation,
        "validated_db_path": str(backup_path if decompressed_for_validation else extracted_path),
        **result,
    }
    print(json.dumps(output, indent=2 if args.pretty else None, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        error_payload = {
            "status": "error",
            "error_type": exc.__class__.__name__,
            "error": str(exc),
        }
        print(json.dumps(error_payload, sort_keys=True), file=sys.stderr)
        raise
