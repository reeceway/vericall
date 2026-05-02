#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

BOOTSTRAP_DIR = Path(tempfile.mkdtemp(prefix="vicall-call-usage-bootstrap-"))
os.environ.setdefault("VICALL_CONTROL_DB_PATH", str(BOOTSTRAP_DIR / "control.db"))
os.environ.setdefault("DEVICE_BINDINGS_PATH", str(BOOTSTRAP_DIR / "device_bindings.json"))
os.environ.setdefault("TWILIO_USE_CONFERENCE_WAKE", "false")

from control_plane import ControlPlaneStore, month_start  # noqa: E402


def _seed_org_with_members(store: ControlPlaneStore, *, billing_exempt: bool = False) -> dict[str, str]:
    msp = store.create_msp(
        name="Usage Test MSP",
        billing_email="usage-billing@example.com",
        seat_price_cents=2000,
    )
    org = store.create_organization(
        msp_id=msp["id"],
        name="Usage Test Org",
        billing_exempt=billing_exempt,
    )
    access_code = store.create_access_code(
        organization_id=org["id"],
        code="USAGE-TEST",
        label="Usage test",
    )
    context = store.organization_context(
        organization_id=org["id"],
        access_code_id=access_code["id"],
    )
    assert context is not None
    store.activate_membership(
        context=context,
        phone_number="+15550001001",
        user_id="caller-user",
    )
    store.activate_membership(
        context=context,
        phone_number="+15550001002",
        user_id="callee-user",
    )
    return {
        "msp_id": msp["id"],
        "org_id": org["id"],
        "caller": "user_15550001001_prod1",
        "callee": "user_15550001002_prod1",
    }


