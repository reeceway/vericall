#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from control_plane import ControlPlaneStore, isoformat, month_start  # noqa: E402


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def identity_for_phone(phone_number: str) -> str:
    return f"user_{''.join(ch for ch in phone_number if ch.isdigit())}_prod1"


def timed(metrics: dict[str, float], name: str):
    class Timer:
        def __enter__(self):
            self.started_at = time.perf_counter()
            return self

        def __exit__(self, exc_type, exc, tb):
            metrics[name] = round(time.perf_counter() - self.started_at, 3)

    return Timer()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Synthetic MSP scale readiness test: 10,000 users, company rollups, usage, and billing."
    )
    parser.add_argument("--companies", type=int, default=100)
    parser.add_argument("--users-per-company", type=int, default=100)
    parser.add_argument("--firm-users", type=int, default=5)
    parser.add_argument("--seat-price-cents", type=int, default=2000)
    parser.add_argument("--invoiced-ratio", type=float, default=0.25)
    parser.add_argument("--call-users", type=int, default=10000)
    parser.add_argument("--snapshot-threshold-seconds", type=float, default=12.0)
    parser.add_argument("--billing-run-threshold-seconds", type=float, default=20.0)
    args = parser.parse_args()

    total_users = args.companies * args.users_per_company
    expect(total_users > 0, "total users must be positive")
    expect(args.call_users <= total_users, "--call-users cannot exceed total users")
    tempdir = Path(tempfile.mkdtemp(prefix="vicall-msp-10000-scale-"))
    store = ControlPlaneStore(tempdir / "control.db")
    period = month_start(datetime.now(timezone.utc))
    period_key = isoformat(period)
    metrics: dict[str, float] = {}

    with timed(metrics, "seed_seconds"):
        msp = store.create_msp(
            name="Scale Readiness MSP",
            billing_email="scale-billing@example.com",
            stripe_customer_id="cus_scale_readiness",
            seat_price_cents=args.seat_price_cents,
        )
        firm = store.create_organization(
            msp_id=msp["id"],
            name="Scale MSP Firm",
            billing_exempt=True,
        )
        firm_code = store.create_access_code(
            organization_id=firm["id"],
            code="SCALE-FIRM",
            label="Firm non-billable access",
        )
        firm_context = store.organization_context(
            organization_id=firm["id"],
            access_code_id=firm_code["id"],
        )
        for index in range(args.firm_users):
            store.activate_membership(
                context=firm_context,
                phone_number=f"+12125550{index:03d}",
                user_id=f"firm-user-{index:03d}",
            )

        memberships: list[dict[str, Any]] = []
        org_ids: list[str] = []
        for company_index in range(args.companies):
            org = store.create_organization(
                msp_id=msp["id"],
                name=f"Customer Company {company_index + 1:03d}",
                external_ref=f"PSA-{company_index + 1:03d}",
                provisioned_seats=args.users_per_company,
            )
            org_ids.append(org["id"])
            code = store.create_access_code(
                organization_id=org["id"],
                code=f"SCALE-{company_index + 1:03d}",
                label="Customer company access",
                max_activations=args.users_per_company,
            )
            context = store.organization_context(
                organization_id=org["id"],
                access_code_id=code["id"],
            )
            for user_index in range(args.users_per_company):
                global_index = company_index * args.users_per_company + user_index
                phone_number = f"+1202555{global_index:04d}"
                membership = store.activate_membership(
                    context=context,
                    phone_number=phone_number,
                    user_id=f"scale-user-{global_index:05d}",
                )
                memberships.append(membership)

        invoiced_count = int(total_users * args.invoiced_ratio)
        for index, membership in enumerate(memberships[:invoiced_count]):
            store.record_seat_billing_event(
                membership=membership,
                period_start=period_key,
                seat_price_cents=args.seat_price_cents,
                amount_cents=args.seat_price_cents,
                stripe_invoice_id=f"in_scale_seat_{index:05d}",
                stripe_invoice_item_id=f"ili_scale_seat_{index:05d}",
                hosted_invoice_url=f"https://billing.stripe.com/invoice/in_scale_seat_{index:05d}",
                status="open",
            )

    with timed(metrics, "usage_seconds"):
        for index, membership in enumerate(memberships[: args.call_users]):
            duration_seconds = 60 + (index % 5) * 60
            caller_phone = str(membership["phone_number"])
            store.record_call_event(
                canonical_key=f"scale-call-{index:05d}",
                caller_identity=identity_for_phone(caller_phone),
                callee_identity=identity_for_phone(caller_phone),
                twilio_call_sid=f"CAscale{index:026d}"[:34],
                leg_role="client",
                status="completed",
                callback_event="completed",
                duration_seconds=duration_seconds,
            )

    with timed(metrics, "snapshot_seconds"):
        snapshot = store.billing_snapshot(msp_id=msp["id"], period_start_value=period)

    expected_call_minutes = sum(1 + (index % 5) for index in range(args.call_users))
    expected_included_minutes = total_users * 450
    expected_unbilled_seats = total_users - int(total_users * args.invoiced_ratio)
    expect(snapshot["total_active_seats"] == total_users + args.firm_users, "active seat total is wrong")
    expect(snapshot["total_billable_seats"] == total_users, "billable seat total is wrong")
    expected_invoiced_seats = int(total_users * args.invoiced_ratio)
    expect(
        snapshot["total_invoiced_seats"] == expected_invoiced_seats,
        f"invoiced seat total is wrong: expected {expected_invoiced_seats}, got {snapshot['total_invoiced_seats']}",
    )
    expect(snapshot["total_unbilled_seats"] == expected_unbilled_seats, "unbilled seat total is wrong")
    expect(
        snapshot["total_billable_minutes"] == expected_call_minutes,
        f"billable minute rollup is wrong: expected {expected_call_minutes}, got {snapshot['total_billable_minutes']}",
    )
    expect(snapshot["total_included_minutes"] == expected_included_minutes, "included minute rollup is wrong")
    expect(snapshot["total_overage_minutes"] == 0, "scale baseline should not create overage")
    expect(snapshot["total_amount_cents"] == total_users * args.seat_price_cents, "total amount is wrong")
    expect(
        snapshot["total_unbilled_amount_cents"] == expected_unbilled_seats * args.seat_price_cents,
        "unbilled amount is wrong",
    )
    expect(len(snapshot["lines"]) == args.companies + 1, "firm plus customer company line count is wrong")
    firm_line = next((line for line in snapshot["lines"] if line["organization_id"] == firm["id"]), None)
    expect(firm_line is not None and firm_line["organization_billing_exempt"], "firm line is not billing-exempt")
    expect(firm_line["billable_seats"] == 0 and firm_line["amount_cents"] == 0, "firm line should not bill")

    with timed(metrics, "billing_run_seconds"):
        billing_run = store.record_billing_run(
            msp_id=msp["id"],
            snapshot=snapshot,
            stripe_invoice_id="in_scale_monthly",
            hosted_invoice_url="https://billing.stripe.com/invoice/in_scale_monthly",
            line_item_ids_by_org={org_id: f"ili_scale_{idx:03d}" for idx, org_id in enumerate(org_ids, start=1)},
            status="finalized",
        )

    with timed(metrics, "post_billing_snapshot_seconds"):
        post_snapshot = store.billing_snapshot(msp_id=msp["id"], period_start_value=period)

    expect(billing_run["stripe_invoice_id"] == "in_scale_monthly", "billing run was not recorded")
    expect(post_snapshot["total_unbilled_seats"] == 0, "monthly billing did not catch up all seats")
    expect(post_snapshot["total_unbilled_amount_cents"] == 0, "monthly billing left unbilled amount")
    expect(post_snapshot["total_invoiced_seats"] == total_users, "monthly billing did not mark all seats invoiced")
    expect(metrics["snapshot_seconds"] <= args.snapshot_threshold_seconds, "billing snapshot exceeded threshold")
    expect(metrics["billing_run_seconds"] <= args.billing_run_threshold_seconds, "billing run exceeded threshold")

    payload = {
        "ok": True,
        "database": str(tempdir / "control.db"),
        "companies": args.companies,
        "customer_users": total_users,
        "firm_users": args.firm_users,
        "call_users": args.call_users,
        "expected_call_minutes": expected_call_minutes,
        "snapshot": {
            "total_active_seats": snapshot["total_active_seats"],
            "total_billable_seats": snapshot["total_billable_seats"],
            "total_invoiced_seats": snapshot["total_invoiced_seats"],
            "total_unbilled_seats": snapshot["total_unbilled_seats"],
            "total_billable_minutes": snapshot["total_billable_minutes"],
            "total_included_minutes": snapshot["total_included_minutes"],
            "total_amount_cents": snapshot["total_amount_cents"],
            "total_unbilled_amount_cents": snapshot["total_unbilled_amount_cents"],
        },
        "post_billing_snapshot": {
            "total_invoiced_seats": post_snapshot["total_invoiced_seats"],
            "total_unbilled_seats": post_snapshot["total_unbilled_seats"],
            "total_unbilled_amount_cents": post_snapshot["total_unbilled_amount_cents"],
        },
        "metrics": metrics,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
