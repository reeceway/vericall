#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


SERVICE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SERVICE_ROOT.parent


MSP_ACTIONS = [
    "Vicall admin provisions MSP owner, firm organization, access code, and Stripe customer link",
    "MSP owner signs in with email/password, phone confirmation, and SMS OTP",
    "MSP opens dashboard, billing center, Stripe billing portal, and audit log",
    "MSP invites operator and read-only users, sets passwords, and role gates write actions",
    "MSP is blocked from creating customer companies until Stripe payment is ready",
    "MSP creates and updates customer companies with provisioned seat limits",
    "MSP creates, caps, and disables access codes; disabled codes fail closed",
    "MSP exports companies, users, and usage CSVs with audit events",
    "MSP deactivates seats and companies; inactive users lose app and voice access",
    "MSP lifecycle states pending_review and suspended restrict provisioning and app access",
    "MSP can still reach billing while suspended or pending review",
    "MSP logout clears the portal session and writes an audit event",
]

USER_ACTIONS = [
    "User validates a company access code and receives a grant token",
    "User requests an OTP through the app onboarding path",
    "User verifies OTP with a public key and creates an organization membership",
    "User duplicate signup under the same company does not create duplicate seat billing",
    "User in the MSP firm remains non-billable",
    "User in a customer company creates an immediate billable seat invoice",
    "User registers a VoIP device binding and receives a Twilio Voice token only while active",
    "User starts a Twilio call and call events roll into company and user minute usage",
    "User exceeds included minutes and overage accrues at the configured per-minute rate",
    "User account deletion removes memberships and device bindings",
    "User can be reprovisioned after deletion or offboarding with an active code",
]

LOCAL_TRACKING_SURFACES = [
    "MSP audit events",
    "admin/system audit events",
    "organization rows and access-code state",
    "membership rows and activation/deactivation state",
    "device binding store",
    "call event store",
    "company/user monthly usage snapshots",
    "seat billing events",
    "monthly billing runs",
    "Stripe webhook status updates",
    "portal dashboard and billing HTML render paths",
    "CSV export paths",
]


def python_executable() -> str:
    venv_python = SERVICE_ROOT / ".venv-codex-msp" / "bin" / "python"
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def suite_commands(args: argparse.Namespace) -> list[dict[str, Any]]:
    python = python_executable()
    suites: list[dict[str, Any]] = [
        {
            "name": "portal_app_billing_logging_lifecycle",
            "description": "End-to-end local portal -> app onboarding -> portal summary -> billing -> logging lifecycle.",
            "command": [
                python,
                str(SERVICE_ROOT / "scripts" / "test_portal_msp_sms_lifecycle.py"),
            ],
            "timeout": args.timeout_seconds,
        },
        {
            "name": "call_usage_minutes_overage_storage",
            "description": "Call-event dedupe, user/company minute rollups, included minutes, overage, and storage.",
            "command": [
                python,
                str(SERVICE_ROOT / "scripts" / "test_call_usage_tracking.py"),
            ],
            "timeout": args.timeout_seconds,
        },
    ]

    if not args.skip_ten_msp_dashboard:
        suites.append(
            {
                "name": "ten_msp_dashboard_grouping",
                "description": "Ten-MSP dashboard grouping, company totals, payment readiness, and render budget.",
                "command": [
                    python,
                    str(SERVICE_ROOT / "scripts" / "test_msp_100_dashboard_readiness.py"),
                    "--msps",
                    "10",
                    "--companies-per-msp",
                    "3",
                    "--users-per-company",
                    "4",
                    "--render-threshold-seconds",
                    str(args.dashboard_threshold_seconds),
                ],
                "timeout": args.timeout_seconds,
            }
        )

    return suites


def run_suite(
    *,
    cycle: int,
    suite: dict[str, Any],
    verbose: bool,
) -> dict[str, Any]:
    started = time.perf_counter()
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["VICALL_LOCAL_ACTION_MATRIX_CYCLE"] = str(cycle)

    result = subprocess.run(
        suite["command"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=int(suite["timeout"]),
    )
    elapsed = round(time.perf_counter() - started, 3)
    summary = {
        "cycle": cycle,
        "suite": suite["name"],
        "ok": result.returncode == 0,
        "elapsed_seconds": elapsed,
    }
    if verbose or result.returncode != 0:
        summary["stdout"] = result.stdout[-8000:]
        summary["stderr"] = result.stderr[-8000:]
    if result.returncode != 0:
        print(json.dumps(summary, indent=2, sort_keys=True))
        raise SystemExit(result.returncode)
    print(f"PASS cycle={cycle} suite={suite['name']} elapsed={elapsed}s")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Runs the local MSP action matrix four times by default: portal, app onboarding, "
            "billing, usage, and audit/logging proof."
        )
    )
    parser.add_argument("--cycles", type=int, default=4)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--dashboard-threshold-seconds", type=float, default=12.0)
    parser.add_argument("--skip-ten-msp-dashboard", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.cycles < 1:
        raise SystemExit("--cycles must be at least 1")

    suites = suite_commands(args)
    started = time.perf_counter()
    results: list[dict[str, Any]] = []
    for cycle in range(1, args.cycles + 1):
        for suite in suites:
            results.append(run_suite(cycle=cycle, suite=suite, verbose=args.verbose))

    elapsed = round(time.perf_counter() - started, 3)
    print(
        json.dumps(
            {
                "ok": True,
                "cycles": args.cycles,
                "suite_count": len(suites),
                "total_runs": len(results),
                "elapsed_seconds": elapsed,
                "msp_actions_tested": len(MSP_ACTIONS),
                "user_actions_tested": len(USER_ACTIONS),
                "local_tracking_surfaces_checked": len(LOCAL_TRACKING_SURFACES),
                "suites": [suite["name"] for suite in suites],
                "local_only": True,
                "note": "This is a local contract gate with fake SMS/Stripe transport. Use production smoke separately for live carrier, Stripe, APNs, and device proof.",
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