def main() -> None:
    tempdir = Path(tempfile.mkdtemp(prefix="vicall-call-usage-"))
    store = ControlPlaneStore(tempdir / "control.db")
    seeded = _seed_org_with_members(store)

    store.record_call_event(
        canonical_key="call:CA-direct-parent",
        caller_identity=seeded["caller"],
        callee_identity=seeded["callee"],
        twilio_call_sid="CA-direct-parent",
        leg_role="caller",
        status="initiated",
        callback_event="initiated",
    )
    store.record_call_event(
        canonical_key=None,
        caller_identity=f"client:{seeded['caller']}",
        callee_identity=f"client:{seeded['callee']}",
        twilio_call_sid="CA-direct-child",
        parent_call_sid="CA-direct-parent",
        leg_role="client",
        status="completed",
        callback_event="completed",
        duration_seconds=125,
    )

    room = "usage-room"
    store.record_call_event(
        canonical_key=f"room:{room}",
        room=room,
        caller_identity=seeded["caller"],
        callee_identity=seeded["callee"],
        twilio_call_sid="CA-conf-parent",
        leg_role="conference_caller",
        status="initiated",
        callback_event="initiated",
    )
    store.record_call_event(
        canonical_key=f"room:{room}",
        room=room,
        caller_identity=f"client:{seeded['caller']}",
        twilio_call_sid="CA-conf-parent",
        leg_role="conference_caller",
        status="completed",
        callback_event="completed",
        duration_seconds=200,
    )
    store.record_call_event(
        canonical_key=f"room:{room}",
        room=room,
        callee_identity=f"client:{seeded['callee']}",
        twilio_call_sid="CA-conf-child",
        leg_role="conference_callee",
        status="completed",
        callback_event="completed",
        duration_seconds=210,
    )

    snapshot = store.billing_snapshot(
        msp_id=seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert snapshot["total_call_count"] == 2, snapshot
    assert snapshot["total_billable_seconds"] == 335, snapshot
    assert snapshot["total_billable_minutes"] == 7, snapshot
    assert len(snapshot["lines"]) == 1, snapshot
    assert snapshot["lines"][0]["call_count"] == 2, snapshot
    assert snapshot["lines"][0]["billable_seconds"] == 335, snapshot
    assert snapshot["lines"][0]["billable_minutes"] == 7, snapshot

    usage_snapshot = store.record_usage_snapshot(
        msp_id=seeded["msp_id"],
        snapshot=snapshot,
    )
    assert usage_snapshot == {
        "period_start": snapshot["period_start"],
        "organization_rows": 1,
        "user_rows": 2,
    }, usage_snapshot

    store.record_billing_run(
        msp_id=seeded["msp_id"],
        snapshot=snapshot,
        stripe_invoice_id="in_usage_test",
        hosted_invoice_url="https://billing.stripe.com/invoice/in_usage_test",
        line_item_ids_by_org={seeded["org_id"]: "ii_usage_test"},
        status="finalized",
    )

    with store._connect() as conn:
        org_usage = conn.execute(
            """
            SELECT call_count, billable_seconds, billable_minutes
            FROM organization_usage_monthly
            WHERE organization_id = ?
            """,
            (seeded["org_id"],),
        ).fetchone()
        user_usage = conn.execute(
            """
            SELECT phone_number, call_count, billable_seconds, billable_minutes
            FROM user_usage_monthly
            ORDER BY phone_number ASC
            """
        ).fetchall()

    assert dict(org_usage) == {
        "call_count": 2,
        "billable_seconds": 335,
        "billable_minutes": 7,
    }, dict(org_usage)
    assert [dict(row) for row in user_usage] == [
        {
            "phone_number": "+15550001001",
            "call_count": 2,
            "billable_seconds": 335,
            "billable_minutes": 7,
        },
        {
            "phone_number": "+15550001002",
            "call_count": 2,
            "billable_seconds": 335,
            "billable_minutes": 7,
        },
    ], [dict(row) for row in user_usage]

    exempt_store = ControlPlaneStore(tempdir / "exempt.db")
    exempt_seeded = _seed_org_with_members(exempt_store, billing_exempt=True)
    exempt_store.record_call_event(
        canonical_key="call:CA-exempt-parent",
        caller_identity=exempt_seeded["caller"],
        callee_identity=exempt_seeded["callee"],
        twilio_call_sid="CA-exempt-parent",
        leg_role="caller",
        status="completed",
        callback_event="completed",
        duration_seconds=61,
    )
    exempt_snapshot = exempt_store.billing_snapshot(
        msp_id=exempt_seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert exempt_snapshot["total_billable_seats"] == 0, exempt_snapshot
    assert exempt_snapshot["total_call_count"] == 1, exempt_snapshot
    assert exempt_snapshot["total_billable_minutes"] == 2, exempt_snapshot
    assert exempt_snapshot["total_amount_cents"] == 0, exempt_snapshot
    exempt_store.record_usage_snapshot(
        msp_id=exempt_seeded["msp_id"],
        snapshot=exempt_snapshot,
    )
    with exempt_store._connect() as conn:
        exempt_org_usage = conn.execute(
            """
            SELECT call_count, billable_seconds, billable_minutes, billable_seats, amount_cents
            FROM organization_usage_monthly
            WHERE organization_id = ?
            """,
            (exempt_seeded["org_id"],),
        ).fetchone()
        exempt_user_usage = conn.execute(
            """
            SELECT COUNT(*) AS row_count, SUM(call_count) AS calls, SUM(billable_minutes) AS minutes
            FROM user_usage_monthly
            """
        ).fetchone()
    assert dict(exempt_org_usage) == {
        "call_count": 1,
        "billable_seconds": 61,
        "billable_minutes": 2,
        "billable_seats": 0,
        "amount_cents": 0,
    }, dict(exempt_org_usage)
    assert dict(exempt_user_usage) == {
        "row_count": 2,
        "calls": 2,
        "minutes": 4,
    }, dict(exempt_user_usage)

    overage_store = ControlPlaneStore(tempdir / "overage.db")
    overage_seeded = _seed_org_with_members(overage_store)
    overage_store.record_call_event(
        canonical_key="call:CA-overage-parent",
        caller_identity=overage_seeded["caller"],
        callee_identity=overage_seeded["callee"],
        twilio_call_sid="CA-overage-parent",
        leg_role="caller",
        status="completed",
        callback_event="completed",
        duration_seconds=907 * 60,
    )
    overage_snapshot = overage_store.billing_snapshot(
        msp_id=overage_seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert overage_snapshot["total_billable_seats"] == 2, overage_snapshot
    assert overage_snapshot["total_billable_minutes"] == 907, overage_snapshot
    assert overage_snapshot["total_included_minutes"] == 900, overage_snapshot
    assert overage_snapshot["total_overage_minutes"] == 7, overage_snapshot
    assert overage_snapshot["total_overage_amount_decicents"] == 7, overage_snapshot
    assert overage_snapshot["total_overage_amount_cents"] == 1, overage_snapshot
    assert overage_snapshot["overage_rate_decicents_per_minute"] == 1, overage_snapshot
    assert overage_snapshot["total_amount_cents"] == 4001, overage_snapshot
    assert overage_snapshot["total_unbilled_amount_cents"] == 4001, overage_snapshot

    overage_store.record_billing_run(
        msp_id=overage_seeded["msp_id"],
        snapshot=overage_snapshot,
        stripe_invoice_id="in_overage_test",
        hosted_invoice_url="https://billing.stripe.com/invoice/in_overage_test",
        line_item_ids_by_org={overage_seeded["org_id"]: "ii_overage_test"},
        status="finalized",
    )
    with overage_store._connect() as conn:
        overage_org_usage = conn.execute(
            """
            SELECT included_minutes, overage_minutes, overage_amount_decicents, overage_amount_cents,
                   overage_rate_decicents_per_minute, included_minutes_per_seat, amount_cents
            FROM organization_usage_monthly
            WHERE organization_id = ?
            """,
            (overage_seeded["org_id"],),
        ).fetchone()
    assert dict(overage_org_usage) == {
        "included_minutes": 900,
        "overage_minutes": 7,
        "overage_amount_decicents": 7,
        "overage_amount_cents": 1,
        "overage_rate_decicents_per_minute": 1,
        "included_minutes_per_seat": 450,
        "amount_cents": 4001,
    }, dict(overage_org_usage)

    post_overage_billing = overage_store.billing_snapshot(
        msp_id=overage_seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert post_overage_billing["total_unbilled_amount_cents"] == 0, post_overage_billing

    overage_store.record_call_event(
        canonical_key="call:CA-overage-extra-small",
        caller_identity=overage_seeded["caller"],
        callee_identity=overage_seeded["callee"],
        twilio_call_sid="CA-overage-extra-small",
        leg_role="caller",
        status="completed",
        callback_event="completed",
        duration_seconds=2 * 60,
    )
    small_adjustment = overage_store.billing_snapshot(
        msp_id=overage_seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert small_adjustment["total_overage_minutes"] == 9, small_adjustment
    assert small_adjustment["total_overage_amount_decicents"] == 9, small_adjustment
    assert small_adjustment["total_overage_amount_cents"] == 1, small_adjustment
    assert small_adjustment["total_unbilled_amount_cents"] == 0, small_adjustment

    overage_store.record_call_event(
        canonical_key="call:CA-overage-extra-cent",
        caller_identity=overage_seeded["caller"],
        callee_identity=overage_seeded["callee"],
        twilio_call_sid="CA-overage-extra-cent",
        leg_role="caller",
        status="completed",
        callback_event="completed",
        duration_seconds=2 * 60,
    )
    cent_adjustment = overage_store.billing_snapshot(
        msp_id=overage_seeded["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert cent_adjustment["total_overage_minutes"] == 11, cent_adjustment
    assert cent_adjustment["total_overage_amount_decicents"] == 11, cent_adjustment
    assert cent_adjustment["total_overage_amount_cents"] == 2, cent_adjustment
    assert cent_adjustment["total_unbilled_amount_cents"] == 1, cent_adjustment

    print("PASS: call sessions, leg de-duping, and monthly minute rollups work")


if __name__ == "__main__":
    main()
