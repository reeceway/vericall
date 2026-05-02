#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from backup_utils import (  # noqa: E402
    BACKUP_FILE_PREFIX,
    collect_table_metrics,
    latest_backup_manifest_path,
    resolve_backup_dir,
    resolve_control_plane_db_path,
    resolve_retention_days,
)

SQLITE_TIMEOUT_SECONDS = max(float(os.getenv("VICALL_SQLITE_TIMEOUT_SECONDS", "30")), 1.0)
SQLITE_BUSY_TIMEOUT_MS = max(int(os.getenv("VICALL_SQLITE_BUSY_TIMEOUT_MS", "30000")), 1000)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a consistent backup of the Vicall control-plane SQLite DB.")
    parser.add_argument("--db-path", default=None, help="Override the control-plane DB path.")
    parser.add_argument("--backup-dir", default=None, help="Override the local backup directory.")
    parser.add_argument(
        "--retention-days",
        type=int,
        default=None,
        help="How many days of local backup artifacts to keep. Defaults to VICALL_BACKUP_RETENTION_DAYS or 30.",
    )
    parser.add_argument(
        "--skip-upload",
        action="store_true",
        help="Always skip offsite upload even if bucket env vars are present.",
    )
    parser.add_argument("--pretty", action="store_true", help="Pretty-print the JSON result.")
    return parser.parse_args()


def open_sqlite_connection(path: Path, *, read_only: bool) -> sqlite3.Connection:
    connection = sqlite3.connect(str(path), timeout=SQLITE_TIMEOUT_SECONDS)
    if read_only:
        connection.execute("PRAGMA query_only = ON")
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
    return connection


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp_path.replace(path)


def compress_file(source_path: Path, destination_path: Path) -> tuple[str, int, int]:
    sha256_hash = hashlib.sha256()
    uncompressed_size = source_path.stat().st_size
    with source_path.open("rb") as source_file:
        with gzip.open(destination_path, "wb", compresslevel=6) as gzip_file:
            while True:
                chunk = source_file.read(1024 * 1024)
                if not chunk:
                    break
                gzip_file.write(chunk)
    with destination_path.open("rb") as gzip_file:
        while True:
            chunk = gzip_file.read(1024 * 1024)
            if not chunk:
                break
            sha256_hash.update(chunk)
    return sha256_hash.hexdigest(), destination_path.stat().st_size, uncompressed_size


def prune_old_local_backups(backup_dir: Path, *, retention_days: int, now: datetime) -> list[str]:
    if retention_days <= 0:
        return []
    cutoff = now - timedelta(days=retention_days)
    removed: list[str] = []
    latest_alias = latest_backup_manifest_path(backup_dir)
    for artifact in backup_dir.glob(f"{BACKUP_FILE_PREFIX}-*"):
        if artifact.name == latest_alias.name:
            continue
        if not artifact.is_file():
            continue
        modified_at = datetime.fromtimestamp(artifact.stat().st_mtime, tz=timezone.utc)
        if modified_at >= cutoff:
            continue
        artifact.unlink(missing_ok=True)
        removed.append(str(artifact))
    return sorted(removed)


def build_s3_client():
    import boto3

    client_kwargs: dict[str, Any] = {}
    region_name = (os.getenv("AWS_REGION") or "").strip()
    endpoint_url = (os.getenv("AWS_ENDPOINT_URL") or "").strip()
    if region_name:
        client_kwargs["region_name"] = region_name
    if endpoint_url:
        client_kwargs["endpoint_url"] = endpoint_url
    return boto3.client("s3", **client_kwargs)


