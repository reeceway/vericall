#!/usr/bin/env python3
"""Read-only production control-plane audit for MSP usage and billing.

Run inside the Fly app VM or anywhere with VICALL_CONTROL_DB_PATH pointing at
the production SQLite DB. The output intentionally masks phone numbers and
Stripe/customer identifiers enough for operator notes.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def mask_phone(value: str | None) -> str | None:
    digits = "".join(ch for ch in str(value or "") if ch.isdigit())
    if len(digits) >= 4:
        return f"***{digits[-4:]}"
    return None


def mask_id(value: str | None, *, keep: int = 6) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if len(raw) <= keep * 2:
        return raw
    return f"{raw[:keep]}...{raw[-keep:]}"


def rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def count(conn: sqlite3.Connection, table: str, where: str = "1=1", params: tuple[Any, ...] = ()) -> int:
    return int(conn.execute(f"SELECT COUNT(*) FROM {table} WHERE {where}", params).fetchone()[0])


def current_period_start() -> str:
    now = datetime.now(timezone.utc)
    return datetime(now.year, now.month, 1, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def previous_period_start() -> str:
    now = datetime.now(timezone.utc)
    year = now.year
    month = now.month - 1
    if month == 0:
        year -= 1
        month = 12
    return datetime(year, month, 1, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def next_period_start(period_start: str) -> str:
    period = datetime.fromisoformat(period_start.replace("Z", "+00:00"))
    year = period.year
    month = period.month + 1
    if month == 13:
        year += 1
        month = 1
    return datetime(year, month, 1, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def live_usage_rollup(conn: sqlite3.Connection, *, msp_id: str, period_start: str) -> dict[str, Any]:
    period_end = next_period_start(period_start)
    org_rows = rows(
        conn,
        """
        WITH org_sessions AS (
            SELECT
                s.id AS call_session_id,
                p.organization_id,
                MAX(p.organization_name) AS organization_name,
                MAX(s.billable_seconds) AS billable_seconds,
                MAX(s.billable_minutes) AS billable_minutes
            FROM call_sessions s
            JOIN call_participants p ON p.call_session_id = s.id
            WHERE p.msp_id = ?
              AND p.organization_id IS NOT NULL
              AND p.phone_number IS NOT NULL
              AND s.completed_at >= ?
              AND s.completed_at < ?
              AND s.billable_seconds > 0
            GROUP BY s.id, p.organization_id
        )
        SELECT
            organization_id,
            organization_name,
            COUNT(*) AS call_count,
            COALESCE(SUM(billable_seconds), 0) AS billable_seconds,
            COALESCE(SUM(billable_minutes), 0) AS billable_minutes
        FROM org_sessions
        GROUP BY organization_id
        ORDER BY billable_minutes DESC
        """,
        (msp_id, period_start, period_end),
    )
    user_rows = rows(
        conn,
        """
        WITH user_sessions AS (
            SELECT
                s.id AS call_session_id,
                p.organization_id,
                MAX(p.organization_name) AS organization_name,
                p.phone_number,
                MAX(p.user_id) AS user_id,
                MAX(p.membership_id) AS membership_id,
                MAX(s.billable_seconds) AS billable_seconds,
                MAX(s.billable_minutes) AS billable_minutes
            FROM call_sessions s
            JOIN call_participants p ON p.call_session_id = s.id
            WHERE p.msp_id = ?
              AND p.organization_id IS NOT NULL
              AND p.phone_number IS NOT NULL
              AND s.completed_at >= ?
              AND s.completed_at < ?
              AND s.billable_seconds > 0
            GROUP BY s.id, p.organization_id, p.phone_number
        )
        SELECT
            organization_id,
            organization_name,
            phone_number,
            user_id,
            membership_id,
            COUNT(*) AS call_count,
            COALESCE(SUM(billable_seconds), 0) AS billable_seconds,
            COALESCE(SUM(billable_minutes), 0) AS billable_minutes
        FROM user_sessions
        GROUP BY organization_id, phone_number
        ORDER BY billable_minutes DESC
        """,
        (msp_id, period_start, period_end),
    )
    return {
        "period_start": period_start,
        "period_end": period_end,
        "organizations": org_rows,
        "users": [
            {
                **row,
                "phone_number": mask_phone(row.get("phone_number")),
            }
            for row in user_rows
        ],
        "totals": {
            "call_count": sum(int(row.get("call_count") or 0) for row in org_rows),
            "billable_seconds": sum(int(row.get("billable_seconds") or 0) for row in org_rows),
            "billable_minutes": sum(int(row.get("billable_minutes") or 0) for row in org_rows),
        },
    }


def sanitize_msp(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row.get("id"),
        "name": row.get("name"),
        "billing_email": row.get("billing_email"),
        "status": row.get("status"),
        "active": bool(row.get("active")),
        "stripe_customer_present": bool(row.get("stripe_customer_id")),
        "stripe_customer_id_masked": mask_id(row.get("stripe_customer_id")),
        "seat_price_cents": int(row.get("seat_price_cents") or 0),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=os.getenv("VICALL_CONTROL_DB_PATH", "/data/vericall_control.db"))
    parser.add_argument("--email", default="reece@vicallapp.com")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    db_path = Path(args.db)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    period = current_period_start()
    previous_period = previous_period_start()
    user = one(
        conn,
        """
        SELECT
            u.id AS msp_user_id,
            u.msp_id,
            u.email,
            u.full_name,
            u.phone_number,
            u.role,
            u.active AS user_active,
            u.last_login_at,
            m.id,
            m.name,
            m.billing_email,
            m.stripe_customer_id,
            m.seat_price_cents,
            m.status,
            m.active,
            m.created_at,
            m.updated_at
        FROM msp_users u
        JOIN msps m ON m.id = u.msp_id
        WHERE lower(u.email) = lower(?)
        ORDER BY u.created_at DESC
        LIMIT 1
        """,
        (args.email,),
    )
    if user is None:
        raise SystemExit(f"MSP user not found for {args.email}")
    msp_id = str(user["msp_id"])

    pragmas = {
        "journal_mode": conn.execute("PRAGMA journal_mode").fetchone()[0],
        "synchronous": conn.execute("PRAGMA synchronous").fetchone()[0],
        "foreign_key_check_count": len(conn.execute("PRAGMA foreign_key_check").fetchall()),
    }

    organizations = rows(
        conn,
        """
        SELECT
            o.id,
            o.name,
            o.external_ref,
            o.provisioned_seats,
            o.billing_exempt,
            o.active,
            COUNT(CASE WHEN om.status = 'active' THEN 1 END) AS active_seats,
            COUNT(CASE WHEN om.status != 'active' THEN 1 END) AS inactive_seats,
            MAX(om.last_verified_at) AS last_verified_at
        FROM organizations o
        LEFT JOIN organization_memberships om ON om.organization_id = o.id
        WHERE o.msp_id = ?
        GROUP BY o.id
        ORDER BY o.created_at ASC
        """,
        (msp_id,),
    )

    memberships = rows(
        conn,
        """
        SELECT
            om.id,
            om.organization_id,
            o.name AS organization_name,
            o.billing_exempt AS organization_billing_exempt,
            om.phone_number,
            om.user_id,
            om.status,
            om.access_code_id,
            om.first_verified_at,
            om.last_verified_at,
            om.deactivated_at
        FROM organization_memberships om
        JOIN organizations o ON o.id = om.organization_id
        WHERE om.msp_id = ?
        ORDER BY om.last_verified_at DESC
        """,
        (msp_id,),
    )

    access_codes = rows(
        conn,
        """
        SELECT
            ac.id,
            ac.organization_id,
            o.name AS organization_name,
            ac.label,
            ac.code_hint,
            ac.active,
            ac.max_activations,
            COUNT(CASE WHEN om.status = 'active' THEN 1 END) AS active_activations
        FROM organization_access_codes ac
        JOIN organizations o ON o.id = ac.organization_id
        LEFT JOIN organization_memberships om ON om.access_code_id = ac.id
        WHERE o.msp_id = ?
        GROUP BY ac.id
        ORDER BY ac.created_at ASC
        """,
        (msp_id,),
    )

    call_sessions = rows(
        conn,
        """
        SELECT
            id,
            canonical_key,
            room,
            caller_identity,
            callee_identity,
            caller_phone_number,
            callee_phone_number,
            msp_id,
            status,
            started_at,
            answered_at,
            completed_at,
            duration_seconds,
            billable_seconds,
            billable_minutes,
            last_event_at
        FROM call_sessions
        WHERE msp_id = ?
        ORDER BY COALESCE(completed_at, last_event_at, created_at) DESC
        LIMIT 20
        """,
        (msp_id,),
    )

    call_participants = rows(
        conn,
        """
        SELECT
            p.call_session_id,
            p.identity,
            p.role,
            p.phone_number,
            p.user_id,
            p.membership_id,
            p.organization_id,
            p.organization_name,
            p.msp_id
        FROM call_participants p
        WHERE p.msp_id = ?
        ORDER BY p.created_at DESC
        LIMIT 40
        """,
        (msp_id,),
    )

    current_usage = rows(
        conn,
        """
        SELECT
            oum.organization_id,
            o.name AS organization_name,
            o.billing_exempt AS organization_billing_exempt,
            oum.period_start,
            oum.active_seats,
            oum.billable_seats,
            oum.call_count,
            oum.billable_seconds,
            oum.billable_minutes,
            oum.included_minutes,
            oum.overage_minutes,
            oum.overage_amount_decicents,
            oum.overage_amount_cents,
            oum.amount_cents,
            oum.stripe_invoice_id
        FROM organization_usage_monthly oum
        JOIN organizations o ON o.id = oum.organization_id
        WHERE oum.msp_id = ? AND oum.period_start IN (?, ?)
        ORDER BY oum.period_start DESC, o.name ASC
        """,
        (msp_id, period, previous_period),
    )

    user_usage = rows(
        conn,
        """
        SELECT
            uum.organization_id,
            o.name AS organization_name,
            uum.membership_id,
            uum.phone_number,
            uum.user_id,
            uum.period_start,
            uum.call_count,
            uum.billable_seconds,
            uum.billable_minutes
        FROM user_usage_monthly uum
        JOIN organizations o ON o.id = uum.organization_id
        WHERE uum.msp_id = ? AND uum.period_start IN (?, ?)
        ORDER BY uum.period_start DESC, uum.billable_minutes DESC
        LIMIT 50
        """,
        (msp_id, period, previous_period),
    )

    seat_billing = rows(
        conn,
        """
        SELECT
            sbe.membership_id,
            sbe.organization_id,
            o.name AS organization_name,
            o.billing_exempt AS organization_billing_exempt,
            sbe.phone_number,
            sbe.user_id,
            sbe.period_start,
            sbe.seat_price_cents,
            sbe.amount_cents,
            sbe.stripe_invoice_id,
            sbe.status,
            sbe.created_at,
            sbe.updated_at
        FROM seat_billing_events sbe
        JOIN organizations o ON o.id = sbe.organization_id
        WHERE sbe.msp_id = ?
        ORDER BY sbe.created_at DESC
        LIMIT 50
        """,
        (msp_id,),
    )

    billing_runs = rows(
        conn,
        """
        SELECT period_start, stripe_invoice_id, status, created_at, finalized_at
        FROM billing_runs
        WHERE msp_id = ?
        ORDER BY period_start DESC
        LIMIT 12
        """,
        (msp_id,),
    )

    audits = rows(
        conn,
        """
        SELECT created_at, action, actor_email, actor_label, organization_name, status, target_type
        FROM msp_audit_events
        WHERE msp_id = ?
        ORDER BY created_at DESC
        LIMIT 25
        """,
        (msp_id,),
    )
    live_current_usage = live_usage_rollup(conn, msp_id=msp_id, period_start=period)
    live_previous_usage = live_usage_rollup(conn, msp_id=msp_id, period_start=previous_period)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "db_path": str(db_path),
        "db_pragmas": pragmas,
        "periods_checked": {"current": period, "previous": previous_period},
        "msp_user": {
            "msp_user_id": user["msp_user_id"],
            "email": user["email"],
            "full_name": user["full_name"],
            "phone_masked": mask_phone(user["phone_number"]),
            "role": user["role"],
            "active": bool(user["user_active"]),
            "last_login_at": user["last_login_at"],
        },
        "msp": sanitize_msp(user),
        "counts": {
            "msps": count(conn, "msps"),
            "organizations_for_msp": len(organizations),
            "active_organizations_for_msp": sum(1 for row in organizations if row.get("active")),
            "billing_exempt_organizations_for_msp": sum(1 for row in organizations if row.get("billing_exempt")),
            "memberships_for_msp": len(memberships),
            "active_memberships_for_msp": sum(1 for row in memberships if row.get("status") == "active"),
            "billable_active_memberships_for_msp": sum(
                1
                for row in memberships
                if row.get("status") == "active" and not bool(row.get("organization_billing_exempt"))
            ),
            "active_access_codes_for_msp": sum(1 for row in access_codes if row.get("active")),
            "access_grants_pending_for_msp": count(
                conn,
                "access_grants",
                "msp_id = ? AND consumed_at IS NULL AND expires_at > ?",
                (msp_id, datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")),
            ),
            "call_sessions_for_msp": count(conn, "call_sessions", "msp_id = ?", (msp_id,)),
            "completed_call_sessions_for_msp": count(
                conn,
                "call_sessions",
                "msp_id = ? AND completed_at IS NOT NULL AND billable_seconds > 0",
                (msp_id,),
            ),
            "call_participants_for_msp": count(conn, "call_participants", "msp_id = ?", (msp_id,)),
            "monthly_org_usage_rows_for_msp": count(conn, "organization_usage_monthly", "msp_id = ?", (msp_id,)),
            "monthly_user_usage_rows_for_msp": count(conn, "user_usage_monthly", "msp_id = ?", (msp_id,)),
            "seat_billing_events_for_msp": count(conn, "seat_billing_events", "msp_id = ?", (msp_id,)),
            "billing_runs_for_msp": count(conn, "billing_runs", "msp_id = ?", (msp_id,)),
            "audit_events_for_msp": count(conn, "msp_audit_events", "msp_id = ?", (msp_id,)),
        },
        "organizations": [
            {
                **row,
                "billing_exempt": bool(row.get("billing_exempt")),
                "active": bool(row.get("active")),
            }
            for row in organizations
        ],
        "memberships": [
            {
                **row,
                "phone_number": mask_phone(row.get("phone_number")),
                "organization_billing_exempt": bool(row.get("organization_billing_exempt")),
            }
            for row in memberships
        ],
        "access_codes": access_codes,
        "recent_call_sessions": [
            {
                **row,
                "canonical_key": mask_id(row.get("canonical_key"), keep=8),
                "caller_identity": mask_id(row.get("caller_identity"), keep=8),
                "callee_identity": mask_id(row.get("callee_identity"), keep=8),
                "caller_phone_number": mask_phone(row.get("caller_phone_number")),
                "callee_phone_number": mask_phone(row.get("callee_phone_number")),
            }
            for row in call_sessions
        ],
        "recent_call_participants": [
            {
                **row,
                "identity": mask_id(row.get("identity"), keep=8),
                "phone_number": mask_phone(row.get("phone_number")),
            }
            for row in call_participants
        ],
        "usage_rows": [
            {
                **row,
                "stripe_invoice_id": mask_id(row.get("stripe_invoice_id")),
                "organization_billing_exempt": bool(row.get("organization_billing_exempt")),
            }
            for row in current_usage
        ],
        "live_usage_rollups": {
            "current": live_current_usage,
            "previous": live_previous_usage,
        },
        "user_usage_rows": [
            {
                **row,
                "phone_number": mask_phone(row.get("phone_number")),
            }
            for row in user_usage
        ],
        "seat_billing_events": [
            {
                **row,
                "phone_number": mask_phone(row.get("phone_number")),
                "stripe_invoice_id": mask_id(row.get("stripe_invoice_id")),
                "organization_billing_exempt": bool(row.get("organization_billing_exempt")),
            }
            for row in seat_billing
        ],
        "billing_runs": [
            {
                **row,
                "stripe_invoice_id": mask_id(row.get("stripe_invoice_id")),
            }
            for row in billing_runs
        ],
        "recent_audit_events": audits,
        "checks": {
            "msp_active": bool(user.get("active")) and str(user.get("status")) == "active",
            "owner_user_active": bool(user.get("user_active")) and str(user.get("role")) == "owner",
            "firm_non_billable": any(row.get("active") and row.get("billing_exempt") for row in organizations),
            "no_billable_firm_seat": all(
                bool(row.get("organization_billing_exempt")) or row.get("status") != "active"
                for row in memberships
            ),
            "call_tracking_schema_ready": pragmas["foreign_key_check_count"] == 0,
            "has_completed_tracked_call": count(
                conn,
                "call_sessions",
                "msp_id = ? AND completed_at IS NOT NULL AND billable_seconds > 0",
                (msp_id,),
            )
            > 0,
            "live_previous_usage_detected": int(live_previous_usage["totals"]["billable_minutes"]) > 0,
            "cached_previous_user_usage_present": any(row.get("period_start") == previous_period for row in user_usage),
            "has_user_usage_rollup": count(conn, "user_usage_monthly", "msp_id = ?", (msp_id,)) > 0,
            "has_org_usage_rollup": count(conn, "organization_usage_monthly", "msp_id = ?", (msp_id,)) > 0,
            "seat_billing_event_recorded": count(conn, "seat_billing_events", "msp_id = ?", (msp_id,)) > 0,
            "billing_run_recorded": count(conn, "billing_runs", "msp_id = ?", (msp_id,)) > 0,
            "audit_trail_present": count(conn, "msp_audit_events", "msp_id = ?", (msp_id,)) > 0,
        },
    }

    encoded = json.dumps(report, indent=2, sort_keys=True)
    print(encoded)
    if args.out:
        Path(args.out).write_text(encoded + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
