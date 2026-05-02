from __future__ import annotations

import json
import os
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import pbkdf2_hmac, sha256
from pathlib import Path
from secrets import compare_digest, token_bytes, token_urlsafe
from typing import Any


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


def month_start(value: datetime | None = None) -> datetime:
    now = value or utcnow()
    return datetime(now.year, now.month, 1, tzinfo=timezone.utc)


def next_month_start(value: datetime | None = None) -> datetime:
    current = month_start(value)
    if current.month == 12:
        return datetime(current.year + 1, 1, 1, tzinfo=timezone.utc)
    return datetime(current.year, current.month + 1, 1, tzinfo=timezone.utc)


def prefixed_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:16]}"


def hash_secret(value: str) -> str:
    return sha256(value.encode("utf-8")).hexdigest()


def normalize_code(code: str | None) -> str:
    return (code or "").strip().upper()


def normalize_email(email: str | None) -> str:
    return (email or "").strip().lower()


def normalize_phone_number(phone_number: str | None) -> str | None:
    normalized = (phone_number or "").strip()
    if not normalized:
        return None

    digits = "".join(ch for ch in normalized if ch.isdigit())
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    if 8 <= len(digits) <= 15:
        return f"+{digits}"
    return normalized


def normalize_seat_limit(value: int | str | None) -> int | None:
    if value is None:
        return None
    if isinstance(value, str):
        normalized = value.strip()
        if not normalized:
            return None
        value = int(normalized)
    normalized_value = int(value)
    return normalized_value if normalized_value > 0 else None


MSP_STATUS_PENDING_REVIEW = "pending_review"
MSP_STATUS_ACTIVE = "active"
MSP_STATUS_SUSPENDED = "suspended"
MSP_STATUS_CLOSED = "closed"
MSP_STATUSES = {
    MSP_STATUS_PENDING_REVIEW,
    MSP_STATUS_ACTIVE,
    MSP_STATUS_SUSPENDED,
    MSP_STATUS_CLOSED,
}
MSP_LOGIN_ALLOWED_STATUSES = {
    MSP_STATUS_PENDING_REVIEW,
    MSP_STATUS_ACTIVE,
    MSP_STATUS_SUSPENDED,
}

MSP_ROLE_OWNER = "owner"
MSP_ROLE_BILLING_ADMIN = "billing_admin"
MSP_ROLE_OPERATOR = "operator"
MSP_ROLE_READ_ONLY = "read_only"
MSP_ROLES = {
    MSP_ROLE_OWNER,
    MSP_ROLE_BILLING_ADMIN,
    MSP_ROLE_OPERATOR,
    MSP_ROLE_READ_ONLY,
}


def normalize_msp_status(status: str | None) -> str:
    normalized = (status or "").strip().lower()
    if not normalized:
        return MSP_STATUS_ACTIVE
    if normalized not in MSP_STATUSES:
        raise ValueError(f"Invalid MSP status: {status}")
    return normalized


def normalize_msp_role(role: str | None) -> str:
    normalized = (role or "").strip().lower()
    if not normalized or normalized == "admin":
        return MSP_ROLE_OWNER
    if normalized not in MSP_ROLES:
        raise ValueError(f"Invalid MSP role: {role}")
    return normalized


def msp_status_allows_login(status: str | None) -> bool:
    return normalize_msp_status(status) in MSP_LOGIN_ALLOWED_STATUSES


def msp_status_allows_production(status: str | None) -> bool:
    return normalize_msp_status(status) == MSP_STATUS_ACTIVE


COMPLETED_CALL_STATUSES = {"completed", "busy", "failed", "no-answer", "canceled"}
ANSWERED_CALL_STATUSES = {"answered", "in-progress"}
STARTED_CALL_STATUSES = {"initiated", "ringing", "queued", "answered", "in-progress", "completed"}
TWILIO_IDENTITY_SUFFIXES = ("_prod1", "_dev2")


class AmbiguousVoiceMembershipError(ValueError):
    """Raised when a phone identity maps to multiple active customer accounts."""


def normalize_twilio_identity(value: str | None) -> str | None:
    normalized = (value or "").strip()
    if normalized.startswith("client:"):
        normalized = normalized.removeprefix("client:")
    return normalized or None


def phone_number_from_twilio_identity(identity: str | None) -> str | None:
    normalized = normalize_twilio_identity(identity)
    if not normalized or not normalized.startswith("user_"):
        return None

    digits = normalized.removeprefix("user_")
    for suffix in TWILIO_IDENTITY_SUFFIXES:
        if digits.endswith(suffix):
            digits = digits[: -len(suffix)]
            break

    if digits.startswith("+") and digits[1:].isdigit():
        return digits
    if not digits.isdigit():
        return None
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    return f"+{digits}"


def billable_minutes_for_seconds(seconds: int | None) -> int:
    normalized = max(int(seconds or 0), 0)
    return (normalized + 59) // 60 if normalized else 0


INCLUDED_MINUTES_PER_SEAT = max(int(os.getenv("VICALL_INCLUDED_MINUTES_PER_SEAT", "450")), 0)
# One decicent is one tenth of a cent. $0.001/minute = 1 decicent/minute.
OVERAGE_DECICENTS_PER_MINUTE = max(int(os.getenv("VICALL_OVERAGE_DECICENTS_PER_MINUTE", "1")), 0)


def included_minutes_for_seats(seats: int | None) -> int:
    return max(int(seats or 0), 0) * INCLUDED_MINUTES_PER_SEAT


def overage_minutes_for_usage(*, billable_minutes: int | None, billable_seats: int | None) -> int:
    return max(int(billable_minutes or 0) - included_minutes_for_seats(billable_seats), 0)


def cents_from_decicents(decicents: int | None) -> int:
    normalized = max(int(decicents or 0), 0)
    return (normalized + 9) // 10 if normalized else 0


def overage_amount_decicents_for_minutes(minutes: int | None) -> int:
    return max(int(minutes or 0), 0) * OVERAGE_DECICENTS_PER_MINUTE


def overage_amount_cents_for_minutes(minutes: int | None) -> int:
    return cents_from_decicents(overage_amount_decicents_for_minutes(minutes))


PASSWORD_ALGORITHM = "pbkdf2_sha256"
PASSWORD_ITERATIONS = int(os.getenv("MSP_PASSWORD_ITERATIONS", "200000"))
PASSWORD_MIN_LENGTH = int(os.getenv("MSP_PASSWORD_MIN_LENGTH", "10"))
SQLITE_TIMEOUT_SECONDS = max(float(os.getenv("VICALL_SQLITE_TIMEOUT_SECONDS", "30")), 1.0)
SQLITE_BUSY_TIMEOUT_MS = max(int(os.getenv("VICALL_SQLITE_BUSY_TIMEOUT_MS", "30000")), 1000)
SQLITE_WAL_AUTOCHECKPOINT_PAGES = max(int(os.getenv("VICALL_SQLITE_WAL_AUTOCHECKPOINT_PAGES", "1000")), 100)
SQLITE_SYNCHRONOUS_LABELS = {
    0: "OFF",
    1: "NORMAL",
    2: "FULL",
    3: "EXTRA",
}


def hash_password(password: str) -> str:
    normalized = (password or "").strip()
    if len(normalized) < PASSWORD_MIN_LENGTH:
        raise ValueError(f"Password must be at least {PASSWORD_MIN_LENGTH} characters")
    salt = token_bytes(16)
    derived = pbkdf2_hmac("sha256", normalized.encode("utf-8"), salt, PASSWORD_ITERATIONS)
    return f"{PASSWORD_ALGORITHM}${PASSWORD_ITERATIONS}${salt.hex()}${derived.hex()}"


def verify_password(stored_value: str | None, provided_password: str | None) -> bool:
    if not stored_value or not provided_password:
        return False
    try:
        algorithm, iterations_raw, salt_hex, expected_hex = stored_value.split("$", 3)
        if algorithm != PASSWORD_ALGORITHM:
            return False
        iterations = int(iterations_raw)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(expected_hex)
    except Exception:
        return False
    calculated = pbkdf2_hmac("sha256", provided_password.encode("utf-8"), salt, iterations)
    return compare_digest(calculated, expected)


@dataclass
class AccessGrantContext:
    organization_id: str
    organization_name: str
    msp_id: str
    msp_name: str
    access_code_id: str
    grant_token: str
    seat_price_cents: int
    organization_billing_exempt: bool = False
    stripe_customer_id: str | None = None

    def as_response(self) -> dict[str, Any]:
        return {
            "organization_id": self.organization_id,
            "organization_name": self.organization_name,
            "msp_id": self.msp_id,
            "msp_name": self.msp_name,
            "access_code_id": self.access_code_id,
            "grant_token": self.grant_token,
            "seat_price_cents": self.seat_price_cents,
            "organization_billing_exempt": self.organization_billing_exempt,
        }


@dataclass
class MSPPortalSessionContext:
    session_token: str
    session_id: str
    msp_user_id: str
    msp_id: str
    msp_name: str
    email: str
    phone_number: str | None
    full_name: str | None
    role: str
    msp_status: str
    billing_email: str | None
    stripe_customer_id: str | None
    seat_price_cents: int

    def as_msp_row(self) -> dict[str, Any]:
        return {
            "id": self.msp_id,
            "name": self.msp_name,
            "billing_email": self.billing_email,
            "stripe_customer_id": self.stripe_customer_id,
            "seat_price_cents": self.seat_price_cents,
            "msp_user_id": self.msp_user_id,
            "email": self.email,
            "phone_number": self.phone_number,
            "full_name": self.full_name,
            "role": self.role,
            "status": self.msp_status,
        }


