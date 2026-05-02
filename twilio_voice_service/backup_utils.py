from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any, Iterable

BACKUP_FILE_PREFIX = "control-plane-backup"
LATEST_BACKUP_MANIFEST_FILENAME = "control-plane-backup-latest.json"

CONTROL_PLANE_REQUIRED_TABLES = (
    "msps",
    "organizations",
    "organization_access_codes",
    "access_grants",
    "organization_memberships",
    "organization_usage_monthly",
    "call_sessions",
    "call_session_legs",
    "call_participants",
    "user_usage_monthly",
    "billing_runs",
)

CONTROL_PLANE_MANIFEST_TABLES = (
    "msps",
    "organizations",
    "organization_access_codes",
    "access_grants",
    "organization_memberships",
    "organization_usage_monthly",
    "call_sessions",
    "call_session_legs",
    "call_participants",
    "user_usage_monthly",
    "billing_runs",
    "msp_users",
    "msp_sessions",
)

TABLE_TIMESTAMP_COLUMNS: dict[str, tuple[str, ...]] = {
    "msps": ("updated_at", "created_at"),
    "organizations": ("updated_at", "created_at"),
    "organization_access_codes": ("updated_at", "created_at"),
    "access_grants": ("created_at", "consumed_at", "expires_at"),
    "organization_memberships": ("updated_at", "last_verified_at", "deactivated_at", "created_at"),
    "organization_usage_monthly": ("updated_at", "created_at"),
    "call_sessions": ("updated_at", "completed_at", "answered_at", "started_at", "created_at"),
    "call_session_legs": ("updated_at", "completed_at", "answered_at", "initiated_at", "created_at"),
    "call_participants": ("updated_at", "created_at"),
    "user_usage_monthly": ("updated_at", "created_at"),
    "billing_runs": ("finalized_at", "created_at"),
    "msp_users": ("updated_at", "last_login_at", "created_at"),
    "msp_sessions": ("last_seen_at", "created_at"),
}


def resolve_control_plane_db_path(db_path: str | Path | None = None) -> Path:
    if db_path is None:
        db_path = os.getenv("VICALL_CONTROL_DB_PATH", "/data/vericall_control.db")
    return Path(db_path).expanduser()


def resolve_backup_dir(backup_dir: str | Path | None = None) -> Path:
    if backup_dir is None:
        backup_dir = os.getenv("VICALL_BACKUP_DIR", "/data/backups")
    return Path(backup_dir).expanduser()


def resolve_retention_days(value: int | str | None = None) -> int:
    raw_value = value if value is not None else os.getenv("VICALL_BACKUP_RETENTION_DAYS", "30")
    try:
        return max(int(raw_value), 0)
    except (TypeError, ValueError):
        return 30


def latest_backup_manifest_path(backup_dir: str | Path | None = None) -> Path:
    return resolve_backup_dir(backup_dir) / LATEST_BACKUP_MANIFEST_FILENAME


def _load_json_file(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def read_latest_backup_manifest(backup_dir: str | Path | None = None) -> dict[str, Any] | None:
    resolved_backup_dir = resolve_backup_dir(backup_dir)
    alias_path = latest_backup_manifest_path(resolved_backup_dir)
    if alias_path.exists():
        loaded = _load_json_file(alias_path)
        if loaded is not None:
            return loaded

    manifest_paths = sorted(
        resolved_backup_dir.glob(f"{BACKUP_FILE_PREFIX}-*.manifest.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for manifest_path in manifest_paths:
        loaded = _load_json_file(manifest_path)
        if loaded is not None:
            return loaded
    return None


def existing_tables(conn: sqlite3.Connection) -> set[str]:
    return {
        str(row[0])
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
    }


def table_columns(conn: sqlite3.Connection, table_name: str) -> set[str]:
    return {
        str(row[1])
        for row in conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    }


def collect_table_metrics(
    conn: sqlite3.Connection,
    *,
    table_names: Iterable[str] = CONTROL_PLANE_MANIFEST_TABLES,
) -> dict[str, dict[str, Any]]:
    known_tables = existing_tables(conn)
    counts: dict[str, int] = {}
    latest_timestamps: dict[str, dict[str, str]] = {}

    for table_name in table_names:
        if table_name not in known_tables:
            continue
        counts[table_name] = int(conn.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()[0] or 0)
        available_columns = table_columns(conn, table_name)
        table_latest: dict[str, str] = {}
        for column_name in TABLE_TIMESTAMP_COLUMNS.get(table_name, ()):
            if column_name not in available_columns:
                continue
            value = conn.execute(
                f"SELECT MAX({column_name}) FROM {table_name} WHERE {column_name} IS NOT NULL"
            ).fetchone()[0]
            if value is not None:
                table_latest[column_name] = str(value)
        if table_latest:
            latest_timestamps[table_name] = table_latest

    return {
        "table_counts": counts,
        "latest_timestamps": latest_timestamps,
    }