def upload_offsite(backup_path: Path, manifest_path: Path) -> dict[str, Any]:
    bucket = (os.getenv("VICALL_BACKUP_BUCKET") or "").strip()
    if not bucket:
        return {"status": "skipped", "reason": "VICALL_BACKUP_BUCKET is not configured"}

    s3_client = build_s3_client()
    prefix = (os.getenv("VICALL_BACKUP_PREFIX") or "").strip().strip("/")

    def key_for(path: Path) -> str:
        return f"{prefix}/{path.name}" if prefix else path.name

    backup_key = key_for(backup_path)
    manifest_key = key_for(manifest_path)
    s3_client.upload_file(str(backup_path), bucket, backup_key, ExtraArgs={"ContentType": "application/gzip"})
    s3_client.upload_file(str(manifest_path), bucket, manifest_key, ExtraArgs={"ContentType": "application/json"})
    return {
        "status": "uploaded",
        "bucket": bucket,
        "prefix": prefix or None,
        "backup_object_key": backup_key,
        "manifest_object_key": manifest_key,
        "endpoint_url": (os.getenv("AWS_ENDPOINT_URL") or "").strip() or None,
    }


def main() -> int:
    args = parse_args()
    db_path = resolve_control_plane_db_path(args.db_path)
    backup_dir = resolve_backup_dir(args.backup_dir)
    retention_days = resolve_retention_days(args.retention_days)
    backup_dir.mkdir(parents=True, exist_ok=True)

    if not db_path.exists():
        raise FileNotFoundError(f"Control-plane DB does not exist: {db_path}")

    started_at = utcnow()
    file_timestamp = started_at.strftime("%Y%m%dT%H%M%SZ")
    stem = f"{BACKUP_FILE_PREFIX}-{file_timestamp}"
    final_backup_path = backup_dir / f"{stem}.sqlite3.gz"
    final_manifest_path = backup_dir / f"{stem}.manifest.json"
    latest_manifest_alias = latest_backup_manifest_path(backup_dir)

    with tempfile.NamedTemporaryFile(
        dir=backup_dir,
        prefix=f".{stem}-",
        suffix=".sqlite3",
        delete=False,
    ) as temp_db_file:
        temp_db_path = Path(temp_db_file.name)

    gzip_temp_path = backup_dir / f".{stem}.sqlite3.gz.tmp"

    try:
        with open_sqlite_connection(db_path, read_only=True) as source_conn:
            with open_sqlite_connection(temp_db_path, read_only=False) as backup_conn:
                source_conn.backup(backup_conn)
                backup_conn.execute("PRAGMA wal_checkpoint(FULL)")
                backup_conn.execute("PRAGMA journal_mode = DELETE").fetchone()
                backup_conn.commit()

        with open_sqlite_connection(temp_db_path, read_only=True) as metrics_conn:
            metrics = collect_table_metrics(metrics_conn)

        sha256_value, compressed_size, uncompressed_size = compress_file(temp_db_path, gzip_temp_path)
        gzip_temp_path.replace(final_backup_path)

        manifest = {
            "timestamp": isoformat(started_at),
            "source_db_path": str(db_path),
            "compressed_backup_path": str(final_backup_path),
            "manifest_path": str(final_manifest_path),
            "sha256": sha256_value,
            "compressed_size_bytes": compressed_size,
            "uncompressed_size_bytes": uncompressed_size,
            "table_counts": metrics["table_counts"],
            "latest_timestamps": metrics["latest_timestamps"],
            "backup_dir": str(backup_dir),
            "retention_days": retention_days,
        }
        write_json_atomic(final_manifest_path, manifest)
        write_json_atomic(latest_manifest_alias, manifest)

        upload_result = {"status": "skipped", "reason": "offsite upload disabled"}
        if not args.skip_upload:
            upload_result = upload_offsite(final_backup_path, final_manifest_path)

        removed_paths = prune_old_local_backups(backup_dir, retention_days=retention_days, now=started_at)

        result = {
            **manifest,
            "latest_manifest_alias_path": str(latest_manifest_alias),
            "retention_cleanup_removed_paths": removed_paths,
            "offsite_upload": upload_result,
        }
        print(json.dumps(result, indent=2 if args.pretty else None, sort_keys=True))
        return 0
    finally:
        temp_db_path.unlink(missing_ok=True)
        gzip_temp_path.unlink(missing_ok=True)
        temp_db_path.with_name(temp_db_path.name + "-wal").unlink(missing_ok=True)
        temp_db_path.with_name(temp_db_path.name + "-shm").unlink(missing_ok=True)


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
