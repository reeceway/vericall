#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

if sys.version_info < (3, 10):
    python311 = ROOT / ".venv-codex-msp" / "bin" / "python"
    if python311.exists():
        os.execv(str(python311), [str(python311), *sys.argv])

BOOTSTRAP_DIR = Path(tempfile.mkdtemp(prefix="vicall-dashboard-100-bootstrap-"))
os.environ.setdefault("VICALL_CONTROL_DB_PATH", str(BOOTSTRAP_DIR / "control.db"))
os.environ.setdefault("DEVICE_BINDINGS_PATH", str(BOOTSTRAP_DIR / "device_bindings.json"))
os.environ.setdefault("TWILIO_USE_CONFERENCE_WAKE", "false")
os.environ.setdefault("VICALL_AUTO_BILLING_ENABLED", "false")

from app import control_plane, portal_summary_for_dashboard, render_portal_dashboard  # noqa: E402
from control_plane import isoformat, month_start  # noqa: E402


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def identity_for_phone(phone_number: str) -> str:
    return f"user_{''.join(ch for ch in phone_number if ch.isdigit())}_prod1"


def seed_msp(index: int, *, companies: int, users_per_company: int) -> dict[str, Any]:
    msp = control_plane.create_msp(
        name=f"Dashboard Ready MSP {index:03d}",
        billing_email=f"billing+dashboard-{index:03d}@example.com",
        stripe_customer_id=f"cus_dashboard_{index:03d}",
        seat_price_cents=2000,
    )
    owner = control_plane.create_msp_user(
        msp_id=msp["id"],
        email=f"owner+dashboard-{index:03d}@example.com",
        phone_number=f"+1417{index:03d}0000",
        full_name=f"Dashboard Owner {index:03d}",
        password="VicallDashboard123!",
    )
    firm = control_plane.create_organization(
        msp_id=msp["id"],
        name=f"Dashboard MSP Firm {index:03d}",
        billing_exempt=True,
    )
    firm_code = control_plane.create_access_code(
        organization_id=firm["id"],
        code=f"DASH-FIRM-{index:03d}",
        label="Firm non-billable access",
    )
    firm_context = control_plane.organization_context(
        organization_id=firm["id"],
        access_code_id=firm_code["id"],
    )
    control_plane.activate_membership(
        context=firm_context,
        phone_number=f"+1418{index:03d}0000",
        user_id=f"firm-user-{index:03d}",
    )

    memberships: list[dict[str, Any]] = []
    for company_index in range(1, companies + 1):
        organization = control_plane.create_organization(
            msp_id=msp["id"],
            name=f"Customer Company {index:03d}-{company_index:02d}",
            external_ref=f"PSA-{index:03d}-{company_index:02d}",
            provisioned_seats=users_per_company,
        )
        code = control_plane.create_access_code(
            organization_id=organization["id"],
            code=f"DASH-{index:03d}-{company_index:02d}",
            label="Customer access",
            max_activations=users_per_company,
        )
        context = control_plane.organization_context(
            organization_id=organization["id"],
            access_code_id=code["id"],
        )
        for user_index in range(1, users_per_company + 1):
            phone_number = f"+1416{index:03d}{company_index:02d}{user_index:02d}"
            membership = control_plane.activate_membership(
                context=context,
                phone_number=phone_number,
                user_id=f"dashboard-user-{index:03d}-{company_index:02d}-{user_index:02d}",
            )
            memberships.append(membership)
            duration_seconds = 60 * (company_index + user_index)
            control_plane.record_call_event(
                canonical_key=f"dashboard-call-{index:03d}-{company_index:02d}-{user_index:02d}",
                caller_identity=identity_for_phone(phone_number),
                callee_identity=identity_for_phone(phone_number),
                twilio_call_sid=f"CAdash{index:03d}{company_index:02d}{user_index:02d}",
                leg_role="client",
                status="completed",
                callback_event="completed",
                duration_seconds=duration_seconds,
            )

    return {
        "msp": msp,
        "owner": owner,
        "firm": firm,
        "memberships": memberships,
    }


def actor_for(seed: dict[str, Any]) -> dict[str, Any]:
    owner = seed["owner"]
    msp = seed["msp"]
    return {
        "id": msp["id"],
        "name": msp["name"],
        "billing_email": msp["billing_email"],
        "stripe_customer_id": msp["stripe_customer_id"],
        "seat_price_cents": msp["seat_price_cents"],
        "msp_user_id": owner["id"],
        "email": owner["email"],
        "phone_number": owner["phone_number"],
        "full_name": owner["full_name"],
        "role": owner["role"],
        "status": msp["status"],
    }