class ControlPlaneStore:
    def __init__(self, db_path: str | Path) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.db_path, timeout=SQLITE_TIMEOUT_SECONDS)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        journal_mode = connection.execute("PRAGMA journal_mode = WAL").fetchone()[0]
        if str(journal_mode).lower() != "wal":
            raise RuntimeError(f"Unable to enable WAL mode for control-plane DB at {self.db_path}")
        connection.execute("PRAGMA synchronous = FULL")
        connection.execute(f"PRAGMA wal_autocheckpoint = {SQLITE_WAL_AUTOCHECKPOINT_PAGES}")
        return connection

    def sqlite_durability_status(self) -> dict[str, Any]:
        db_exists = self.db_path.exists()
        db_size_bytes = self.db_path.stat().st_size if db_exists else 0
        with self._connect() as conn:
            journal_mode = str(conn.execute("PRAGMA journal_mode").fetchone()[0]).lower()
            synchronous_value = int(conn.execute("PRAGMA synchronous").fetchone()[0])
            foreign_keys_enabled = bool(int(conn.execute("PRAGMA foreign_keys").fetchone()[0]))
            busy_timeout_ms = int(conn.execute("PRAGMA busy_timeout").fetchone()[0])
            wal_autocheckpoint = int(conn.execute("PRAGMA wal_autocheckpoint").fetchone()[0])

        return {
            "db_path": str(self.db_path),
            "db_exists": db_exists,
            "db_size_bytes": db_size_bytes,
            "journal_mode": journal_mode,
            "synchronous": {
                "value": synchronous_value,
                "label": SQLITE_SYNCHRONOUS_LABELS.get(synchronous_value, str(synchronous_value)),
            },
            "foreign_keys": foreign_keys_enabled,
            "busy_timeout_ms": busy_timeout_ms,
            "connection_timeout_seconds": SQLITE_TIMEOUT_SECONDS,
            "wal_autocheckpoint_pages": wal_autocheckpoint,
        }

    def _migrate(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS msps (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    billing_email TEXT,
                    stripe_customer_id TEXT,
                    seat_price_cents INTEGER NOT NULL DEFAULT 2000,
                    status TEXT NOT NULL DEFAULT 'active',
                    active INTEGER NOT NULL DEFAULT 1,
                    portal_api_key_hash TEXT UNIQUE,
                    portal_api_key_hint TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organizations (
                    id TEXT PRIMARY KEY,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    external_ref TEXT,
                    provisioned_seats INTEGER,
                    billing_exempt INTEGER NOT NULL DEFAULT 0,
                    active INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organization_access_codes (
                    id TEXT PRIMARY KEY,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    label TEXT,
                    code_hash TEXT NOT NULL UNIQUE,
                    code_hint TEXT,
                    active INTEGER NOT NULL DEFAULT 1,
                    max_activations INTEGER,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS access_grants (
                    id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    access_code_id TEXT NOT NULL REFERENCES organization_access_codes(id) ON DELETE CASCADE,
                    phone_number TEXT,
                    expires_at TEXT NOT NULL,
                    consumed_at TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organization_memberships (
                    id TEXT PRIMARY KEY,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    phone_number TEXT NOT NULL,
                    user_id TEXT,
                    status TEXT NOT NULL,
                    access_code_id TEXT REFERENCES organization_access_codes(id),
                    first_verified_at TEXT NOT NULL,
                    last_verified_at TEXT NOT NULL,
                    deactivated_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(organization_id, phone_number)
                );

                CREATE TABLE IF NOT EXISTS organization_usage_monthly (
                    id TEXT PRIMARY KEY,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    period_start TEXT NOT NULL,
                    active_seats INTEGER NOT NULL,
                    billable_seats INTEGER NOT NULL DEFAULT 0,
                    call_count INTEGER NOT NULL DEFAULT 0,
                    billable_seconds INTEGER NOT NULL DEFAULT 0,
                    billable_minutes INTEGER NOT NULL DEFAULT 0,
                    included_minutes INTEGER NOT NULL DEFAULT 0,
                    overage_minutes INTEGER NOT NULL DEFAULT 0,
                    overage_amount_decicents INTEGER NOT NULL DEFAULT 0,
                    overage_amount_cents INTEGER NOT NULL DEFAULT 0,
                    overage_rate_decicents_per_minute INTEGER NOT NULL DEFAULT 1,
                    included_minutes_per_seat INTEGER NOT NULL DEFAULT 450,
                    seat_price_cents INTEGER NOT NULL,
                    amount_cents INTEGER NOT NULL,
                    stripe_invoice_id TEXT,
                    stripe_invoice_item_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(organization_id, period_start)
                );

                CREATE TABLE IF NOT EXISTS seat_billing_events (
                    id TEXT PRIMARY KEY,
                    membership_id TEXT NOT NULL REFERENCES organization_memberships(id) ON DELETE CASCADE,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    phone_number TEXT NOT NULL,
                    user_id TEXT,
                    period_start TEXT NOT NULL,
                    seat_price_cents INTEGER NOT NULL,
                    amount_cents INTEGER NOT NULL,
                    stripe_invoice_id TEXT,
                    stripe_invoice_item_id TEXT,
                    hosted_invoice_url TEXT,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(membership_id, period_start)
                );

                CREATE TABLE IF NOT EXISTS call_sessions (
                    id TEXT PRIMARY KEY,
                    canonical_key TEXT NOT NULL UNIQUE,
                    room TEXT,
                    caller_identity TEXT,
                    callee_identity TEXT,
                    caller_phone_number TEXT,
                    callee_phone_number TEXT,
                    caller_organization_id TEXT REFERENCES organizations(id) ON DELETE SET NULL,
                    callee_organization_id TEXT REFERENCES organizations(id) ON DELETE SET NULL,
                    msp_id TEXT REFERENCES msps(id) ON DELETE SET NULL,
                    status TEXT NOT NULL,
                    started_at TEXT,
                    answered_at TEXT,
                    completed_at TEXT,
                    duration_seconds INTEGER NOT NULL DEFAULT 0,
                    billable_seconds INTEGER NOT NULL DEFAULT 0,
                    billable_minutes INTEGER NOT NULL DEFAULT 0,
                    last_event_at TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS call_session_legs (
                    id TEXT PRIMARY KEY,
                    call_session_id TEXT NOT NULL REFERENCES call_sessions(id) ON DELETE CASCADE,
                    twilio_call_sid TEXT NOT NULL UNIQUE,
                    parent_call_sid TEXT,
                    leg_role TEXT,
                    from_identity TEXT,
                    to_identity TEXT,
                    status TEXT,
                    callback_event TEXT,
                    initiated_at TEXT,
                    ringing_at TEXT,
                    answered_at TEXT,
                    completed_at TEXT,
                    duration_seconds INTEGER NOT NULL DEFAULT 0,
                    last_event_at TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS call_participants (
                    id TEXT PRIMARY KEY,
                    call_session_id TEXT NOT NULL REFERENCES call_sessions(id) ON DELETE CASCADE,
                    identity TEXT NOT NULL,
                    role TEXT NOT NULL,
                    phone_number TEXT,
                    user_id TEXT,
                    membership_id TEXT REFERENCES organization_memberships(id) ON DELETE SET NULL,
                    organization_id TEXT REFERENCES organizations(id) ON DELETE SET NULL,
                    organization_name TEXT,
                    msp_id TEXT REFERENCES msps(id) ON DELETE SET NULL,
                    msp_name TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(call_session_id, identity)
                );

                CREATE TABLE IF NOT EXISTS user_usage_monthly (
                    id TEXT PRIMARY KEY,
                    membership_id TEXT REFERENCES organization_memberships(id) ON DELETE SET NULL,
                    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    phone_number TEXT NOT NULL,
                    user_id TEXT,
                    period_start TEXT NOT NULL,
                    call_count INTEGER NOT NULL,
                    billable_seconds INTEGER NOT NULL,
                    billable_minutes INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(organization_id, phone_number, period_start)
                );

                CREATE TABLE IF NOT EXISTS billing_runs (
                    id TEXT PRIMARY KEY,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    period_start TEXT NOT NULL,
                    stripe_invoice_id TEXT,
                    hosted_invoice_url TEXT,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    finalized_at TEXT,
                    UNIQUE(msp_id, period_start)
                );

                CREATE TABLE IF NOT EXISTS msp_audit_events (
                    id TEXT PRIMARY KEY,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    actor_type TEXT NOT NULL,
                    actor_msp_user_id TEXT REFERENCES msp_users(id) ON DELETE SET NULL,
                    actor_email TEXT,
                    actor_role TEXT,
                    actor_label TEXT,
                    action TEXT NOT NULL,
                    target_type TEXT,
                    target_id TEXT,
                    organization_id TEXT,
                    organization_name TEXT,
                    status TEXT NOT NULL,
                    event_metadata TEXT,
                    ip_address TEXT,
                    user_agent TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS msp_users (
                    id TEXT PRIMARY KEY,
                    msp_id TEXT NOT NULL REFERENCES msps(id) ON DELETE CASCADE,
                    email TEXT NOT NULL UNIQUE,
                    phone_number TEXT,
                    full_name TEXT,
                    role TEXT NOT NULL DEFAULT 'owner',
                    active INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_login_at TEXT
                );

                CREATE TABLE IF NOT EXISTS msp_login_tokens (
                    id TEXT PRIMARY KEY,
                    msp_user_id TEXT NOT NULL REFERENCES msp_users(id) ON DELETE CASCADE,
                    token_hash TEXT NOT NULL UNIQUE,
                    purpose TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    consumed_at TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS msp_login_challenges (
                    id TEXT PRIMARY KEY,
                    msp_user_id TEXT NOT NULL REFERENCES msp_users(id) ON DELETE CASCADE,
                    token_hash TEXT NOT NULL UNIQUE,
                    phone_number TEXT,
                    ip_address TEXT,
                    user_agent TEXT,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_otp_sent_at TEXT,
                    expires_at TEXT NOT NULL,
                    consumed_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS msp_sessions (
                    id TEXT PRIMARY KEY,
                    msp_user_id TEXT NOT NULL REFERENCES msp_users(id) ON DELETE CASCADE,
                    token_hash TEXT NOT NULL UNIQUE,
                    expires_at TEXT NOT NULL,
                    revoked_at TEXT,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT
                );

                CREATE TABLE IF NOT EXISTS account_deletion_tokens (
                    id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE,
                    phone_number TEXT,
                    user_id TEXT,
                    identity TEXT,
                    expires_at TEXT NOT NULL,
                    consumed_at TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_access_codes_org ON organization_access_codes(organization_id);
                CREATE INDEX IF NOT EXISTS idx_memberships_org_status ON organization_memberships(organization_id, status);
                CREATE INDEX IF NOT EXISTS idx_memberships_phone_status ON organization_memberships(phone_number, status);
                CREATE INDEX IF NOT EXISTS idx_usage_monthly_msp_period ON organization_usage_monthly(msp_id, period_start);
                CREATE INDEX IF NOT EXISTS idx_seat_billing_events_msp_period ON seat_billing_events(msp_id, period_start);
                CREATE INDEX IF NOT EXISTS idx_seat_billing_events_invoice ON seat_billing_events(stripe_invoice_id);
                CREATE INDEX IF NOT EXISTS idx_call_sessions_completed ON call_sessions(completed_at);
                CREATE INDEX IF NOT EXISTS idx_call_sessions_msp_completed ON call_sessions(msp_id, completed_at);
                CREATE INDEX IF NOT EXISTS idx_call_legs_session ON call_session_legs(call_session_id);
                CREATE INDEX IF NOT EXISTS idx_call_participants_org ON call_participants(organization_id, msp_id);
                CREATE INDEX IF NOT EXISTS idx_user_usage_msp_period ON user_usage_monthly(msp_id, period_start);
                CREATE INDEX IF NOT EXISTS idx_msp_users_msp ON msp_users(msp_id);
                CREATE INDEX IF NOT EXISTS idx_msp_login_tokens_user ON msp_login_tokens(msp_user_id);
                CREATE INDEX IF NOT EXISTS idx_msp_login_challenges_user ON msp_login_challenges(msp_user_id);
                CREATE INDEX IF NOT EXISTS idx_msp_login_challenges_expires ON msp_login_challenges(expires_at);
                CREATE INDEX IF NOT EXISTS idx_msp_sessions_user ON msp_sessions(msp_user_id);
                CREATE INDEX IF NOT EXISTS idx_account_deletion_tokens_created ON account_deletion_tokens(created_at);
                CREATE INDEX IF NOT EXISTS idx_msp_audit_events_msp_created ON msp_audit_events(msp_id, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_msp_audit_events_msp_action ON msp_audit_events(msp_id, action, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_msp_audit_events_msp_org ON msp_audit_events(msp_id, organization_id, created_at DESC);
                """
            )
            msp_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(msps)").fetchall()
            }
            if "status" not in msp_columns:
                conn.execute("ALTER TABLE msps ADD COLUMN status TEXT")
            conn.execute(
                """
                UPDATE msps
                SET status = CASE
                    WHEN LOWER(COALESCE(status, '')) IN ('pending_review', 'active', 'suspended', 'closed')
                        THEN LOWER(status)
                    WHEN active = 1 THEN 'active'
                    ELSE 'closed'
                END
                WHERE status IS NULL
                   OR TRIM(status) = ''
                   OR LOWER(status) NOT IN ('pending_review', 'active', 'suspended', 'closed')
                """
            )
            conn.execute(
                """
                UPDATE msps
                SET active = CASE WHEN status = 'closed' THEN 0 ELSE 1 END
                WHERE active != CASE WHEN status = 'closed' THEN 0 ELSE 1 END
                """
            )
            msp_user_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(msp_users)").fetchall()
            }
            if "password_hash" not in msp_user_columns:
                conn.execute("ALTER TABLE msp_users ADD COLUMN password_hash TEXT")
            if "phone_number" not in msp_user_columns:
                conn.execute("ALTER TABLE msp_users ADD COLUMN phone_number TEXT")
            conn.execute(
                """
                UPDATE msp_users
                SET role = CASE
                    WHEN role IS NULL OR TRIM(role) = '' OR LOWER(role) = 'admin' THEN 'owner'
                    ELSE LOWER(role)
                END
                """
            )
            conn.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_msp_users_phone
                ON msp_users(phone_number)
                WHERE phone_number IS NOT NULL AND phone_number != ''
                """
            )
            billing_run_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(billing_runs)").fetchall()
            }
            if "hosted_invoice_url" not in billing_run_columns:
                conn.execute("ALTER TABLE billing_runs ADD COLUMN hosted_invoice_url TEXT")
            usage_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(organization_usage_monthly)").fetchall()
            }
            organization_columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(organizations)").fetchall()
            }
            if "provisioned_seats" not in organization_columns:
                conn.execute("ALTER TABLE organizations ADD COLUMN provisioned_seats INTEGER")
            if "billing_exempt" not in organization_columns:
                conn.execute("ALTER TABLE organizations ADD COLUMN billing_exempt INTEGER NOT NULL DEFAULT 0")
                conn.execute(
                    """
                    UPDATE organizations
                    SET billing_exempt = 1
                    WHERE id IN (
                        SELECT first_org.id
                        FROM organizations first_org
                        JOIN (
                            SELECT msp_id, MIN(created_at) AS first_created_at
                            FROM organizations
                            GROUP BY msp_id
                        ) ranked
                          ON ranked.msp_id = first_org.msp_id
                         AND ranked.first_created_at = first_org.created_at
                    )
                    """
                )
            usage_column_migrations = {
                "billable_seats": "ALTER TABLE organization_usage_monthly ADD COLUMN billable_seats INTEGER NOT NULL DEFAULT 0",
                "call_count": "ALTER TABLE organization_usage_monthly ADD COLUMN call_count INTEGER NOT NULL DEFAULT 0",
                "billable_seconds": "ALTER TABLE organization_usage_monthly ADD COLUMN billable_seconds INTEGER NOT NULL DEFAULT 0",
                "billable_minutes": "ALTER TABLE organization_usage_monthly ADD COLUMN billable_minutes INTEGER NOT NULL DEFAULT 0",
                "included_minutes": "ALTER TABLE organization_usage_monthly ADD COLUMN included_minutes INTEGER NOT NULL DEFAULT 0",
                "overage_minutes": "ALTER TABLE organization_usage_monthly ADD COLUMN overage_minutes INTEGER NOT NULL DEFAULT 0",
                "overage_amount_decicents": "ALTER TABLE organization_usage_monthly ADD COLUMN overage_amount_decicents INTEGER NOT NULL DEFAULT 0",
                "overage_amount_cents": "ALTER TABLE organization_usage_monthly ADD COLUMN overage_amount_cents INTEGER NOT NULL DEFAULT 0",
                "overage_rate_decicents_per_minute": "ALTER TABLE organization_usage_monthly ADD COLUMN overage_rate_decicents_per_minute INTEGER NOT NULL DEFAULT 1",
                "included_minutes_per_seat": "ALTER TABLE organization_usage_monthly ADD COLUMN included_minutes_per_seat INTEGER NOT NULL DEFAULT 450",
            }
            for column_name, statement in usage_column_migrations.items():
                if column_name not in usage_columns:
                    conn.execute(statement)

    def create_msp(
        self,
        *,
        name: str,
        billing_email: str | None,
        seat_price_cents: int,
        status: str = MSP_STATUS_ACTIVE,
        stripe_customer_id: str | None = None,
        portal_api_key: str | None = None,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        msp_id = prefixed_id("msp")
        raw_portal_key = portal_api_key or f"vicall_msp_{token_urlsafe(24)}"
        portal_key_hash = hash_secret(raw_portal_key)
        portal_key_hint = raw_portal_key[-6:]
        normalized_status = normalize_msp_status(status)
        active_flag = 0 if normalized_status == MSP_STATUS_CLOSED else 1

        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO msps (
                    id, name, billing_email, stripe_customer_id, seat_price_cents,
                    status, active, portal_api_key_hash, portal_api_key_hint, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    msp_id,
                    name.strip(),
                    (billing_email or "").strip() or None,
                    stripe_customer_id,
                    int(seat_price_cents),
                    normalized_status,
                    active_flag,
                    portal_key_hash,
                    portal_key_hint,
                    now,
                    now,
                ),
            )
        return {
            "id": msp_id,
            "name": name.strip(),
            "billing_email": (billing_email or "").strip() or None,
            "seat_price_cents": int(seat_price_cents),
            "stripe_customer_id": stripe_customer_id,
            "status": normalized_status,
            "portal_api_key": raw_portal_key,
            "portal_api_key_hint": portal_key_hint,
        }

    def create_msp_user(
        self,
        *,
        msp_id: str,
        email: str,
        phone_number: str | None = None,
        full_name: str | None = None,
        role: str = MSP_ROLE_OWNER,
        password: str | None = None,
    ) -> dict[str, Any]:
        normalized_email = normalize_email(email)
        normalized_phone = normalize_phone_number(phone_number)
        normalized_role = normalize_msp_role(role)
        if not normalized_email:
            raise ValueError("Missing email address")
        now = isoformat(utcnow())
        user_id = prefixed_id("mspu")
        password_hash = hash_password(password) if password else None
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO msp_users (
                    id, msp_id, email, phone_number, full_name, role, active, created_at, updated_at, last_login_at, password_hash
                ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, NULL, ?)
                """,
                (
                    user_id,
                    msp_id,
                    normalized_email,
                    normalized_phone,
                    (full_name or "").strip() or None,
                    normalized_role,
                    now,
                    now,
                    password_hash,
                ),
            )
        return {
            "id": user_id,
            "msp_id": msp_id,
            "email": normalized_email,
            "phone_number": normalized_phone,
            "full_name": (full_name or "").strip() or None,
            "role": normalized_role,
        }

    def set_msp_user_password(self, *, msp_user_id: str, password: str) -> None:
        now = isoformat(utcnow())
        password_hash = hash_password(password)
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_users
                SET password_hash = ?, updated_at = ?
                WHERE id = ?
                """,
                (password_hash, now, msp_user_id),
            )

    def update_msp_user_profile(
        self,
        *,
        msp_user_id: str,
        phone_number: str | None = None,
        full_name: str | None = None,
        role: str | None = None,
    ) -> None:
        normalized_phone = normalize_phone_number(phone_number)
        normalized_name = (full_name or "").strip() or None
        normalized_role = normalize_msp_role(role) if role is not None else None
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_users
                SET
                    phone_number = COALESCE(?, phone_number),
                    full_name = COALESCE(?, full_name),
                    role = COALESCE(?, role),
                    updated_at = ?
                WHERE id = ?
                """,
                (normalized_phone, normalized_name, normalized_role, now, msp_user_id),
            )

    def authenticate_msp_user(self, *, email: str, password: str) -> sqlite3.Row | None:
        normalized_email = normalize_email(email)
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    u.*,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM msp_users u
                JOIN msps m ON m.id = u.msp_id
                WHERE u.email = ?
                  AND u.active = 1
                  AND m.active = 1
                  AND m.status IN ('pending_review', 'active', 'suspended')
                """,
                (normalized_email,),
            ).fetchone()
        if row is None:
            return None
        if not verify_password(row["password_hash"], password):
            return None
        return row

    def get_msp_user_by_email(self, email: str) -> sqlite3.Row | None:
        normalized_email = normalize_email(email)
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT
                    u.*,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM msp_users u
                JOIN msps m ON m.id = u.msp_id
                WHERE u.email = ?
                  AND u.active = 1
                  AND m.active = 1
                  AND m.status IN ('pending_review', 'active', 'suspended')
                """,
                (normalized_email,),
            ).fetchone()

    def get_msp_user_by_phone(self, phone_number: str) -> sqlite3.Row | None:
        normalized_phone = normalize_phone_number(phone_number)
        if not normalized_phone:
            return None
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT
                    u.*,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM msp_users u
                JOIN msps m ON m.id = u.msp_id
                WHERE u.phone_number = ?
                  AND u.active = 1
                  AND m.active = 1
                  AND m.status IN ('pending_review', 'active', 'suspended')
                """,
                (normalized_phone,),
            ).fetchone()

    def get_msp_user_for_msp(self, *, msp_id: str, email: str) -> sqlite3.Row | None:
        normalized_email = normalize_email(email)
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT *
                FROM msp_users
                WHERE msp_id = ? AND email = ? AND active = 1
                """,
                (msp_id, normalized_email),
            ).fetchone()

    def list_msp_users(self, msp_id: str) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, email, phone_number, full_name, role, active, created_at, updated_at, last_login_at
                FROM msp_users
                WHERE msp_id = ?
                ORDER BY created_at ASC
                """,
                (msp_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def create_msp_login_challenge(
        self,
        *,
        msp_user_id: str,
        ip_address: str | None = None,
        user_agent: str | None = None,
        ttl_minutes: int = 15,
    ) -> str:
        raw_token = f"vmlc_{token_urlsafe(32)}"
        now = utcnow()
        timestamp = isoformat(now)
        expires_at = isoformat(now + timedelta(minutes=ttl_minutes))
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_login_challenges
                SET consumed_at = ?, updated_at = ?
                WHERE msp_user_id = ? AND consumed_at IS NULL
                """,
                (timestamp, timestamp, msp_user_id),
            )
            conn.execute(
                """
                INSERT INTO msp_login_challenges (
                    id, msp_user_id, token_hash, phone_number, ip_address, user_agent,
                    attempt_count, last_otp_sent_at, expires_at, consumed_at, created_at, updated_at
                ) VALUES (?, ?, ?, NULL, ?, ?, 0, NULL, ?, NULL, ?, ?)
                """,
                (
                    prefixed_id("mlc"),
                    msp_user_id,
                    hash_secret(raw_token),
                    (ip_address or "").strip() or None,
                    (user_agent or "").strip() or None,
                    expires_at,
                    timestamp,
                    timestamp,
                ),
            )
        return raw_token

    def get_msp_login_challenge(self, raw_token: str) -> sqlite3.Row | None:
        token_hash = hash_secret(raw_token)
        now = utcnow()
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    c.id AS challenge_id,
                    c.msp_user_id,
                    c.phone_number AS challenge_phone_number,
                    c.ip_address,
                    c.user_agent,
                    c.attempt_count,
                    c.last_otp_sent_at,
                    c.expires_at,
                    c.consumed_at,
                    c.created_at,
                    c.updated_at,
                    u.email,
                    u.phone_number AS user_phone_number,
                    u.full_name,
                    u.role,
                    u.active AS user_active,
                    m.id AS msp_id,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents,
                    m.active AS msp_active
                FROM msp_login_challenges c
                JOIN msp_users u ON u.id = c.msp_user_id
                JOIN msps m ON m.id = u.msp_id
                WHERE c.token_hash = ?
                """,
                (token_hash,),
            ).fetchone()
        if row is None:
            return None
        expires_at = parse_iso(row["expires_at"])
        if row["consumed_at"] or expires_at is None or expires_at <= now:
            return None
        if not row["user_active"] or not row["msp_active"] or not msp_status_allows_login(row["msp_status"]):
            return None
        return row

    def set_msp_login_challenge_phone(self, *, raw_token: str, phone_number: str) -> sqlite3.Row | None:
        challenge = self.get_msp_login_challenge(raw_token)
        if challenge is None:
            return None
        normalized_phone = normalize_phone_number(phone_number)
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_login_challenges
                SET phone_number = ?, last_otp_sent_at = ?, updated_at = ?
                WHERE id = ?
                """,
                (normalized_phone, now, now, challenge["challenge_id"]),
            )
        return self.get_msp_login_challenge(raw_token)

    def increment_msp_login_challenge_attempts(self, raw_token: str) -> None:
        challenge = self.get_msp_login_challenge(raw_token)
        if challenge is None:
            return
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_login_challenges
                SET attempt_count = attempt_count + 1, updated_at = ?
                WHERE id = ?
                """,
                (now, challenge["challenge_id"]),
            )

    def consume_msp_login_challenge(self, raw_token: str) -> sqlite3.Row | None:
        challenge = self.get_msp_login_challenge(raw_token)
        if challenge is None:
            return None
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_login_challenges
                SET consumed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                (now, now, challenge["challenge_id"]),
            )
        return challenge

    def revoke_msp_login_challenge(self, raw_token: str) -> None:
        challenge = self.get_msp_login_challenge(raw_token)
        if challenge is None:
            return
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_login_challenges
                SET consumed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                (now, now, challenge["challenge_id"]),
            )

    def issue_msp_login_token(
        self,
        *,
        msp_user_id: str,
        purpose: str = "login",
        ttl_minutes: int = 20,
    ) -> str:
        raw_token = f"vml_{token_urlsafe(32)}"
        now = utcnow()
        expires_at = isoformat(now + timedelta(minutes=ttl_minutes))
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO msp_login_tokens (
                    id, msp_user_id, token_hash, purpose, expires_at, consumed_at, created_at
                ) VALUES (?, ?, ?, ?, ?, NULL, ?)
                """,
                (
                    prefixed_id("mlt"),
                    msp_user_id,
                    hash_secret(raw_token),
                    purpose,
                    expires_at,
                    isoformat(now),
                ),
            )
        return raw_token

    def get_msp_login_token(self, raw_token: str, *, purpose: str = "login") -> sqlite3.Row | None:
        token_hash = hash_secret(raw_token)
        now = utcnow()
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    t.id AS login_token_id,
                    t.expires_at,
                    t.consumed_at,
                    u.id AS msp_user_id,
                    u.email,
                    u.full_name,
                    u.role,
                    u.active AS user_active,
                    m.id AS msp_id,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.active AS msp_active,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM msp_login_tokens t
                JOIN msp_users u ON u.id = t.msp_user_id
                JOIN msps m ON m.id = u.msp_id
                WHERE t.token_hash = ? AND t.purpose = ?
                """,
                (token_hash, purpose),
            ).fetchone()
        if row is None:
            return None
        expires_at = parse_iso(row["expires_at"])
        if row["consumed_at"] or expires_at is None or expires_at <= now:
            return None
        if not row["user_active"] or not row["msp_active"] or not msp_status_allows_login(row["msp_status"]):
            return None
        return row

    def consume_msp_login_token(self, raw_token: str, *, purpose: str = "login") -> sqlite3.Row | None:
        now = utcnow()
        row = self.get_msp_login_token(raw_token, purpose=purpose)
        if row is None:
            return None
        with self._connect() as conn:
            conn.execute(
                "UPDATE msp_login_tokens SET consumed_at = ? WHERE id = ?",
                (isoformat(now), row["login_token_id"]),
            )
            conn.execute(
                "UPDATE msp_users SET last_login_at = ?, updated_at = ? WHERE id = ?",
                (isoformat(now), isoformat(now), row["msp_user_id"]),
            )
        return row

    def create_msp_session(self, *, msp_user_id: str, ttl_days: int = 30) -> MSPPortalSessionContext:
        raw_token = f"vms_{token_urlsafe(32)}"
        now = utcnow()
        expires_at = isoformat(now + timedelta(days=ttl_days))
        session_id = prefixed_id("msps")
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO msp_sessions (
                    id, msp_user_id, token_hash, expires_at, revoked_at, created_at, last_seen_at
                ) VALUES (?, ?, ?, ?, NULL, ?, ?)
                """,
                (
                    session_id,
                    msp_user_id,
                    hash_secret(raw_token),
                    expires_at,
                    isoformat(now),
                    isoformat(now),
                ),
            )
            conn.execute(
                "UPDATE msp_users SET last_login_at = ?, updated_at = ? WHERE id = ?",
                (isoformat(now), isoformat(now), msp_user_id),
            )
        context = self.get_msp_session(raw_token)
        if context is None:
            raise RuntimeError("Could not establish MSP session")
        return context

    def get_msp_session(self, raw_token: str) -> MSPPortalSessionContext | None:
        token_hash = hash_secret(raw_token)
        now = utcnow()
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    s.id AS session_id,
                    s.expires_at,
                    s.revoked_at,
                    u.id AS msp_user_id,
                    u.email,
                    u.phone_number,
                    u.full_name,
                    u.role,
                    u.active AS user_active,
                    m.id AS msp_id,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.active AS msp_active,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM msp_sessions s
                JOIN msp_users u ON u.id = s.msp_user_id
                JOIN msps m ON m.id = u.msp_id
                WHERE s.token_hash = ?
                """,
                (token_hash,),
            ).fetchone()
            if row is None:
                return None
            expires_at = parse_iso(row["expires_at"])
            if row["revoked_at"] or expires_at is None or expires_at <= now:
                return None
            if not row["user_active"] or not row["msp_active"] or not msp_status_allows_login(row["msp_status"]):
                return None
            conn.execute(
                "UPDATE msp_sessions SET last_seen_at = ? WHERE id = ?",
                (isoformat(now), row["session_id"]),
            )
        return MSPPortalSessionContext(
            session_token=raw_token,
            session_id=row["session_id"],
            msp_user_id=row["msp_user_id"],
            msp_id=row["msp_id"],
            msp_name=row["msp_name"],
            email=row["email"],
            phone_number=row["phone_number"],
            full_name=row["full_name"],
            role=normalize_msp_role(row["role"]),
            msp_status=normalize_msp_status(row["msp_status"]),
            billing_email=row["billing_email"],
            stripe_customer_id=row["stripe_customer_id"],
            seat_price_cents=int(row["seat_price_cents"]),
        )

    def revoke_msp_session(self, raw_token: str) -> None:
        token_hash = hash_secret(raw_token)
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE msp_sessions
                SET revoked_at = ?
                WHERE token_hash = ? AND revoked_at IS NULL
                """,
                (now, token_hash),
            )

    def issue_account_deletion_token(
        self,
        *,
        phone_number: str | None,
        user_id: str | None = None,
        identity: str | None = None,
        ttl_minutes: int = 20,
    ) -> dict[str, Any]:
        raw_token = f"vdel_{token_urlsafe(32)}"
        now = utcnow()
        expires_at = isoformat(now + timedelta(minutes=ttl_minutes))
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO account_deletion_tokens (
                    id, token_hash, phone_number, user_id, identity, expires_at, consumed_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                (
                    prefixed_id("adt"),
                    hash_secret(raw_token),
                    (phone_number or "").strip() or None,
                    (user_id or "").strip() or None,
                    (identity or "").strip() or None,
                    expires_at,
                    isoformat(now),
                ),
            )
        return {"deletion_token": raw_token, "expires_at": expires_at}

    def peek_account_deletion_token(self, raw_token: str) -> dict[str, Any] | None:
        token_hash = hash_secret(raw_token)
        now = utcnow()
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT id, phone_number, user_id, identity, expires_at, consumed_at, created_at
                FROM account_deletion_tokens
                WHERE token_hash = ?
                """,
                (token_hash,),
            ).fetchone()
        if row is None:
            return None
        expires_at = parse_iso(row["expires_at"])
        if row["consumed_at"] or expires_at is None or expires_at <= now:
            return None
        return dict(row)

    def consume_account_deletion_token(self, raw_token: str) -> dict[str, Any] | None:
        token_hash = hash_secret(raw_token)
        now = utcnow()
        consumed_at = isoformat(now)
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT id, phone_number, user_id, identity, expires_at, consumed_at, created_at
                FROM account_deletion_tokens
                WHERE token_hash = ?
                """,
                (token_hash,),
            ).fetchone()
            if row is None:
                return None
            expires_at = parse_iso(row["expires_at"])
            if row["consumed_at"] or expires_at is None or expires_at <= now:
                return None
            conn.execute(
                "UPDATE account_deletion_tokens SET consumed_at = ? WHERE id = ?",
                (consumed_at, row["id"]),
            )
        result = dict(row)
        result["consumed_at"] = consumed_at
        return result

    def create_organization(
        self,
        *,
        msp_id: str,
        name: str,
        external_ref: str | None = None,
        provisioned_seats: int | None = None,
        billing_exempt: bool = False,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        organization_id = prefixed_id("org")
        normalized_seat_limit = normalize_seat_limit(provisioned_seats)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO organizations (id, msp_id, name, external_ref, provisioned_seats, billing_exempt, active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                (
                    organization_id,
                    msp_id,
                    name.strip(),
                    (external_ref or "").strip() or None,
                    normalized_seat_limit,
                    1 if billing_exempt else 0,
                    now,
                    now,
                ),
            )
        return {
            "id": organization_id,
            "msp_id": msp_id,
            "name": name.strip(),
            "external_ref": (external_ref or "").strip() or None,
            "provisioned_seats": normalized_seat_limit,
            "billing_exempt": billing_exempt,
        }

    def get_organization_for_msp(self, *, msp_id: str, organization_id: str) -> sqlite3.Row | None:
        with self._connect() as conn:
            return conn.execute(
                """
                SELECT id, msp_id, name, external_ref, provisioned_seats, billing_exempt, active
                FROM organizations
                WHERE id = ? AND msp_id = ?
                """,
                (organization_id, msp_id),
            ).fetchone()

    def billing_exempt_organization_count(self, *, msp_id: str) -> int:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT COUNT(*) AS count
                FROM organizations
                WHERE msp_id = ? AND billing_exempt = 1 AND active = 1
                """,
                (msp_id,),
            ).fetchone()
        return int(row["count"] or 0)

    def update_organization_for_msp(
        self,
        *,
        msp_id: str,
        organization_id: str,
        external_ref: str | None = None,
        provisioned_seats: int | str | None = None,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        normalized_external_ref = (external_ref or "").strip() or None
        normalized_seat_limit = normalize_seat_limit(provisioned_seats)
        with self._connect() as conn:
            result = conn.execute(
                """
                UPDATE organizations
                SET
                    external_ref = ?,
                    provisioned_seats = ?,
                    updated_at = ?
                WHERE id = ? AND msp_id = ?
                """,
                (normalized_external_ref, normalized_seat_limit, now, organization_id, msp_id),
            )
            if result.rowcount == 0:
                raise KeyError("Organization not found")
        row = self.get_organization_for_msp(msp_id=msp_id, organization_id=organization_id)
        if row is None:
            raise KeyError("Organization not found")
        return dict(row)

    def create_access_code(
        self,
        *,
        organization_id: str,
        code: str,
        label: str | None = None,
        max_activations: int | None = None,
    ) -> dict[str, Any]:
        normalized_code = normalize_code(code)
        if not normalized_code:
            raise ValueError("Missing access code")
        now = isoformat(utcnow())
        access_code_id = prefixed_id("code")
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO organization_access_codes (
                    id, organization_id, label, code_hash, code_hint, active, max_activations, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                """,
                (
                    access_code_id,
                    organization_id,
                    (label or "").strip() or None,
                    hash_secret(normalized_code),
                    normalized_code[-4:],
                    max_activations,
                    now,
                    now,
                ),
            )
        return {
            "id": access_code_id,
            "organization_id": organization_id,
            "label": (label or "").strip() or None,
            "code_hint": normalized_code[-4:],
            "max_activations": max_activations,
        }

    def deactivate_access_code_for_msp(
        self,
        *,
        msp_id: str,
        organization_id: str,
        access_code_id: str,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    ac.id,
                    ac.label,
                    ac.code_hint,
                    ac.active,
                    o.id AS organization_id,
                    o.name AS organization_name
                FROM organization_access_codes ac
                JOIN organizations o ON o.id = ac.organization_id
                WHERE ac.id = ? AND ac.organization_id = ? AND o.msp_id = ?
                """,
                (access_code_id, organization_id, msp_id),
            ).fetchone()
            if row is None:
                raise KeyError("Access code not found")
            conn.execute(
                """
                UPDATE organization_access_codes
                SET active = 0, updated_at = ?
                WHERE id = ?
                """,
                (now, access_code_id),
            )
        return dict(row)

    def organization_membership_counts(
        self,
        *,
        organization_id: str,
        phone_number: str | None = None,
        access_code_id: str | None = None,
    ) -> dict[str, int]:
        normalized_phone = normalize_phone_number(phone_number)
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_seats,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' AND om.access_code_id = ? THEN om.id END) AS access_code_active_seats,
                    MAX(CASE WHEN om.status = 'active' AND om.phone_number = ? THEN 1 ELSE 0 END) AS phone_already_active,
                    MAX(CASE WHEN om.status = 'active' AND om.phone_number = ? AND om.access_code_id = ? THEN 1 ELSE 0 END) AS phone_already_active_on_code
                FROM organization_memberships om
                WHERE om.organization_id = ?
                """,
                (access_code_id, normalized_phone, normalized_phone, access_code_id, organization_id),
            ).fetchone()
        return {
            "active_seats": int(row["active_seats"] or 0),
            "access_code_active_seats": int(row["access_code_active_seats"] or 0),
            "phone_already_active": int(row["phone_already_active"] or 0),
            "phone_already_active_on_code": int(row["phone_already_active_on_code"] or 0),
        }

    def access_code_capacity(self, *, code: str, phone_number: str | None = None) -> dict[str, Any] | None:
        normalized_code = normalize_code(code)
        if not normalized_code:
            return None
        code_hash = hash_secret(normalized_code)
        normalized_phone = normalize_phone_number(phone_number)
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    ac.id AS access_code_id,
                    ac.max_activations,
                    o.id AS organization_id,
                    o.name AS organization_name,
                    o.provisioned_seats,
                    o.billing_exempt AS organization_billing_exempt,
                    o.active AS organization_active,
                    m.id AS msp_id,
                    m.status AS msp_status,
                    m.active AS msp_active,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_seats,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' AND om.access_code_id = ac.id THEN om.id END) AS access_code_active_seats,
                    MAX(CASE WHEN om.status = 'active' AND om.phone_number = ? THEN 1 ELSE 0 END) AS phone_already_active,
                    MAX(CASE WHEN om.status = 'active' AND om.phone_number = ? AND om.access_code_id = ac.id THEN 1 ELSE 0 END) AS phone_already_active_on_code
                FROM organization_access_codes ac
                JOIN organizations o ON o.id = ac.organization_id
                JOIN msps m ON m.id = o.msp_id
                LEFT JOIN organization_memberships om ON om.organization_id = o.id
                WHERE ac.code_hash = ? AND ac.active = 1
                GROUP BY ac.id
                """,
                (normalized_phone, normalized_phone, code_hash),
            ).fetchone()
        if row is None:
            return None
        return dict(row)

    def assert_access_code_capacity(self, *, code: str, phone_number: str | None = None) -> dict[str, Any] | None:
        row = self.access_code_capacity(code=code, phone_number=phone_number)
        if row is None:
            return None
        if not bool(row["organization_active"]) or not bool(row["msp_active"]):
            raise ValueError("This company is no longer active")
        if not msp_status_allows_production(row["msp_status"]):
            normalized_status = normalize_msp_status(row["msp_status"])
            if normalized_status == MSP_STATUS_PENDING_REVIEW:
                raise ValueError("This MSP is still pending review and cannot issue production access codes yet")
            if normalized_status == MSP_STATUS_SUSPENDED:
                raise ValueError("This MSP is suspended and cannot provision employee access")
            raise ValueError("This MSP cannot provision employee access right now")

        active_seats = int(row["active_seats"] or 0)
        access_code_active_seats = int(row["access_code_active_seats"] or 0)
        provisioned_seats = normalize_seat_limit(row["provisioned_seats"])
        max_activations = normalize_seat_limit(row["max_activations"])
        phone_already_active = bool(row["phone_already_active"])
        phone_already_active_on_code = bool(row["phone_already_active_on_code"])

        if provisioned_seats is not None and not phone_already_active and active_seats >= provisioned_seats:
            raise ValueError("This company has reached its provisioned seat limit")
        if max_activations is not None and not phone_already_active_on_code and access_code_active_seats >= max_activations:
            raise ValueError("This access code has no seats remaining")
        return row

    def validate_access_code(self, code: str) -> sqlite3.Row | None:
        normalized_code = normalize_code(code)
        if not normalized_code:
            return None
        code_hash = hash_secret(normalized_code)
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    ac.id AS access_code_id,
                    ac.organization_id,
                    o.name AS organization_name,
                    o.billing_exempt AS organization_billing_exempt,
                    o.active AS organization_active,
                    m.id AS msp_id,
                    m.name AS msp_name,
                    m.status AS msp_status,
                    m.active AS msp_active,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM organization_access_codes ac
                JOIN organizations o ON o.id = ac.organization_id
                JOIN msps m ON m.id = o.msp_id
                WHERE ac.code_hash = ? AND ac.active = 1
                """,
                (code_hash,),
            ).fetchone()
        return row

    def organization_context(
        self,
        *,
        organization_id: str,
        access_code_id: str | None = None,
    ) -> AccessGrantContext:
        with self._connect() as conn:
            if access_code_id:
                row = conn.execute(
                    """
                    SELECT
                        ac.id AS access_code_id,
                        ac.active AS access_code_active,
                        o.id AS organization_id,
                        o.name AS organization_name,
                        o.billing_exempt AS organization_billing_exempt,
                        o.active AS organization_active,
                        m.id AS msp_id,
                        m.name AS msp_name,
                        m.status AS msp_status,
                        m.active AS msp_active,
                        m.stripe_customer_id,
                        m.seat_price_cents
                    FROM organization_access_codes ac
                    JOIN organizations o ON o.id = ac.organization_id
                    JOIN msps m ON m.id = o.msp_id
                    WHERE o.id = ? AND ac.id = ?
                    """,
                    (organization_id, access_code_id),
                ).fetchone()
            else:
                row = conn.execute(
                    """
                    SELECT
                        ac.id AS access_code_id,
                        ac.active AS access_code_active,
                        o.id AS organization_id,
                        o.name AS organization_name,
                        o.billing_exempt AS organization_billing_exempt,
                        o.active AS organization_active,
                        m.id AS msp_id,
                        m.name AS msp_name,
                        m.status AS msp_status,
                        m.active AS msp_active,
                        m.stripe_customer_id,
                        m.seat_price_cents
                    FROM organizations o
                    JOIN msps m ON m.id = o.msp_id
                    LEFT JOIN organization_access_codes ac
                      ON ac.organization_id = o.id AND ac.active = 1
                    WHERE o.id = ?
                    ORDER BY ac.created_at ASC
                    LIMIT 1
                    """,
                    (organization_id,),
                ).fetchone()

        if row is None:
            raise KeyError("Organization not found")
        if not row["organization_active"] or not row["msp_active"]:
            raise KeyError("Organization is not active")
        if not msp_status_allows_production(row["msp_status"]):
            normalized_status = normalize_msp_status(row["msp_status"])
            if normalized_status == MSP_STATUS_PENDING_REVIEW:
                raise KeyError("MSP is pending review and cannot provision production access yet")
            if normalized_status == MSP_STATUS_SUSPENDED:
                raise KeyError("MSP is suspended and cannot provision production access")
            raise KeyError("MSP cannot provision production access")
        if not row["access_code_id"] or not row["access_code_active"]:
            raise KeyError("Organization does not have an active access code")

        return AccessGrantContext(
            organization_id=row["organization_id"],
            organization_name=row["organization_name"],
            msp_id=row["msp_id"],
            msp_name=row["msp_name"],
            access_code_id=row["access_code_id"],
            grant_token="manual_admin_activation",
            seat_price_cents=int(row["seat_price_cents"]),
            organization_billing_exempt=bool(row["organization_billing_exempt"]),
            stripe_customer_id=row["stripe_customer_id"],
        )

    def issue_access_grant(self, *, context_row: sqlite3.Row, phone_number: str | None = None) -> AccessGrantContext:
        raw_token = f"vicg_{token_urlsafe(32)}"
        now = utcnow()
        expires_at = isoformat(now + timedelta(minutes=int(os.getenv("ACCESS_GRANT_TTL_MINUTES", "30"))))
        normalized_phone = normalize_phone_number(phone_number)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO access_grants (
                    id, token_hash, organization_id, msp_id, access_code_id,
                    phone_number, expires_at, consumed_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                (
                    prefixed_id("grant"),
                    hash_secret(raw_token),
                    context_row["organization_id"],
                    context_row["msp_id"],
                    context_row["access_code_id"],
                    normalized_phone,
                    expires_at,
                    isoformat(now),
                ),
            )
        return AccessGrantContext(
            organization_id=context_row["organization_id"],
            organization_name=context_row["organization_name"],
            msp_id=context_row["msp_id"],
            msp_name=context_row["msp_name"],
            access_code_id=context_row["access_code_id"],
            grant_token=raw_token,
            seat_price_cents=int(context_row["seat_price_cents"]),
            organization_billing_exempt=bool(context_row["organization_billing_exempt"]),
            stripe_customer_id=context_row["stripe_customer_id"],
        )

    def grant_context(self, grant_token: str, *, phone_number: str | None = None, consume: bool = False) -> AccessGrantContext | None:
        token_hash = hash_secret(grant_token)
        now = utcnow()
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT
                    g.id AS grant_id,
                    g.organization_id,
                    g.msp_id,
                    g.access_code_id,
                    g.phone_number,
                    g.expires_at,
                    g.consumed_at,
                    o.name AS organization_name,
                    o.billing_exempt AS organization_billing_exempt,
                    m.name AS msp_name,
                    m.stripe_customer_id,
                    m.seat_price_cents
                FROM access_grants g
                JOIN organizations o ON o.id = g.organization_id
                JOIN msps m ON m.id = g.msp_id
                WHERE g.token_hash = ?
                """,
                (token_hash,),
            ).fetchone()
            if row is None:
                return None

            expires_at = parse_iso(row["expires_at"])
            if expires_at is None or expires_at <= now:
                return None
            if row["consumed_at"]:
                return None

            requested_phone = normalize_phone_number(phone_number)
            stored_phone = normalize_phone_number(row["phone_number"])
            if stored_phone and requested_phone and stored_phone != requested_phone:
                return None
            if requested_phone and not stored_phone:
                conn.execute(
                    "UPDATE access_grants SET phone_number = ? WHERE id = ?",
                    (requested_phone, row["grant_id"]),
                )
                stored_phone = requested_phone

            if consume:
                conn.execute(
                    "UPDATE access_grants SET consumed_at = ? WHERE id = ?",
                    (isoformat(now), row["grant_id"]),
                )

        return AccessGrantContext(
            organization_id=row["organization_id"],
            organization_name=row["organization_name"],
            msp_id=row["msp_id"],
            msp_name=row["msp_name"],
            access_code_id=row["access_code_id"],
            grant_token=grant_token,
            seat_price_cents=int(row["seat_price_cents"]),
            organization_billing_exempt=bool(row["organization_billing_exempt"]),
            stripe_customer_id=row["stripe_customer_id"],
        )

    def activate_membership(
        self,
        *,
        context: AccessGrantContext,
        phone_number: str,
        user_id: str | None,
    ) -> dict[str, Any]:
        normalized_phone = normalize_phone_number(phone_number)
        if not normalized_phone:
            raise ValueError("Phone number is required")
        now = isoformat(utcnow())
        with self._connect() as conn:
            code_row = conn.execute(
                """
                SELECT
                    ac.max_activations,
                    o.provisioned_seats,
                    o.billing_exempt AS organization_billing_exempt
                FROM organization_access_codes ac
                JOIN organizations o ON o.id = ac.organization_id
                WHERE ac.id = ? AND o.id = ?
                """,
                (context.access_code_id, context.organization_id),
            ).fetchone()
            existing = conn.execute(
                """
                SELECT id, first_verified_at, status, access_code_id
                FROM organization_memberships
                WHERE organization_id = ? AND phone_number = ?
                """,
                (context.organization_id, normalized_phone),
            ).fetchone()

            counts = self.organization_membership_counts(
                organization_id=context.organization_id,
                phone_number=normalized_phone,
                access_code_id=context.access_code_id,
            )
            is_existing_active = bool(existing and existing["status"] == "active")
            is_existing_active_on_code = bool(
                existing
                and existing["status"] == "active"
                and str(existing["access_code_id"] or "") == context.access_code_id
            )
            provisioned_seats = normalize_seat_limit(code_row["provisioned_seats"] if code_row else None)
            max_activations = normalize_seat_limit(code_row["max_activations"] if code_row else None)
            if provisioned_seats is not None and not is_existing_active and counts["active_seats"] >= provisioned_seats:
                raise ValueError("This company has reached its provisioned seat limit")
            if max_activations is not None and not is_existing_active_on_code and counts["access_code_active_seats"] >= max_activations:
                raise ValueError("This access code has no seats remaining")

            if existing:
                conn.execute(
                    """
                    UPDATE organization_memberships
                    SET
                        msp_id = ?,
                        user_id = COALESCE(?, user_id),
                        status = 'active',
                        access_code_id = ?,
                        last_verified_at = ?,
                        deactivated_at = NULL,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        context.msp_id,
                        user_id,
                        context.access_code_id,
                        now,
                        now,
                        existing["id"],
                    ),
                )
                membership_id = existing["id"]
                first_verified_at = existing["first_verified_at"]
                was_existing_membership = True
            else:
                membership_id = prefixed_id("mem")
                first_verified_at = now
                was_existing_membership = False
                conn.execute(
                    """
                    INSERT INTO organization_memberships (
                        id, organization_id, msp_id, phone_number, user_id, status,
                        access_code_id, first_verified_at, last_verified_at,
                        deactivated_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, NULL, ?, ?)
                    """,
                    (
                        membership_id,
                        context.organization_id,
                        context.msp_id,
                        normalized_phone,
                        user_id,
                        context.access_code_id,
                        now,
                        now,
                        now,
                        now,
                    ),
                )

        return {
            "membership_id": membership_id,
            "organization_id": context.organization_id,
            "msp_id": context.msp_id,
            "phone_number": normalized_phone,
            "user_id": user_id,
            "first_verified_at": first_verified_at,
            "last_verified_at": now,
            "status": "active",
            "was_existing_membership": was_existing_membership,
            "was_already_active": is_existing_active,
            "organization_billing_exempt": bool(code_row["organization_billing_exempt"]) if code_row else context.organization_billing_exempt,
        }

    def seat_billing_event_for_membership(
        self,
        *,
        membership_id: str,
        period_start: str,
    ) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT *
                FROM seat_billing_events
                WHERE membership_id = ? AND period_start = ?
                """,
                (membership_id, period_start),
            ).fetchone()
        return dict(row) if row else None

    def record_seat_billing_event(
        self,
        *,
        membership: dict[str, Any],
        period_start: str,
        seat_price_cents: int,
        amount_cents: int,
        stripe_invoice_id: str | None,
        stripe_invoice_item_id: str | None,
        hosted_invoice_url: str | None,
        status: str,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO seat_billing_events (
                    id, membership_id, organization_id, msp_id, phone_number, user_id,
                    period_start, seat_price_cents, amount_cents,
                    stripe_invoice_id, stripe_invoice_item_id, hosted_invoice_url,
                    status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(membership_id, period_start) DO UPDATE SET
                    organization_id = excluded.organization_id,
                    msp_id = excluded.msp_id,
                    phone_number = excluded.phone_number,
                    user_id = COALESCE(excluded.user_id, seat_billing_events.user_id),
                    seat_price_cents = excluded.seat_price_cents,
                    amount_cents = excluded.amount_cents,
                    stripe_invoice_id = COALESCE(seat_billing_events.stripe_invoice_id, excluded.stripe_invoice_id),
                    stripe_invoice_item_id = COALESCE(seat_billing_events.stripe_invoice_item_id, excluded.stripe_invoice_item_id),
                    hosted_invoice_url = COALESCE(excluded.hosted_invoice_url, seat_billing_events.hosted_invoice_url),
                    status = excluded.status,
                    updated_at = excluded.updated_at
                """,
                (
                    prefixed_id("seatbill"),
                    membership["membership_id"],
                    membership["organization_id"],
                    membership["msp_id"],
                    membership["phone_number"],
                    (membership.get("user_id") or None),
                    period_start,
                    int(seat_price_cents),
                    int(amount_cents),
                    (stripe_invoice_id or "").strip() or None,
                    (stripe_invoice_item_id or "").strip() or None,
                    (hosted_invoice_url or "").strip() or None,
                    (status or "").strip() or "open",
                    now,
                    now,
                ),
            )
            row = conn.execute(
                """
                SELECT *
                FROM seat_billing_events
                WHERE membership_id = ? AND period_start = ?
                """,
                (membership["membership_id"], period_start),
            ).fetchone()
        return dict(row) if row else {}

    def seat_billing_event_by_invoice_id(self, stripe_invoice_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT *
                FROM seat_billing_events
                WHERE stripe_invoice_id = ?
                """,
                (stripe_invoice_id,),
            ).fetchone()
        return dict(row) if row else None

    def update_seat_billing_event_status(
        self,
        *,
        stripe_invoice_id: str,
        status: str,
        hosted_invoice_url: str | None = None,
    ) -> dict[str, Any] | None:
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE seat_billing_events
                SET
                    status = ?,
                    hosted_invoice_url = COALESCE(?, hosted_invoice_url),
                    updated_at = ?
                WHERE stripe_invoice_id = ?
                """,
                (status, (hosted_invoice_url or "").strip() or None, now, stripe_invoice_id),
            )
            row = conn.execute(
                "SELECT * FROM seat_billing_events WHERE stripe_invoice_id = ?",
                (stripe_invoice_id,),
            ).fetchone()
        return dict(row) if row else None

    def seat_billing_events_for_msp(
        self,
        *,
        msp_id: str,
        period_start: str,
        limit: int | None = 200,
    ) -> list[dict[str, Any]]:
        limit_clause = "" if limit is None else "LIMIT ?"
        params: list[Any] = [msp_id, period_start]
        if limit is not None:
            params.append(max(int(limit), 1))
        with self._connect() as conn:
            rows = conn.execute(
                f"""
                SELECT
                    sbe.*,
                    o.name AS organization_name,
                    o.billing_exempt AS organization_billing_exempt,
                    om.status AS membership_status,
                    om.last_verified_at
                FROM seat_billing_events sbe
                JOIN organizations o ON o.id = sbe.organization_id
                LEFT JOIN organization_memberships om ON om.id = sbe.membership_id
                WHERE sbe.msp_id = ? AND sbe.period_start = ?
                ORDER BY sbe.created_at DESC
                {limit_clause}
                """,
                params,
            ).fetchall()
        return [dict(row) for row in rows]

    def deactivate_account_memberships(
        self,
        *,
        phone_number: str,
        user_id: str | None = None,
    ) -> dict[str, Any]:
        normalized_phone = normalize_phone_number(phone_number)
        normalized_user_id = (user_id or "").strip() or None
        if not normalized_phone and not normalized_user_id:
            return {"deactivated_memberships": 0, "organizations": []}

        now = isoformat(utcnow())
        clauses: list[str] = []
        params: list[Any] = []
        if normalized_phone:
            clauses.append("om.phone_number = ?")
            params.append(normalized_phone)
        if normalized_user_id:
            clauses.append("om.user_id = ?")
            params.append(normalized_user_id)
        where_clause = " OR ".join(clauses)

        with self._connect() as conn:
            rows = conn.execute(
                f"""
                SELECT
                    om.id,
                    om.organization_id,
                    om.msp_id,
                    om.phone_number,
                    om.user_id,
                    o.name AS organization_name,
                    m.name AS msp_name
                FROM organization_memberships om
                JOIN organizations o ON o.id = om.organization_id
                JOIN msps m ON m.id = om.msp_id
                WHERE ({where_clause}) AND om.status = 'active'
                """,
                params,
            ).fetchall()

            if rows:
                membership_ids = [row["id"] for row in rows]
                placeholders = ",".join("?" for _ in membership_ids)
                conn.execute(
                    f"""
                    UPDATE organization_memberships
                    SET status = 'inactive', deactivated_at = ?, updated_at = ?
                    WHERE id IN ({placeholders})
                    """,
                    [now, now, *membership_ids],
                )

        organizations = sorted({row["organization_id"] for row in rows})
        return {
            "deactivated_memberships": len(rows),
            "organizations": organizations,
            "memberships": [dict(row) for row in rows],
        }

    def deactivate_memberships_for_msp(
        self,
        *,
        msp_id: str,
        organization_id: str | None = None,
        phone_number: str,
        user_id: str | None = None,
    ) -> dict[str, Any]:
        normalized_phone = normalize_phone_number(phone_number)
        normalized_organization_id = (organization_id or "").strip() or None
        normalized_user_id = (user_id or "").strip() or None
        if not normalized_phone and not normalized_user_id:
            return {"deactivated_memberships": 0, "organizations": []}

        now = isoformat(utcnow())
        clauses: list[str] = []
        params: list[Any] = [msp_id]
        organization_filter = ""
        if normalized_organization_id:
            organization_filter = "AND organization_id = ?"
            params.append(normalized_organization_id)
        if normalized_phone:
            clauses.append("phone_number = ?")
            params.append(normalized_phone)
        if normalized_user_id:
            clauses.append("user_id = ?")
            params.append(normalized_user_id)
        where_clause = " OR ".join(clauses)

        with self._connect() as conn:
            rows = conn.execute(
                f"""
                SELECT id, organization_id
                FROM organization_memberships
                WHERE msp_id = ? {organization_filter} AND ({where_clause}) AND status = 'active'
                """,
                params,
            ).fetchall()

            if rows:
                membership_ids = [row["id"] for row in rows]
                placeholders = ",".join("?" for _ in membership_ids)
                conn.execute(
                    f"""
                    UPDATE organization_memberships
                    SET status = 'inactive', deactivated_at = ?, updated_at = ?
                    WHERE id IN ({placeholders})
                    """,
                    [now, now, *membership_ids],
                )

        organizations = sorted({row["organization_id"] for row in rows})
        return {
            "deactivated_memberships": len(rows),
            "organizations": organizations,
        }

    def deactivate_organization_for_msp(
        self,
        *,
        msp_id: str,
        organization_id: str,
    ) -> dict[str, Any]:
        normalized_org_id = (organization_id or "").strip()
        if not normalized_org_id:
            raise KeyError("Organization not found")

        now = isoformat(utcnow())
        with self._connect() as conn:
            org = conn.execute(
                """
                SELECT id, name, active
                FROM organizations
                WHERE id = ? AND msp_id = ?
                """,
                (normalized_org_id, msp_id),
            ).fetchone()
            if org is None:
                raise KeyError("Organization not found")

            active_memberships = conn.execute(
                """
                SELECT id
                FROM organization_memberships
                WHERE organization_id = ? AND status = 'active'
                """,
                (normalized_org_id,),
            ).fetchall()
            access_codes = conn.execute(
                """
                SELECT id
                FROM organization_access_codes
                WHERE organization_id = ? AND active = 1
                """,
                (normalized_org_id,),
            ).fetchall()
            grants = conn.execute(
                """
                SELECT id
                FROM access_grants
                WHERE organization_id = ? AND consumed_at IS NULL
                """,
                (normalized_org_id,),
            ).fetchall()

            if active_memberships:
                membership_ids = [row["id"] for row in active_memberships]
                placeholders = ",".join("?" for _ in membership_ids)
                conn.execute(
                    f"""
                    UPDATE organization_memberships
                    SET status = 'inactive', deactivated_at = ?, updated_at = ?
                    WHERE id IN ({placeholders})
                    """,
                    [now, now, *membership_ids],
                )

            if access_codes:
                access_code_ids = [row["id"] for row in access_codes]
                placeholders = ",".join("?" for _ in access_code_ids)
                conn.execute(
                    f"""
                    UPDATE organization_access_codes
                    SET active = 0, updated_at = ?
                    WHERE id IN ({placeholders})
                    """,
                    [now, *access_code_ids],
                )

            if grants:
                grant_ids = [row["id"] for row in grants]
                placeholders = ",".join("?" for _ in grant_ids)
                conn.execute(
                    f"""
                    UPDATE access_grants
                    SET consumed_at = ?
                    WHERE id IN ({placeholders})
                    """,
                    [now, *grant_ids],
                )

            conn.execute(
                """
                UPDATE organizations
                SET active = 0, updated_at = ?
                WHERE id = ?
                """,
                (now, normalized_org_id),
            )

        return {
            "organization_id": normalized_org_id,
            "organization_name": org["name"],
            "organization_was_active": bool(org["active"]),
            "deactivated_memberships": len(active_memberships),
            "deactivated_access_codes": len(access_codes),
            "expired_grants": len(grants),
        }

    def get_msp(self, msp_id: str) -> sqlite3.Row | None:
        with self._connect() as conn:
            return conn.execute("SELECT * FROM msps WHERE id = ?", (msp_id,)).fetchone()

    def set_msp_status(self, *, msp_id: str, status: str) -> dict[str, Any]:
        normalized_status = normalize_msp_status(status)
        active_flag = 0 if normalized_status == MSP_STATUS_CLOSED else 1
        now = isoformat(utcnow())
        with self._connect() as conn:
            result = conn.execute(
                """
                UPDATE msps
                SET status = ?, active = ?, updated_at = ?
                WHERE id = ?
                """,
                (normalized_status, active_flag, now, msp_id),
            )
            if result.rowcount == 0:
                raise KeyError("MSP not found")
        row = self.get_msp(msp_id)
        if row is None:
            raise KeyError("MSP not found")
        return dict(row)

    def record_msp_audit_event(
        self,
        *,
        msp_id: str,
        actor_type: str,
        action: str,
        status: str = "success",
        actor_msp_user_id: str | None = None,
        actor_email: str | None = None,
        actor_role: str | None = None,
        actor_label: str | None = None,
        target_type: str | None = None,
        target_id: str | None = None,
        organization_id: str | None = None,
        organization_name: str | None = None,
        event_metadata: dict[str, Any] | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> dict[str, Any]:
        now = isoformat(utcnow())
        row = {
            "id": prefixed_id("audit"),
            "msp_id": msp_id,
            "actor_type": (actor_type or "").strip() or "system",
            "actor_msp_user_id": (actor_msp_user_id or "").strip() or None,
            "actor_email": normalize_email(actor_email) if actor_email else None,
            "actor_role": normalize_msp_role(actor_role) if actor_role else None,
            "actor_label": (actor_label or "").strip() or None,
            "action": (action or "").strip(),
            "target_type": (target_type or "").strip() or None,
            "target_id": (target_id or "").strip() or None,
            "organization_id": (organization_id or "").strip() or None,
            "organization_name": (organization_name or "").strip() or None,
            "status": (status or "").strip() or "success",
            "event_metadata": dict(event_metadata or {}),
            "ip_address": (ip_address or "").strip() or None,
            "user_agent": (user_agent or "").strip() or None,
            "created_at": now,
        }
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO msp_audit_events (
                    id, msp_id, actor_type, actor_msp_user_id, actor_email, actor_role, actor_label,
                    action, target_type, target_id, organization_id, organization_name,
                    status, event_metadata, ip_address, user_agent, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["id"],
                    row["msp_id"],
                    row["actor_type"],
                    row["actor_msp_user_id"],
                    row["actor_email"],
                    row["actor_role"],
                    row["actor_label"],
                    row["action"],
                    row["target_type"],
                    row["target_id"],
                    row["organization_id"],
                    row["organization_name"],
                    row["status"],
                    json.dumps(row["event_metadata"], sort_keys=True),
                    row["ip_address"],
                    row["user_agent"],
                    row["created_at"],
                ),
            )
        return row

    def _audit_event_row_to_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        event = dict(row)
        metadata_raw = event.get("event_metadata")
        if metadata_raw:
            try:
                event["event_metadata"] = json.loads(metadata_raw)
            except json.JSONDecodeError:
                event["event_metadata"] = {"raw": metadata_raw}
        else:
            event["event_metadata"] = {}
        return event

    def list_msp_audit_actions(self, msp_id: str) -> list[str]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT DISTINCT action
                FROM msp_audit_events
                WHERE msp_id = ?
                ORDER BY action ASC
                """,
                (msp_id,),
            ).fetchall()
        return [str(row["action"]) for row in rows]

    def list_msp_audit_events(
        self,
        msp_id: str,
        *,
        actor_query: str | None = None,
        organization_query: str | None = None,
        action: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        where_clauses = ["msp_id = ?"]
        params: list[Any] = [msp_id]
        normalized_actor = (actor_query or "").strip()
        normalized_organization = (organization_query or "").strip()
        normalized_action = (action or "").strip()
        if normalized_actor:
            like = f"%{normalized_actor}%"
            where_clauses.append(
                "(COALESCE(actor_email, '') LIKE ? OR COALESCE(actor_label, '') LIKE ? OR COALESCE(actor_role, '') LIKE ?)"
            )
            params.extend([like, like, like])
        if normalized_organization:
            like = f"%{normalized_organization}%"
            where_clauses.append(
                "(COALESCE(organization_id, '') LIKE ? OR COALESCE(organization_name, '') LIKE ? OR COALESCE(target_id, '') LIKE ?)"
            )
            params.extend([like, like, like])
        if normalized_action:
            where_clauses.append("action = ?")
            params.append(normalized_action)
        where_sql = " AND ".join(where_clauses)
        with self._connect() as conn:
            rows = conn.execute(
                f"""
                SELECT
                    id, msp_id, actor_type, actor_msp_user_id, actor_email, actor_role, actor_label,
                    action, target_type, target_id, organization_id, organization_name,
                    status, event_metadata, ip_address, user_agent, created_at
                FROM msp_audit_events
                WHERE {where_sql}
                ORDER BY created_at DESC
                LIMIT ?
                """,
                [*params, max(int(limit), 1)],
            ).fetchall()
        return [self._audit_event_row_to_dict(row) for row in rows]

    def get_msp_by_portal_key(self, portal_key: str) -> sqlite3.Row | None:
        hashed = hash_secret(portal_key)
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM msps WHERE portal_api_key_hash = ? AND active = 1",
                (hashed,),
            ).fetchone()
        return row

    def set_msp_stripe_customer(self, msp_id: str, stripe_customer_id: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE msps SET stripe_customer_id = ?, updated_at = ? WHERE id = ?",
                (stripe_customer_id, isoformat(utcnow()), msp_id),
            )

    def admin_overview(self) -> dict[str, Any]:
        with self._connect() as conn:
            counts = conn.execute(
                """
                SELECT
                    (SELECT COUNT(*) FROM msps WHERE active = 1) AS msp_count,
                    (SELECT COUNT(*) FROM organizations WHERE active = 1) AS organization_count,
                    (SELECT COUNT(*) FROM organization_access_codes WHERE active = 1) AS access_code_count,
                    (SELECT COUNT(*) FROM organization_memberships WHERE status = 'active') AS active_membership_count
                """
            ).fetchone()
            msps = conn.execute(
                """
                SELECT
                    m.id,
                    m.name,
                    m.billing_email,
                    m.stripe_customer_id,
                    m.seat_price_cents,
                    m.status,
                    m.portal_api_key_hint,
                    COUNT(DISTINCT o.id) AS organization_count,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_memberships
                FROM msps m
                LEFT JOIN organizations o ON o.msp_id = m.id AND o.active = 1
                LEFT JOIN organization_memberships om ON om.msp_id = m.id AND om.status = 'active'
                WHERE m.active = 1
                GROUP BY m.id
                ORDER BY m.created_at ASC
                """
            ).fetchall()

        return {
            "msp_count": int(counts["msp_count"]),
            "organization_count": int(counts["organization_count"]),
            "access_code_count": int(counts["access_code_count"]),
            "active_membership_count": int(counts["active_membership_count"]),
            "msps": [dict(row) for row in msps],
        }

    def msp_summary(self, msp_id: str) -> dict[str, Any]:
        with self._connect() as conn:
            msp = conn.execute(
                "SELECT id, name, billing_email, stripe_customer_id, seat_price_cents, status, portal_api_key_hint FROM msps WHERE id = ?",
                (msp_id,),
            ).fetchone()
            if msp is None:
                raise KeyError("MSP not found")

            organizations = conn.execute(
                """
                SELECT
                    o.id,
                    o.name,
                    o.external_ref,
                    o.provisioned_seats,
                    o.billing_exempt,
                    o.active,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_seats,
                    COUNT(DISTINCT CASE WHEN ac.active = 1 THEN ac.id END) AS active_access_codes,
                    MAX(om.last_verified_at) AS last_verified_at
                FROM organizations o
                LEFT JOIN organization_memberships om ON om.organization_id = o.id
                LEFT JOIN organization_access_codes ac ON ac.organization_id = o.id
                WHERE o.msp_id = ?
                GROUP BY o.id
                ORDER BY o.created_at ASC
                """,
                (msp_id,),
            ).fetchall()

            recent_memberships = conn.execute(
                """
                SELECT organization_id, phone_number, user_id, last_verified_at
                FROM organization_memberships
                WHERE msp_id = ? AND status = 'active'
                ORDER BY last_verified_at DESC
                LIMIT 25
                """,
                (msp_id,),
            ).fetchall()

        return {
            "msp": dict(msp),
            "organizations": [dict(row) for row in organizations],
            "recent_memberships": [dict(row) for row in recent_memberships],
        }

    def organization_page_for_msp(
        self,
        msp_id: str,
        *,
        query: str | None = None,
        status: str = "all",
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, Any]:
        normalized_query = (query or "").strip()
        normalized_status = (status or "all").strip().lower()
        where_clauses = ["o.msp_id = ?"]
        params: list[Any] = [msp_id]
        if normalized_status == "active":
            where_clauses.append("o.active = 1")
        elif normalized_status == "offboarded":
            where_clauses.append("o.active = 0")
        if normalized_query:
            like = f"%{normalized_query}%"
            where_clauses.append("(o.name LIKE ? OR o.id LIKE ? OR COALESCE(o.external_ref, '') LIKE ?)")
            params.extend([like, like, like])

        where_sql = " AND ".join(where_clauses)
        with self._connect() as conn:
            total_count = int(
                conn.execute(
                    f"SELECT COUNT(*) AS count FROM organizations o WHERE {where_sql}",
                    params,
                ).fetchone()["count"]
            )
            rows = conn.execute(
                f"""
                SELECT
                    o.id,
                    o.name,
                    o.external_ref,
                    o.provisioned_seats,
                    o.billing_exempt,
                    o.active,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_seats,
                    COUNT(DISTINCT CASE WHEN om.status = 'inactive' THEN om.id END) AS inactive_seats,
                    COUNT(DISTINCT CASE WHEN ac.active = 1 THEN ac.id END) AS active_access_codes,
                    MAX(om.last_verified_at) AS last_verified_at
                FROM organizations o
                LEFT JOIN organization_memberships om ON om.organization_id = o.id
                LEFT JOIN organization_access_codes ac ON ac.organization_id = o.id
                WHERE {where_sql}
                GROUP BY o.id
                ORDER BY o.name ASC
                LIMIT ? OFFSET ?
                """,
                [*params, int(limit), int(offset)],
            ).fetchall()
        return {
            "rows": [dict(row) for row in rows],
            "total_count": total_count,
            "query": normalized_query,
            "status": normalized_status,
            "limit": int(limit),
            "offset": int(offset),
        }

    def organization_rows_for_msp(self, msp_id: str) -> list[dict[str, Any]]:
        return self.organization_page_for_msp(msp_id, limit=10000, offset=0)["rows"]

    def membership_rows_for_msp(self, msp_id: str) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    om.id,
                    om.organization_id,
                    o.name AS organization_name,
                    om.phone_number,
                    om.user_id,
                    om.status,
                    om.first_verified_at,
                    om.last_verified_at,
                    om.deactivated_at
                FROM organization_memberships om
                JOIN organizations o ON o.id = om.organization_id
                WHERE om.msp_id = ?
                ORDER BY o.name ASC, om.last_verified_at DESC
                """,
                (msp_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def access_code_rows_for_organization(self, *, msp_id: str, organization_id: str) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    ac.id,
                    ac.organization_id,
                    ac.label,
                    ac.code_hint,
                    ac.max_activations,
                    ac.active,
                    ac.created_at,
                    COUNT(DISTINCT CASE WHEN om.status = 'active' THEN om.id END) AS active_memberships,
                    COUNT(DISTINCT CASE WHEN om.status = 'inactive' THEN om.id END) AS inactive_memberships
                FROM organization_access_codes ac
                JOIN organizations o ON o.id = ac.organization_id
                LEFT JOIN organization_memberships om ON om.access_code_id = ac.id
                WHERE ac.organization_id = ? AND o.msp_id = ?
                GROUP BY ac.id
                ORDER BY ac.created_at ASC
                """,
                (organization_id, msp_id),
            ).fetchall()
        return [dict(row) for row in rows]

    def membership_rows_for_organization(self, *, msp_id: str, organization_id: str) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    om.id,
                    om.organization_id,
                    o.name AS organization_name,
                    om.phone_number,
                    om.user_id,
                    om.status,
                    om.access_code_id,
                    ac.label AS access_code_label,
                    ac.code_hint AS access_code_hint,
                    om.first_verified_at,
                    om.last_verified_at,
                    om.deactivated_at
                FROM organization_memberships om
                JOIN organizations o ON o.id = om.organization_id
                LEFT JOIN organization_access_codes ac ON ac.id = om.access_code_id
                WHERE om.organization_id = ? AND om.msp_id = ?
                ORDER BY
                    CASE WHEN om.status = 'active' THEN 0 ELSE 1 END,
                    om.last_verified_at DESC
                """,
                (organization_id, msp_id),
            ).fetchall()
        return [dict(row) for row in rows]

    def organization_detail_for_msp(self, *, msp_id: str, organization_id: str) -> dict[str, Any]:
        organization = self.get_organization_for_msp(msp_id=msp_id, organization_id=organization_id)
        if organization is None:
            raise KeyError("Organization not found")
        access_codes = self.access_code_rows_for_organization(msp_id=msp_id, organization_id=organization_id)
        memberships = self.membership_rows_for_organization(msp_id=msp_id, organization_id=organization_id)
        active_seats = sum(1 for row in memberships if row["status"] == "active")
        inactive_seats = sum(1 for row in memberships if row["status"] != "active")
        provisioned_seats = normalize_seat_limit(organization["provisioned_seats"])
        return {
            "organization": {
                **dict(organization),
                "active_seats": active_seats,
                "inactive_seats": inactive_seats,
                "provisioned_seats": provisioned_seats,
                "remaining_seats": (
                    max(provisioned_seats - active_seats, 0)
                    if provisioned_seats is not None
                    else None
                ),
            },
            "access_codes": access_codes,
            "memberships": memberships,
        }

    def _active_voice_memberships_for_phone(
        self,
        conn: sqlite3.Connection,
        phone_number: str | None,
        *,
        membership_id: str | None = None,
        organization_id: str | None = None,
        msp_id: str | None = None,
    ) -> list[sqlite3.Row]:
        normalized_phone = normalize_phone_number(phone_number)
        if not normalized_phone:
            return []

        filters = [
            "om.phone_number = ?",
            "om.status = 'active'",
            "o.active = 1",
            "m.active = 1",
            "m.status = ?",
        ]
        params: list[Any] = [normalized_phone, MSP_STATUS_ACTIVE]
        if membership_id:
            filters.append("om.id = ?")
            params.append(membership_id.strip())
        if organization_id:
            filters.append("om.organization_id = ?")
            params.append(organization_id.strip())
        if msp_id:
            filters.append("om.msp_id = ?")
            params.append(msp_id.strip())

        query = f"""
            SELECT
                om.id AS membership_id,
                om.organization_id,
                om.msp_id,
                om.phone_number,
                om.user_id,
                o.name AS organization_name,
                m.name AS msp_name,
                m.status AS msp_status
            FROM organization_memberships om
            JOIN organizations o ON o.id = om.organization_id
            JOIN msps m ON m.id = om.msp_id
            WHERE {' AND '.join(filters)}
            ORDER BY om.last_verified_at DESC
            """
        return conn.execute(query, tuple(params)).fetchall()

    def _active_voice_membership_for_phone(
        self,
        conn: sqlite3.Connection,
        phone_number: str | None,
        *,
        membership_id: str | None = None,
        organization_id: str | None = None,
        msp_id: str | None = None,
        require_unambiguous: bool = False,
    ) -> sqlite3.Row | None:
        rows = self._active_voice_memberships_for_phone(
            conn,
            phone_number,
            membership_id=membership_id,
            organization_id=organization_id,
            msp_id=msp_id,
        )
        if require_unambiguous and len(rows) > 1:
            raise AmbiguousVoiceMembershipError(
                "Multiple active Vicall accounts match this phone. Select the MSP/company account before calling."
            )
        return rows[0] if rows else None

    def active_voice_memberships_for_identity(
        self,
        identity: str | None,
        *,
        membership_id: str | None = None,
        organization_id: str | None = None,
        msp_id: str | None = None,
    ) -> list[dict[str, Any]]:
        normalized_identity = normalize_twilio_identity(identity)
        phone_number = phone_number_from_twilio_identity(normalized_identity)
        if not phone_number and normalized_identity and normalized_identity.startswith("+"):
            phone_number = normalize_phone_number(normalized_identity)
        if not phone_number:
            return []

        with self._connect() as conn:
            rows = self._active_voice_memberships_for_phone(
                conn,
                phone_number,
                membership_id=membership_id,
                organization_id=organization_id,
                msp_id=msp_id,
            )

        return [
            {
                **dict(row),
                "identity": normalized_identity,
                "phone_number": row["phone_number"],
            }
            for row in rows
        ]

    def active_voice_membership_for_identity(
        self,
        identity: str | None,
        *,
        membership_id: str | None = None,
        organization_id: str | None = None,
        msp_id: str | None = None,
        require_unambiguous: bool = False,
    ) -> dict[str, Any] | None:
        normalized_identity = normalize_twilio_identity(identity)
        phone_number = phone_number_from_twilio_identity(normalized_identity)
        if not phone_number and normalized_identity and normalized_identity.startswith("+"):
            phone_number = normalize_phone_number(normalized_identity)
        if not phone_number:
            return None

        with self._connect() as conn:
            row = self._active_voice_membership_for_phone(
                conn,
                phone_number,
                membership_id=membership_id,
                organization_id=organization_id,
                msp_id=msp_id,
                require_unambiguous=require_unambiguous,
            )

        if row is None:
            return None
        return {
            **dict(row),
            "identity": normalized_identity,
            "phone_number": row["phone_number"],
        }

    def _resolve_call_identity(
        self,
        conn: sqlite3.Connection,
        identity: str | None,
        *,
        membership_id: str | None = None,
        organization_id: str | None = None,
        msp_id: str | None = None,
    ) -> dict[str, Any]:
        normalized_identity = normalize_twilio_identity(identity)
        phone_number = phone_number_from_twilio_identity(normalized_identity)
        if not phone_number and normalized_identity and normalized_identity.startswith("+"):
            phone_number = normalize_phone_number(normalized_identity)

        row = self._active_voice_membership_for_phone(
            conn,
            phone_number,
            membership_id=membership_id,
            organization_id=organization_id,
            msp_id=msp_id,
        )

        return {
            "identity": normalized_identity,
            "phone_number": row["phone_number"] if row else phone_number,
            "membership_id": row["membership_id"] if row else None,
            "organization_id": row["organization_id"] if row else None,
            "organization_name": row["organization_name"] if row else None,
            "msp_id": row["msp_id"] if row else None,
            "msp_name": row["msp_name"] if row else None,
            "user_id": row["user_id"] if row else None,
            "msp_status": row["msp_status"] if row else None,
        }

    def _upsert_call_participant(
        self,
        conn: sqlite3.Connection,
        *,
        call_session_id: str,
        role: str,
        resolved_identity: dict[str, Any],
        now: str,
    ) -> None:
        identity = resolved_identity.get("identity")
        if not identity:
            return

        conn.execute(
            """
            INSERT INTO call_participants (
                id, call_session_id, identity, role, phone_number, user_id,
                membership_id, organization_id, organization_name, msp_id, msp_name,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(call_session_id, identity) DO UPDATE SET
                role = excluded.role,
                phone_number = COALESCE(excluded.phone_number, call_participants.phone_number),
                user_id = COALESCE(excluded.user_id, call_participants.user_id),
                membership_id = COALESCE(excluded.membership_id, call_participants.membership_id),
                organization_id = COALESCE(excluded.organization_id, call_participants.organization_id),
                organization_name = COALESCE(excluded.organization_name, call_participants.organization_name),
                msp_id = COALESCE(excluded.msp_id, call_participants.msp_id),
                msp_name = COALESCE(excluded.msp_name, call_participants.msp_name),
                updated_at = excluded.updated_at
            """,
            (
                prefixed_id("part"),
                call_session_id,
                identity,
                role,
                resolved_identity.get("phone_number"),
                resolved_identity.get("user_id"),
                resolved_identity.get("membership_id"),
                resolved_identity.get("organization_id"),
                resolved_identity.get("organization_name"),
                resolved_identity.get("msp_id"),
                resolved_identity.get("msp_name"),
                now,
                now,
            ),
        )

    def record_call_event(
        self,
        *,
        canonical_key: str | None,
        room: str | None = None,
        caller_identity: str | None = None,
        callee_identity: str | None = None,
        caller_membership_id: str | None = None,
        caller_organization_id: str | None = None,
        caller_msp_id: str | None = None,
        callee_membership_id: str | None = None,
        callee_organization_id: str | None = None,
        callee_msp_id: str | None = None,
        twilio_call_sid: str | None = None,
        parent_call_sid: str | None = None,
        leg_role: str | None = None,
        status: str | None = None,
        callback_event: str | None = None,
        duration_seconds: int | None = None,
        event_at: datetime | None = None,
    ) -> dict[str, Any] | None:
        normalized_call_sid = (twilio_call_sid or "").strip()
        normalized_parent_sid = (parent_call_sid or "").strip() or None
        normalized_key = (canonical_key or "").strip()
        if not normalized_key:
            fallback_sid = normalized_parent_sid or normalized_call_sid
            if not fallback_sid:
                return None
            normalized_key = f"call:{fallback_sid}"

        normalized_status = (status or "").strip().lower()
        normalized_event = (callback_event or "").strip().lower()
        event_name = normalized_event or normalized_status
        now = isoformat(event_at or utcnow())
        positive_duration = max(int(duration_seconds or 0), 0) if duration_seconds is not None else None

        with self._connect() as conn:
            caller = self._resolve_call_identity(
                conn,
                caller_identity,
                membership_id=caller_membership_id,
                organization_id=caller_organization_id,
                msp_id=caller_msp_id,
            )
            callee = self._resolve_call_identity(
                conn,
                callee_identity,
                membership_id=callee_membership_id,
                organization_id=callee_organization_id,
                msp_id=callee_msp_id,
            )
            existing = conn.execute(
                "SELECT * FROM call_sessions WHERE canonical_key = ?",
                (normalized_key,),
            ).fetchone()

            session_id = existing["id"] if existing else prefixed_id("call")
            msp_id = caller["msp_id"] or callee["msp_id"] or (existing["msp_id"] if existing else None)
            started_at = existing["started_at"] if existing else None
            answered_at = existing["answered_at"] if existing else None
            completed_at = existing["completed_at"] if existing else None

            if not started_at and (normalized_status in STARTED_CALL_STATUSES or event_name in STARTED_CALL_STATUSES):
                started_at = now
            if not answered_at and (normalized_status in ANSWERED_CALL_STATUSES or event_name in ANSWERED_CALL_STATUSES):
                answered_at = now
            if normalized_status in COMPLETED_CALL_STATUSES or event_name in COMPLETED_CALL_STATUSES:
                completed_at = now

            session_status = normalized_status or event_name or (existing["status"] if existing else "unknown")
            if not existing:
                conn.execute(
                    """
                    INSERT INTO call_sessions (
                        id, canonical_key, room, caller_identity, callee_identity,
                        caller_phone_number, callee_phone_number,
                        caller_organization_id, callee_organization_id, msp_id,
                        status, started_at, answered_at, completed_at,
                        duration_seconds, billable_seconds, billable_minutes,
                        last_event_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?, ?)
                    """,
                    (
                        session_id,
                        normalized_key,
                        (room or "").strip() or None,
                        caller["identity"],
                        callee["identity"],
                        caller["phone_number"],
                        callee["phone_number"],
                        caller["organization_id"],
                        callee["organization_id"],
                        msp_id,
                        session_status,
                        started_at,
                        answered_at,
                        completed_at,
                        now,
                        now,
                        now,
                    ),
                )
            else:
                conn.execute(
                    """
                    UPDATE call_sessions
                    SET
                        room = COALESCE(?, room),
                        caller_identity = COALESCE(caller_identity, ?),
                        callee_identity = COALESCE(callee_identity, ?),
                        caller_phone_number = COALESCE(caller_phone_number, ?),
                        callee_phone_number = COALESCE(callee_phone_number, ?),
                        caller_organization_id = COALESCE(caller_organization_id, ?),
                        callee_organization_id = COALESCE(callee_organization_id, ?),
                        msp_id = COALESCE(msp_id, ?),
                        status = ?,
                        started_at = COALESCE(started_at, ?),
                        answered_at = COALESCE(answered_at, ?),
                        completed_at = COALESCE(?, completed_at),
                        last_event_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        (room or "").strip() or None,
                        caller["identity"],
                        callee["identity"],
                        caller["phone_number"],
                        callee["phone_number"],
                        caller["organization_id"],
                        callee["organization_id"],
                        msp_id,
                        session_status,
                        started_at,
                        answered_at,
                        completed_at,
                        now,
                        now,
                        session_id,
                    ),
                )

            self._upsert_call_participant(
                conn,
                call_session_id=session_id,
                role="caller",
                resolved_identity=caller,
                now=now,
            )
            self._upsert_call_participant(
                conn,
                call_session_id=session_id,
                role="callee",
                resolved_identity=callee,
                now=now,
            )

            if normalized_call_sid:
                existing_leg = conn.execute(
                    "SELECT * FROM call_session_legs WHERE twilio_call_sid = ?",
                    (normalized_call_sid,),
                ).fetchone()
                initiated_at = existing_leg["initiated_at"] if existing_leg else None
                ringing_at = existing_leg["ringing_at"] if existing_leg else None
                leg_answered_at = existing_leg["answered_at"] if existing_leg else None
                leg_completed_at = existing_leg["completed_at"] if existing_leg else None
                if not initiated_at and event_name == "initiated":
                    initiated_at = now
                if not ringing_at and event_name == "ringing":
                    ringing_at = now
                if not leg_answered_at and (normalized_status in ANSWERED_CALL_STATUSES or event_name in ANSWERED_CALL_STATUSES):
                    leg_answered_at = now
                if normalized_status in COMPLETED_CALL_STATUSES or event_name in COMPLETED_CALL_STATUSES:
                    leg_completed_at = now

                existing_leg_duration = int(existing_leg["duration_seconds"]) if existing_leg else 0
                leg_duration = max(existing_leg_duration, positive_duration or 0)
                if existing_leg:
                    conn.execute(
                        """
                        UPDATE call_session_legs
                        SET
                            call_session_id = ?,
                            parent_call_sid = COALESCE(?, parent_call_sid),
                            leg_role = COALESCE(?, leg_role),
                            from_identity = COALESCE(?, from_identity),
                            to_identity = COALESCE(?, to_identity),
                            status = COALESCE(?, status),
                            callback_event = COALESCE(?, callback_event),
                            initiated_at = COALESCE(initiated_at, ?),
                            ringing_at = COALESCE(ringing_at, ?),
                            answered_at = COALESCE(answered_at, ?),
                            completed_at = COALESCE(?, completed_at),
                            duration_seconds = ?,
                            last_event_at = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                        (
                            session_id,
                            normalized_parent_sid,
                            (leg_role or "").strip() or None,
                            caller["identity"],
                            callee["identity"],
                            normalized_status or None,
                            normalized_event or None,
                            initiated_at,
                            ringing_at,
                            leg_answered_at,
                            leg_completed_at,
                            leg_duration,
                            now,
                            now,
                            existing_leg["id"],
                        ),
                    )
                else:
                    conn.execute(
                        """
                        INSERT INTO call_session_legs (
                            id, call_session_id, twilio_call_sid, parent_call_sid, leg_role,
                            from_identity, to_identity, status, callback_event,
                            initiated_at, ringing_at, answered_at, completed_at,
                            duration_seconds, last_event_at, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            prefixed_id("leg"),
                            session_id,
                            normalized_call_sid,
                            normalized_parent_sid,
                            (leg_role or "").strip() or None,
                            caller["identity"],
                            callee["identity"],
                            normalized_status or None,
                            normalized_event or None,
                            initiated_at,
                            ringing_at,
                            leg_answered_at,
                            leg_completed_at,
                            leg_duration,
                            now,
                            now,
                            now,
                        ),
                    )

            session_row = conn.execute(
                "SELECT duration_seconds, billable_seconds, answered_at FROM call_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            existing_duration = int(session_row["duration_seconds"] or 0)
            session_duration = existing_duration
            if positive_duration is not None:
                session_duration = max(session_duration, positive_duration)
            elif completed_at and session_row["answered_at"]:
                answered = parse_iso(session_row["answered_at"])
                completed = parse_iso(completed_at)
                if answered and completed and completed > answered:
                    session_duration = max(session_duration, int((completed - answered).total_seconds()))

            conn.execute(
                """
                UPDATE call_sessions
                SET
                    duration_seconds = ?,
                    billable_seconds = ?,
                    billable_minutes = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (
                    session_duration,
                    session_duration,
                    billable_minutes_for_seconds(session_duration),
                    now,
                    session_id,
                ),
            )

            final_row = conn.execute(
                "SELECT * FROM call_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
        return dict(final_row) if final_row else None

    def call_usage_rollup(self, *, msp_id: str, period_start_value: datetime | None = None) -> dict[str, Any]:
        period = month_start(period_start_value)
        period_end = next_month_start(period)
        period_key = isoformat(period)
        period_end_key = isoformat(period_end)
        org_rollups: dict[str, dict[str, Any]] = {}
        user_rollups: dict[tuple[str, str], dict[str, Any]] = {}
        seen_org_sessions: set[tuple[str, str]] = set()
        seen_user_sessions: set[tuple[str, str, str]] = set()

        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    s.id AS call_session_id,
                    s.billable_seconds,
                    s.billable_minutes,
                    p.membership_id,
                    p.organization_id,
                    p.organization_name,
                    p.msp_id,
                    p.phone_number,
                    p.user_id
                FROM call_sessions s
                JOIN call_participants p ON p.call_session_id = s.id
                WHERE
                    p.msp_id = ?
                    AND p.organization_id IS NOT NULL
                    AND p.phone_number IS NOT NULL
                    AND s.completed_at >= ?
                    AND s.completed_at < ?
                    AND s.billable_seconds > 0
                ORDER BY s.completed_at ASC
                """,
                (msp_id, period_key, period_end_key),
            ).fetchall()

        for row in rows:
            call_session_id = row["call_session_id"]
            organization_id = row["organization_id"]
            phone_number = row["phone_number"]
            seconds = int(row["billable_seconds"] or 0)
            minutes = int(row["billable_minutes"] or billable_minutes_for_seconds(seconds))

            org_key = (call_session_id, organization_id)
            if org_key not in seen_org_sessions:
                seen_org_sessions.add(org_key)
                org_rollup = org_rollups.setdefault(
                    organization_id,
                    {
                        "organization_id": organization_id,
                        "organization_name": row["organization_name"],
                        "msp_id": row["msp_id"],
                        "period_start": period_key,
                        "call_count": 0,
                        "billable_seconds": 0,
                        "billable_minutes": 0,
                    },
                )
                org_rollup["call_count"] += 1
                org_rollup["billable_seconds"] += seconds
                org_rollup["billable_minutes"] += minutes

            user_key = (organization_id, phone_number)
            user_session_key = (call_session_id, organization_id, phone_number)
            if user_session_key in seen_user_sessions:
                continue
            seen_user_sessions.add(user_session_key)
            user_rollup = user_rollups.setdefault(
                user_key,
                {
                    "membership_id": row["membership_id"],
                    "organization_id": organization_id,
                    "organization_name": row["organization_name"],
                    "msp_id": row["msp_id"],
                    "phone_number": phone_number,
                    "user_id": row["user_id"],
                    "period_start": period_key,
                    "call_count": 0,
                    "billable_seconds": 0,
                    "billable_minutes": 0,
                },
            )
            user_rollup["membership_id"] = user_rollup["membership_id"] or row["membership_id"]
            user_rollup["user_id"] = user_rollup["user_id"] or row["user_id"]
            user_rollup["call_count"] += 1
            user_rollup["billable_seconds"] += seconds
            user_rollup["billable_minutes"] += minutes

        return {
            "period_start": period_key,
            "period_end": period_end_key,
            "organizations": list(org_rollups.values()),
            "users": list(user_rollups.values()),
        }

    def refresh_monthly_usage_snapshots(
        self,
        *,
        msp_id: str,
        period_start_value: datetime | None = None,
    ) -> dict[str, Any]:
        rollup = self.call_usage_rollup(msp_id=msp_id, period_start_value=period_start_value)
        now = isoformat(utcnow())
        with self._connect() as conn:
            for row in rollup["users"]:
                conn.execute(
                    """
                    INSERT INTO user_usage_monthly (
                        id, membership_id, organization_id, msp_id, phone_number, user_id,
                        period_start, call_count, billable_seconds, billable_minutes,
                        created_at, updated_at
                    ) VALUES (
                        COALESCE((SELECT id FROM user_usage_monthly WHERE organization_id = ? AND phone_number = ? AND period_start = ?), ?),
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    ON CONFLICT(organization_id, phone_number, period_start) DO UPDATE SET
                        membership_id = excluded.membership_id,
                        msp_id = excluded.msp_id,
                        user_id = excluded.user_id,
                        call_count = excluded.call_count,
                        billable_seconds = excluded.billable_seconds,
                        billable_minutes = excluded.billable_minutes,
                        updated_at = excluded.updated_at
                    """,
                    (
                        row["organization_id"],
                        row["phone_number"],
                        row["period_start"],
                        prefixed_id("userusage"),
                        row["membership_id"],
                        row["organization_id"],
                        row["msp_id"],
                        row["phone_number"],
                        row["user_id"],
                        row["period_start"],
                        row["call_count"],
                        row["billable_seconds"],
                        row["billable_minutes"],
                        now,
                        now,
                    ),
                )
        return rollup

    def record_usage_snapshot(
        self,
        *,
        msp_id: str,
        snapshot: dict[str, Any],
    ) -> dict[str, Any]:
        period_start = str(snapshot["period_start"])
        now = isoformat(utcnow())
        user_rows = list(snapshot.get("user_usage") or [])
        line_rows = list(snapshot.get("lines") or [])

        with self._connect() as conn:
            for row in user_rows:
                conn.execute(
                    """
                    INSERT INTO user_usage_monthly (
                        id, membership_id, organization_id, msp_id, phone_number, user_id,
                        period_start, call_count, billable_seconds, billable_minutes,
                        created_at, updated_at
                    ) VALUES (
                        COALESCE((SELECT id FROM user_usage_monthly WHERE organization_id = ? AND phone_number = ? AND period_start = ?), ?),
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    ON CONFLICT(organization_id, phone_number, period_start) DO UPDATE SET
                        membership_id = excluded.membership_id,
                        msp_id = excluded.msp_id,
                        user_id = excluded.user_id,
                        call_count = excluded.call_count,
                        billable_seconds = excluded.billable_seconds,
                        billable_minutes = excluded.billable_minutes,
                        updated_at = excluded.updated_at
                    """,
                    (
                        row["organization_id"],
                        row["phone_number"],
                        period_start,
                        prefixed_id("userusage"),
                        row.get("membership_id"),
                        row["organization_id"],
                        msp_id,
                        row["phone_number"],
                        row.get("user_id"),
                        period_start,
                        int(row.get("call_count") or 0),
                        int(row.get("billable_seconds") or 0),
                        int(row.get("billable_minutes") or 0),
                        now,
                        now,
                    ),
                )

            for line in line_rows:
                conn.execute(
                    """
                    INSERT INTO organization_usage_monthly (
                        id, organization_id, msp_id, period_start,
                        active_seats, billable_seats, call_count, billable_seconds,
                        billable_minutes, included_minutes, overage_minutes,
                        overage_amount_decicents, overage_amount_cents,
                        overage_rate_decicents_per_minute, included_minutes_per_seat,
                        seat_price_cents, amount_cents,
                        stripe_invoice_id, stripe_invoice_item_id,
                        created_at, updated_at
                    ) VALUES (
                        COALESCE((SELECT id FROM organization_usage_monthly WHERE organization_id = ? AND period_start = ?), ?),
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        (SELECT stripe_invoice_id FROM organization_usage_monthly WHERE organization_id = ? AND period_start = ?),
                        (SELECT stripe_invoice_item_id FROM organization_usage_monthly WHERE organization_id = ? AND period_start = ?),
                        COALESCE((SELECT created_at FROM organization_usage_monthly WHERE organization_id = ? AND period_start = ?), ?),
                        ?
                    )
                    ON CONFLICT(organization_id, period_start) DO UPDATE SET
                        msp_id = excluded.msp_id,
                        active_seats = excluded.active_seats,
                        billable_seats = excluded.billable_seats,
                        call_count = excluded.call_count,
                        billable_seconds = excluded.billable_seconds,
                        billable_minutes = excluded.billable_minutes,
                        included_minutes = excluded.included_minutes,
                        overage_minutes = excluded.overage_minutes,
                        overage_amount_decicents = excluded.overage_amount_decicents,
                        overage_amount_cents = excluded.overage_amount_cents,
                        overage_rate_decicents_per_minute = excluded.overage_rate_decicents_per_minute,
                        included_minutes_per_seat = excluded.included_minutes_per_seat,
                        seat_price_cents = excluded.seat_price_cents,
                        amount_cents = excluded.amount_cents,
                        stripe_invoice_id = COALESCE(organization_usage_monthly.stripe_invoice_id, excluded.stripe_invoice_id),
                        stripe_invoice_item_id = COALESCE(organization_usage_monthly.stripe_invoice_item_id, excluded.stripe_invoice_item_id),
                        updated_at = excluded.updated_at
                    """,
                    (
                        line["organization_id"],
                        period_start,
                        prefixed_id("usage"),
                        line["organization_id"],
                        msp_id,
                        period_start,
                        int(line.get("active_seats") or 0),
                        int(line.get("billable_seats") or 0),
                        int(line.get("call_count") or 0),
                        int(line.get("billable_seconds") or 0),
                        int(line.get("billable_minutes") or 0),
                        int(line.get("included_minutes") or 0),
                        int(line.get("overage_minutes") or 0),
                        int(line.get("overage_amount_decicents") or 0),
                        int(line.get("overage_amount_cents") or 0),
                        int(line.get("overage_rate_decicents_per_minute", OVERAGE_DECICENTS_PER_MINUTE)),
                        int(line.get("included_minutes_per_seat", INCLUDED_MINUTES_PER_SEAT)),
                        int(line.get("seat_price_cents") or 0),
                        int(line.get("amount_cents") or 0),
                        line["organization_id"],
                        period_start,
                        line["organization_id"],
                        period_start,
                        line["organization_id"],
                        period_start,
                        now,
                        now,
                    ),
                )

        return {
            "period_start": period_start,
            "organization_rows": len(line_rows),
            "user_rows": len(user_rows),
        }

    def billing_runs_for_msp(self, msp_id: str, *, limit: int = 12) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, period_start, stripe_invoice_id, hosted_invoice_url, status, created_at, finalized_at
                FROM billing_runs
                WHERE msp_id = ?
                ORDER BY period_start DESC
                LIMIT ?
                """,
                (msp_id, int(limit)),
            ).fetchall()
        return [dict(row) for row in rows]

    def billing_period_summaries_for_msp(self, msp_id: str, *, limit: int = 12) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    br.id,
                    br.period_start,
                    br.stripe_invoice_id,
                    br.hosted_invoice_url,
                    br.status,
                    br.created_at,
                    br.finalized_at,
                    COALESCE(SUM(oum.billable_seats), 0) AS total_billable_seats,
                    COALESCE(SUM(oum.active_seats), 0) AS total_active_seats,
                    COALESCE(SUM(oum.call_count), 0) AS total_call_count,
                    COALESCE(SUM(oum.billable_minutes), 0) AS total_billable_minutes,
                    COALESCE(SUM(oum.included_minutes), 0) AS total_included_minutes,
                    COALESCE(SUM(oum.overage_minutes), 0) AS total_overage_minutes,
                    COALESCE(SUM(oum.overage_amount_decicents), 0) AS total_overage_amount_decicents,
                    COALESCE(SUM(oum.overage_amount_cents), 0) AS total_overage_amount_cents,
                    COALESCE(SUM(oum.amount_cents), 0) AS total_amount_cents,
                    COUNT(DISTINCT oum.organization_id) AS company_count
                FROM billing_runs br
                LEFT JOIN organization_usage_monthly oum
                  ON oum.msp_id = br.msp_id AND oum.period_start = br.period_start
                WHERE br.msp_id = ?
                GROUP BY br.id
                ORDER BY br.period_start DESC
                LIMIT ?
                """,
                (msp_id, max(int(limit), 1)),
            ).fetchall()
        return [dict(row) for row in rows]

    def billing_period_detail_for_msp(
        self,
        *,
        msp_id: str,
        period_start: str,
    ) -> dict[str, Any]:
        period_key = (period_start or "").strip()
        if not period_key:
            raise KeyError("Billing period not found")
        with self._connect() as conn:
            msp = conn.execute(
                "SELECT id, name, billing_email, stripe_customer_id, seat_price_cents FROM msps WHERE id = ?",
                (msp_id,),
            ).fetchone()
            if msp is None:
                raise KeyError("MSP not found")

            billing_run = conn.execute(
                """
                SELECT id, period_start, stripe_invoice_id, hosted_invoice_url, status, created_at, finalized_at
                FROM billing_runs
                WHERE msp_id = ? AND period_start = ?
                """,
                (msp_id, period_key),
            ).fetchone()

            company_rows = conn.execute(
                """
                SELECT
                    oum.organization_id,
                    o.name AS organization_name,
                    o.active AS organization_active,
                    o.billing_exempt AS organization_billing_exempt,
                    oum.active_seats,
                    oum.billable_seats,
                    oum.call_count,
                    oum.billable_seconds,
                    oum.billable_minutes,
                    oum.included_minutes,
                    oum.overage_minutes,
                    oum.overage_amount_decicents,
                    oum.overage_amount_cents,
                    oum.overage_rate_decicents_per_minute,
                    oum.included_minutes_per_seat,
                    oum.seat_price_cents,
                    oum.amount_cents,
                    oum.stripe_invoice_id,
                    oum.stripe_invoice_item_id
                FROM organization_usage_monthly oum
                JOIN organizations o ON o.id = oum.organization_id
                WHERE oum.msp_id = ? AND oum.period_start = ?
                ORDER BY o.name ASC
                """,
                (msp_id, period_key),
            ).fetchall()

            user_rows = conn.execute(
                """
                SELECT
                    uum.membership_id,
                    uum.organization_id,
                    o.name AS organization_name,
                    uum.phone_number,
                    uum.user_id,
                    uum.call_count,
                    uum.billable_seconds,
                    uum.billable_minutes
                FROM user_usage_monthly uum
                JOIN organizations o ON o.id = uum.organization_id
                WHERE uum.msp_id = ? AND uum.period_start = ?
                ORDER BY uum.billable_minutes DESC, uum.phone_number ASC
                LIMIT 50
                """,
                (msp_id, period_key),
            ).fetchall()

        seat_billing_events = self.seat_billing_events_for_msp(
            msp_id=msp_id,
            period_start=period_key,
            limit=None,
        )
        seat_billing_by_org: dict[str, dict[str, Any]] = {}
        for event in seat_billing_events:
            if bool(event.get("organization_billing_exempt")):
                continue
            organization_id = str(event["organization_id"])
            rollup = seat_billing_by_org.setdefault(
                organization_id,
                {
                    "organization_id": organization_id,
                    "organization_name": event.get("organization_name") or organization_id,
                    "invoiced_seats": 0,
                    "paid_seats": 0,
                    "payment_required_seats": 0,
                    "invoiced_amount_cents": 0,
                },
            )
            if event.get("stripe_invoice_id"):
                rollup["invoiced_seats"] += 1
            if str(event.get("status") or "").lower() == "paid":
                rollup["paid_seats"] += 1
            if str(event.get("status") or "").lower() in {"open", "finalized", "payment_failed", "uncollectible"}:
                rollup["payment_required_seats"] += 1
            rollup["invoiced_amount_cents"] += int(event.get("amount_cents") or 0)

        if billing_run is None and not company_rows and not user_rows and not seat_billing_events:
            raise KeyError("Billing period not found")

        lines = [dict(row) for row in company_rows]
        seen_line_orgs = set()
        for line in lines:
            organization_id = str(line["organization_id"])
            seen_line_orgs.add(organization_id)
            rollup = seat_billing_by_org.get(organization_id, {})
            line["invoiced_seats"] = int(rollup.get("invoiced_seats", 0))
            line["paid_seats"] = int(rollup.get("paid_seats", 0))
            line["payment_required_seats"] = int(rollup.get("payment_required_seats", 0))
            line["invoiced_amount_cents"] = int(rollup.get("invoiced_amount_cents", 0))
            line["unbilled_seats"] = max(int(line.get("billable_seats") or 0) - int(line["invoiced_seats"]), 0)
            line["unbilled_amount_cents"] = int(line["unbilled_seats"]) * int(line.get("seat_price_cents") or 0)
        for organization_id, rollup in seat_billing_by_org.items():
            if organization_id in seen_line_orgs:
                continue
            invoiced_amount_cents = int(rollup.get("invoiced_amount_cents") or 0)
            invoiced_seats = int(rollup.get("invoiced_seats") or 0)
            lines.append(
                {
                    "organization_id": organization_id,
                    "organization_name": rollup.get("organization_name") or organization_id,
                    "organization_active": True,
                    "organization_billing_exempt": False,
                    "active_seats": 0,
                    "billable_seats": invoiced_seats,
                    "call_count": 0,
                    "billable_seconds": 0,
                    "billable_minutes": 0,
                    "included_minutes": 0,
                    "overage_minutes": 0,
                    "overage_amount_decicents": 0,
                    "overage_amount_cents": 0,
                    "overage_rate_decicents_per_minute": OVERAGE_DECICENTS_PER_MINUTE,
                    "included_minutes_per_seat": INCLUDED_MINUTES_PER_SEAT,
                    "seat_price_cents": int(msp["seat_price_cents"]),
                    "amount_cents": invoiced_amount_cents,
                    "stripe_invoice_id": None,
                    "stripe_invoice_item_id": None,
                    "invoiced_seats": invoiced_seats,
                    "paid_seats": int(rollup.get("paid_seats", 0)),
                    "payment_required_seats": int(rollup.get("payment_required_seats", 0)),
                    "invoiced_amount_cents": invoiced_amount_cents,
                    "unbilled_seats": 0,
                    "unbilled_amount_cents": 0,
                }
            )
        user_usage = [dict(row) for row in user_rows]
        total_active_seats = sum(int(row["active_seats"] or 0) for row in lines)
        total_billable_seats = sum(int(row["billable_seats"] or 0) for row in lines)
        total_call_count = sum(int(row["call_count"] or 0) for row in lines)
        total_billable_seconds = sum(int(row["billable_seconds"] or 0) for row in lines)
        total_billable_minutes = sum(int(row["billable_minutes"] or 0) for row in lines)
        total_included_minutes = sum(int(row.get("included_minutes") or 0) for row in lines)
        total_overage_minutes = sum(int(row.get("overage_minutes") or 0) for row in lines)
        total_overage_amount_decicents = sum(int(row.get("overage_amount_decicents") or 0) for row in lines)
        total_overage_amount_cents = sum(int(row.get("overage_amount_cents") or 0) for row in lines)
        total_amount_cents = sum(int(row["amount_cents"] or 0) for row in lines)
        total_invoiced_seats = sum(int(row.get("invoiced_seats") or 0) for row in lines)
        total_paid_seats = sum(int(row.get("paid_seats") or 0) for row in lines)
        total_payment_required_seats = sum(int(row.get("payment_required_seats") or 0) for row in lines)
        total_invoiced_amount_cents = sum(int(row.get("invoiced_amount_cents") or 0) for row in lines)
        total_unbilled_seats = sum(int(row.get("unbilled_seats") or 0) for row in lines)
        total_unbilled_amount_cents = sum(int(row.get("unbilled_amount_cents") or 0) for row in lines)

        return {
            "msp_id": msp_id,
            "msp_name": msp["name"],
            "billing_email": msp["billing_email"],
            "stripe_customer_id": msp["stripe_customer_id"],
            "period_start": period_key,
            "seat_price_cents": int(msp["seat_price_cents"]),
            "total_active_seats": total_active_seats,
            "total_billable_seats": total_billable_seats,
            "total_call_count": total_call_count,
            "total_billable_seconds": total_billable_seconds,
            "total_billable_minutes": total_billable_minutes,
            "total_included_minutes": total_included_minutes,
            "total_overage_minutes": total_overage_minutes,
            "total_overage_amount_decicents": total_overage_amount_decicents,
            "total_overage_amount_cents": total_overage_amount_cents,
            "overage_rate_decicents_per_minute": OVERAGE_DECICENTS_PER_MINUTE,
            "included_minutes_per_seat": INCLUDED_MINUTES_PER_SEAT,
            "total_invoiced_seats": total_invoiced_seats,
            "total_paid_seats": total_paid_seats,
            "total_payment_required_seats": total_payment_required_seats,
            "total_invoiced_amount_cents": total_invoiced_amount_cents,
            "total_amount_cents": total_amount_cents,
            "total_unbilled_seats": total_unbilled_seats,
            "total_unbilled_amount_cents": total_unbilled_amount_cents,
            "lines": lines,
            "user_usage": user_usage,
            "seat_billing_events": seat_billing_events,
            "billing_run": dict(billing_run) if billing_run is not None else None,
        }

    def billing_snapshot(self, *, msp_id: str, period_start_value: datetime | None = None) -> dict[str, Any]:
        period = month_start(period_start_value)
        period_end = next_month_start(period)
        period_key = isoformat(period)
        period_end_key = isoformat(period_end)
        usage_rollup = self.call_usage_rollup(msp_id=msp_id, period_start_value=period)
        usage_by_org = {
            row["organization_id"]: row
            for row in usage_rollup["organizations"]
        }
        seat_billing_events = self.seat_billing_events_for_msp(
            msp_id=msp_id,
            period_start=period_key,
            limit=None,
        )
        seat_billing_by_org: dict[str, dict[str, int]] = {}
        for event in seat_billing_events:
            if bool(event.get("organization_billing_exempt")):
                continue
            organization_id = str(event["organization_id"])
            rollup = seat_billing_by_org.setdefault(
                organization_id,
                {
                    "invoiced_seats": 0,
                    "paid_seats": 0,
                    "payment_required_seats": 0,
                    "invoiced_amount_cents": 0,
                },
            )
            if event.get("stripe_invoice_id"):
                rollup["invoiced_seats"] += 1
            if str(event.get("status") or "").lower() == "paid":
                rollup["paid_seats"] += 1
            if str(event.get("status") or "").lower() in {"open", "finalized", "payment_failed", "uncollectible"}:
                rollup["payment_required_seats"] += 1
            rollup["invoiced_amount_cents"] += int(event.get("amount_cents") or 0)

        with self._connect() as conn:
            msp = conn.execute(
                "SELECT id, name, billing_email, stripe_customer_id, seat_price_cents FROM msps WHERE id = ?",
                (msp_id,),
            ).fetchone()
            if msp is None:
                raise KeyError("MSP not found")
            billed_usage_rows = conn.execute(
                """
                SELECT organization_id, overage_minutes, overage_amount_cents, overage_amount_decicents
                FROM organization_usage_monthly
                WHERE msp_id = ? AND period_start = ? AND stripe_invoice_id IS NOT NULL
                """,
                (msp_id, period_key),
            ).fetchall()
            billed_overage_minutes_by_org = {
                row["organization_id"]: int(row["overage_minutes"] or 0)
                for row in billed_usage_rows
            }
            billed_overage_amount_cents_by_org = {
                row["organization_id"]: int(row["overage_amount_cents"] or 0)
                for row in billed_usage_rows
            }
            billed_overage_amount_decicents_by_org = {
                row["organization_id"]: int(row["overage_amount_decicents"] or 0)
                for row in billed_usage_rows
            }

            org_rows = conn.execute(
                """
                SELECT
                    o.id AS organization_id,
                    o.name AS organization_name,
                    o.active AS organization_active,
                    o.billing_exempt AS organization_billing_exempt,
                    COUNT(CASE WHEN om.status = 'active' THEN 1 END) AS active_seats,
                    COUNT(
                        CASE
                            WHEN om.first_verified_at < ?
                             AND (om.deactivated_at IS NULL OR om.deactivated_at >= ?)
                            THEN 1
                        END
                    ) AS billable_seats
                FROM organizations o
                LEFT JOIN organization_memberships om ON om.organization_id = o.id
                WHERE o.msp_id = ?
                GROUP BY o.id
                ORDER BY o.name ASC
                """,
                (period_end_key, period_key, msp_id),
            ).fetchall()

        seat_price_cents = int(msp["seat_price_cents"])
        lines: list[dict[str, Any]] = []
        total_amount_cents = 0
        total_active_seats = 0
        total_billable_seats = 0
        total_call_count = 0
        total_billable_seconds = 0
        total_billable_minutes = 0
        total_included_minutes = 0
        total_overage_minutes = 0
        total_overage_amount_decicents = 0
        total_overage_amount_cents = 0
        total_invoiced_seats = 0
        total_paid_seats = 0
        total_payment_required_seats = 0
        total_invoiced_amount_cents = 0
        total_unbilled_seats = 0
        total_unbilled_amount_cents = 0
        for row in org_rows:
            active_seats = int(row["active_seats"])
            organization_billing_exempt = bool(row["organization_billing_exempt"])
            billable_seats = 0 if organization_billing_exempt else int(row["billable_seats"])
            organization_active = bool(row["organization_active"])
            if not organization_active and billable_seats == 0:
                continue
            org_usage = usage_by_org.get(row["organization_id"], {})
            call_count = int(org_usage.get("call_count", 0))
            billable_seconds = int(org_usage.get("billable_seconds", 0))
            billable_minutes = int(org_usage.get("billable_minutes", 0))
            included_minutes = 0 if organization_billing_exempt else included_minutes_for_seats(billable_seats)
            overage_minutes = 0 if organization_billing_exempt else overage_minutes_for_usage(
                billable_minutes=billable_minutes,
                billable_seats=billable_seats,
            )
            overage_amount_decicents = 0 if organization_billing_exempt else overage_amount_decicents_for_minutes(overage_minutes)
            overage_amount_cents = 0 if organization_billing_exempt else overage_amount_cents_for_minutes(overage_minutes)
            seat_amount_cents = billable_seats * seat_price_cents
            amount_cents = seat_amount_cents + overage_amount_cents
            billing_event_rollup = seat_billing_by_org.get(row["organization_id"], {})
            invoiced_seats = int(billing_event_rollup.get("invoiced_seats", 0))
            paid_seats = int(billing_event_rollup.get("paid_seats", 0))
            payment_required_seats = int(billing_event_rollup.get("payment_required_seats", 0))
            invoiced_amount_cents = int(billing_event_rollup.get("invoiced_amount_cents", 0))
            unbilled_seats = max(billable_seats - invoiced_seats, 0)
            billed_overage_minutes = int(billed_overage_minutes_by_org.get(row["organization_id"], 0))
            billed_overage_amount_decicents = int(billed_overage_amount_decicents_by_org.get(row["organization_id"], 0))
            billed_overage_amount_cents = int(billed_overage_amount_cents_by_org.get(row["organization_id"], 0))
            unbilled_overage_minutes = max(overage_minutes - billed_overage_minutes, 0)
            unbilled_overage_amount_decicents = max(overage_amount_decicents - billed_overage_amount_decicents, 0)
            unbilled_overage_amount_cents = max(overage_amount_cents - billed_overage_amount_cents, 0)
            unbilled_amount_cents = (unbilled_seats * seat_price_cents) + unbilled_overage_amount_cents
            total_amount_cents += amount_cents
            total_active_seats += active_seats
            total_billable_seats += billable_seats
            total_call_count += call_count
            total_billable_seconds += billable_seconds
            total_billable_minutes += billable_minutes
            total_included_minutes += included_minutes
            total_overage_minutes += overage_minutes
            total_overage_amount_decicents += overage_amount_decicents
            total_overage_amount_cents += overage_amount_cents
            total_invoiced_seats += invoiced_seats
            total_paid_seats += paid_seats
            total_payment_required_seats += payment_required_seats
            total_invoiced_amount_cents += invoiced_amount_cents
            total_unbilled_seats += unbilled_seats
            total_unbilled_amount_cents += unbilled_amount_cents
            lines.append(
                {
                    "organization_id": row["organization_id"],
                    "organization_name": row["organization_name"],
                    "organization_active": organization_active,
                    "organization_billing_exempt": organization_billing_exempt,
                    "active_seats": active_seats,
                    "billable_seats": billable_seats,
                    "call_count": call_count,
                    "billable_seconds": billable_seconds,
                    "billable_minutes": billable_minutes,
                    "included_minutes": included_minutes,
                    "overage_minutes": overage_minutes,
                    "overage_amount_decicents": overage_amount_decicents,
                    "overage_amount_cents": overage_amount_cents,
                    "overage_rate_decicents_per_minute": OVERAGE_DECICENTS_PER_MINUTE,
                    "billed_overage_minutes": billed_overage_minutes,
                    "billed_overage_amount_decicents": billed_overage_amount_decicents,
                    "billed_overage_amount_cents": billed_overage_amount_cents,
                    "unbilled_overage_minutes": unbilled_overage_minutes,
                    "unbilled_overage_amount_decicents": unbilled_overage_amount_decicents,
                    "invoiced_seats": invoiced_seats,
                    "paid_seats": paid_seats,
                    "payment_required_seats": payment_required_seats,
                    "unbilled_seats": unbilled_seats,
                    "seat_price_cents": seat_price_cents,
                    "amount_cents": amount_cents,
                    "seat_amount_cents": seat_amount_cents,
                    "invoiced_amount_cents": invoiced_amount_cents,
                    "unbilled_overage_amount_cents": unbilled_overage_amount_cents,
                    "unbilled_amount_cents": unbilled_amount_cents,
                    "description": f'{row["organization_name"]} — {billable_seats} billable seat{"s" if billable_seats != 1 else ""}',
                    "period_start": period_key,
                    "period_end": period_end_key,
                }
            )

        return {
            "msp_id": msp_id,
            "msp_name": msp["name"],
            "billing_email": msp["billing_email"],
            "stripe_customer_id": msp["stripe_customer_id"],
            "period_start": period_key,
            "period_end": period_end_key,
            "seat_price_cents": seat_price_cents,
            "total_active_seats": total_active_seats,
            "total_billable_seats": total_billable_seats,
            "total_call_count": total_call_count,
            "total_billable_seconds": total_billable_seconds,
            "total_billable_minutes": total_billable_minutes,
            "total_included_minutes": total_included_minutes,
            "total_overage_minutes": total_overage_minutes,
            "total_overage_amount_decicents": total_overage_amount_decicents,
            "total_overage_amount_cents": total_overage_amount_cents,
            "overage_rate_decicents_per_minute": OVERAGE_DECICENTS_PER_MINUTE,
            "included_minutes_per_seat": INCLUDED_MINUTES_PER_SEAT,
            "total_invoiced_seats": total_invoiced_seats,
            "total_paid_seats": total_paid_seats,
            "total_payment_required_seats": total_payment_required_seats,
            "total_invoiced_amount_cents": total_invoiced_amount_cents,
            "total_unbilled_seats": total_unbilled_seats,
            "total_amount_cents": total_amount_cents,
            "total_unbilled_amount_cents": total_unbilled_amount_cents,
            "lines": lines,
            "user_usage": usage_rollup["users"],
            "seat_billing_events": seat_billing_events,
        }

    def record_billing_run(
        self,
        *,
        msp_id: str,
        snapshot: dict[str, Any],
        stripe_invoice_id: str,
        hosted_invoice_url: str | None,
        line_item_ids_by_org: dict[str, str],
        status: str,
    ) -> dict[str, Any]:
        period_start = snapshot["period_start"]
        now = isoformat(utcnow())
        billing_run_id = prefixed_id("bill")
        period_dt = parse_iso(period_start)
        period_end = next_month_start(period_dt) if period_dt else None
        period_end_key = isoformat(period_end) if period_end else period_start
        self.refresh_monthly_usage_snapshots(msp_id=msp_id, period_start_value=period_dt)

        with self._connect() as conn:
            existing = conn.execute(
                "SELECT id, stripe_invoice_id, hosted_invoice_url, status FROM billing_runs WHERE msp_id = ? AND period_start = ?",
                (msp_id, period_start),
            ).fetchone()

            conn.execute(
                """
                INSERT OR REPLACE INTO billing_runs (id, msp_id, period_start, stripe_invoice_id, hosted_invoice_url, status, created_at, finalized_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    existing["id"] if existing else billing_run_id,
                    msp_id,
                    period_start,
                    stripe_invoice_id,
                    hosted_invoice_url,
                    status,
                    now,
                    now if status in {"finalized", "paid"} else None,
                ),
            )

            for line in snapshot["lines"]:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO organization_usage_monthly (
                        id, organization_id, msp_id, period_start,
                        active_seats, billable_seats, call_count, billable_seconds,
                        billable_minutes, included_minutes, overage_minutes,
                        overage_amount_decicents, overage_amount_cents,
                        overage_rate_decicents_per_minute, included_minutes_per_seat,
                        seat_price_cents,
                        amount_cents, stripe_invoice_id, stripe_invoice_item_id, created_at, updated_at
                    ) VALUES (
                        COALESCE((SELECT id FROM organization_usage_monthly WHERE organization_id = ? AND period_start = ?), ?),
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    """,
                    (
                        line["organization_id"],
                        period_start,
                        prefixed_id("usage"),
                        line["organization_id"],
                        msp_id,
                        period_start,
                        line["active_seats"],
                        line.get("billable_seats", 0),
                        line.get("call_count", 0),
                        line.get("billable_seconds", 0),
                        line.get("billable_minutes", 0),
                        line.get("included_minutes", 0),
                        line.get("overage_minutes", 0),
                        line.get("overage_amount_decicents", 0),
                        line.get("overage_amount_cents", 0),
                        line.get("overage_rate_decicents_per_minute", OVERAGE_DECICENTS_PER_MINUTE),
                        line.get("included_minutes_per_seat", INCLUDED_MINUTES_PER_SEAT),
                        line["seat_price_cents"],
                        line["amount_cents"],
                        stripe_invoice_id,
                        line_item_ids_by_org.get(line["organization_id"]),
                        now,
                        now,
                    ),
                )

                unbilled_seats = int(line.get("unbilled_seats", line.get("billable_seats", 0)) or 0)
                if unbilled_seats > 0:
                    unbilled_memberships = conn.execute(
                        """
                        SELECT
                            om.id AS membership_id,
                            om.organization_id,
                            om.msp_id,
                            om.phone_number,
                            om.user_id
                        FROM organization_memberships om
                        LEFT JOIN seat_billing_events sbe
                          ON sbe.membership_id = om.id AND sbe.period_start = ?
                        WHERE om.organization_id = ?
                          AND om.first_verified_at < ?
                          AND (om.deactivated_at IS NULL OR om.deactivated_at >= ?)
                          AND sbe.id IS NULL
                        ORDER BY om.first_verified_at ASC
                        LIMIT ?
                        """,
                        (
                            period_start,
                            line["organization_id"],
                            period_end_key,
                            period_start,
                            unbilled_seats,
                        ),
                    ).fetchall()
                    for membership in unbilled_memberships:
                        conn.execute(
                            """
                            INSERT INTO seat_billing_events (
                                id, membership_id, organization_id, msp_id, phone_number, user_id,
                                period_start, seat_price_cents, amount_cents,
                                stripe_invoice_id, stripe_invoice_item_id, hosted_invoice_url,
                                status, created_at, updated_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(membership_id, period_start) DO NOTHING
                            """,
                            (
                                prefixed_id("seatbill"),
                                membership["membership_id"],
                                membership["organization_id"],
                                membership["msp_id"],
                                membership["phone_number"],
                                membership["user_id"],
                                period_start,
                                line["seat_price_cents"],
                                line["seat_price_cents"],
                                stripe_invoice_id,
                                line_item_ids_by_org.get(line["organization_id"]),
                                hosted_invoice_url,
                                status,
                                now,
                                now,
                            ),
                        )

        return {
            "id": existing["id"] if existing else billing_run_id,
            "msp_id": msp_id,
            "period_start": period_start,
            "stripe_invoice_id": stripe_invoice_id,
            "hosted_invoice_url": hosted_invoice_url,
            "status": status,
        }

    def existing_billing_run(self, *, msp_id: str, period_start: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT id, msp_id, period_start, stripe_invoice_id, hosted_invoice_url, status, created_at, finalized_at FROM billing_runs WHERE msp_id = ? AND period_start = ?",
                (msp_id, period_start),
            ).fetchone()
        return dict(row) if row else None

    def billing_run_by_invoice_id(self, stripe_invoice_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT id, msp_id, period_start, stripe_invoice_id, hosted_invoice_url, status, created_at, finalized_at
                FROM billing_runs
                WHERE stripe_invoice_id = ?
                """,
                (stripe_invoice_id,),
            ).fetchone()
        return dict(row) if row else None

    def update_billing_run_status(
        self,
        *,
        stripe_invoice_id: str,
        status: str,
        hosted_invoice_url: str | None = None,
    ) -> None:
        now = isoformat(utcnow())
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE billing_runs
                SET
                    status = ?,
                    hosted_invoice_url = COALESCE(?, hosted_invoice_url),
                    finalized_at = COALESCE(finalized_at, ?)
                WHERE stripe_invoice_id = ?
                """,
                (status, (hosted_invoice_url or "").strip() or None, now, stripe_invoice_id),
            )