def dashboard_html_for(seed: dict[str, Any], *, payment_ready: bool, query: str = "") -> tuple[dict[str, Any], str]:
    summary = portal_summary_for_dashboard(
        msp_id=str(seed["msp"]["id"]),
        company_query=query,
        company_status="all",
        page=1,
    )
    summary["billing_readiness"] = {
        "customer_id": seed["msp"]["stripe_customer_id"],
        "auto_charge_ready": payment_ready,
        "payment_method_label": "Payment method on file" if payment_ready else "No default payment method on file",
    }
    return summary, render_portal_dashboard(
        summary,
        actor=actor_for(seed),
        company_query=query,
        company_status="all",
        page=1,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Synthetic 100-MSP dashboard readiness test for company grouping, minutes, billing, and payment gating."
    )
    parser.add_argument("--msps", type=int, default=100)
    parser.add_argument("--companies-per-msp", type=int, default=2)
    parser.add_argument("--users-per-company", type=int, default=4)
    parser.add_argument("--render-threshold-seconds", type=float, default=12.0)
    args = parser.parse_args()

    expect(args.msps >= 1, "--msps must be at least 1")
    expect(args.companies_per_msp >= 1, "--companies-per-msp must be at least 1")
    expect(args.users_per_company >= 1, "--users-per-company must be at least 1")

    started_at = time.perf_counter()
    period = month_start(datetime.now(timezone.utc))
    expected_customer_seats = args.companies_per_msp * args.users_per_company
    expected_minutes_per_msp = sum(
        company_index + user_index
        for company_index in range(1, args.companies_per_msp + 1)
        for user_index in range(1, args.users_per_company + 1)
    )

    rendered = 0
    sampled_msp_ids: list[str] = []
    for index in range(1, args.msps + 1):
        seed = seed_msp(index, companies=args.companies_per_msp, users_per_company=args.users_per_company)
        sampled_msp_ids.append(str(seed["msp"]["id"]))
        snapshot = control_plane.billing_snapshot(msp_id=str(seed["msp"]["id"]), period_start_value=period)
        expect(snapshot["total_active_seats"] == expected_customer_seats + 1, "active seats include customer seats plus firm seat")
        expect(snapshot["total_billable_seats"] == expected_customer_seats, "firm seat must not be billable")
        expect(snapshot["total_billable_minutes"] == expected_minutes_per_msp, "minute rollup does not match seeded calls")
        expect(snapshot["total_amount_cents"] == expected_customer_seats * 2000, "seat billing total is wrong")

        summary, html = dashboard_html_for(seed, payment_ready=True)
        expect(summary["has_active_msp_firm"] is True, "dashboard summary lost the MSP firm readiness flag")
        expect("Customer Companies" in html, "dashboard missing customer company metric")
        expect("Used / Included Minutes" in html, "dashboard missing minute metric")
        expect("Top usage this month" in html, "company card missing user minute breakdown")
        expect("Projected Monthly Bill" in html, "dashboard missing billing projection")
        expect("Payment method on file" in html, "dashboard missing Stripe readiness")
        rendered += 1

        if index == 1:
            _, filtered_html = dashboard_html_for(seed, payment_ready=False, query="Customer Company")
            expect("Payment Method Required" in filtered_html, "payment gate disappeared when the firm is filtered off the page")

    elapsed = round(time.perf_counter() - started_at, 3)
    expect(elapsed <= args.render_threshold_seconds, f"dashboard readiness test exceeded {args.render_threshold_seconds}s")
    print(
        json.dumps(
            {
                "ok": True,
                "database": os.environ["VICALL_CONTROL_DB_PATH"],
                "period_start": isoformat(period),
                "msps": args.msps,
                "rendered_dashboards": rendered,
                "companies_per_msp": args.companies_per_msp,
                "users_per_company": args.users_per_company,
                "expected_customer_seats_per_msp": expected_customer_seats,
                "expected_minutes_per_msp": expected_minutes_per_msp,
                "sampled_msp_ids": sampled_msp_ids[:5],
                "elapsed_seconds": elapsed,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
