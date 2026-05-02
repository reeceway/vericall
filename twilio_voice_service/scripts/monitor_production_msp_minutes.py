#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
from typing import Any
from urllib.request import Request, urlopen


DEFAULT_BASE_URL = "https://vericall-twilio-voice.fly.dev"


def admin_key_from_fly(app_name: str) -> str:
    remote = "import os; print(os.getenv('VICALL_ADMIN_API_KEY',''))"
    encoded = base64.b64encode(remote.encode()).decode()
    command = [
        "flyctl",
        "ssh",
        "console",
        "-a",
        app_name,
        "-C",
        f"python -c \"import base64; exec(base64.b64decode('{encoded}').decode())\"",
    ]
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise RuntimeError("Could not read production admin key through Fly SSH")
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    key = lines[-1] if lines else ""
    if not key:
        raise RuntimeError("Production admin key is empty")
    return key


def request_json(url: str, *, admin_key: str) -> dict[str, Any]:
    request = Request(url, headers={"X-Admin-Key": admin_key})
    with urlopen(request, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected JSON object from {url}")
    return payload


def mask_phone(value: str | None) -> str:
    digits = "".join(ch for ch in str(value or "") if ch.isdigit())
    return f"***{digits[-4:]}" if len(digits) >= 4 else "***"


def matching_user_rows(snapshot: dict[str, Any], phone_suffix: str | None) -> list[dict[str, Any]]:
    rows = snapshot.get("user_usage") or []
    if not phone_suffix:
        return list(rows)
    suffix = "".join(ch for ch in phone_suffix if ch.isdigit())[-4:]
    return [
        row for row in rows
        if "".join(ch for ch in str(row.get("phone_number") or "") if ch.isdigit()).endswith(suffix)
    ]


def compact_snapshot(snapshot: dict[str, Any], *, phone_suffix: str | None) -> dict[str, Any]:
    users = matching_user_rows(snapshot, phone_suffix)
    return {
        "total_billable_seats": int(snapshot.get("total_billable_seats") or 0),
        "total_active_seats": int(snapshot.get("total_active_seats") or 0),
        "total_billable_minutes": int(snapshot.get("total_billable_minutes") or 0),
        "total_included_minutes": int(snapshot.get("total_included_minutes") or 0),
        "total_overage_minutes": int(snapshot.get("total_overage_minutes") or 0),
        "total_amount_cents": int(snapshot.get("total_amount_cents") or 0),
        "users": [
            {
                "organization_name": row.get("organization_name"),
                "phone": mask_phone(str(row.get("phone_number") or "")),
                "call_count": int(row.get("call_count") or 0),
                "billable_minutes": int(row.get("billable_minutes") or 0),
            }
            for row in users
        ],
        "companies": [
            {
                "organization_name": line.get("organization_name"),
                "organization_active": bool(line.get("organization_active")),
                "billing_exempt": bool(line.get("organization_billing_exempt")),
                "active_seats": int(line.get("active_seats") or 0),
                "billable_seats": int(line.get("billable_seats") or 0),
                "billable_minutes": int(line.get("billable_minutes") or 0),
                "included_minutes": int(line.get("included_minutes") or 0),
                "overage_minutes": int(line.get("overage_minutes") or 0),
                "amount_cents": int(line.get("amount_cents") or 0),
            }
            for line in snapshot.get("lines") or []
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Poll production MSP billing preview until a call-minute delta appears.")
    parser.add_argument("--base-url", default=os.getenv("VICALL_PRODUCTION_BASE_URL") or DEFAULT_BASE_URL)
    parser.add_argument("--fly-app", default=os.getenv("VICALL_PRODUCTION_FLY_APP") or "vericall-twilio-voice")
    parser.add_argument("--msp-id", required=True)
    parser.add_argument("--phone-suffix", default="")
    parser.add_argument("--admin-key", default=os.getenv("VICALL_ADMIN_API_KEY"))
    parser.add_argument("--admin-key-from-fly", action="store_true")
    parser.add_argument("--interval-seconds", type=int, default=10)
    parser.add_argument("--timeout-seconds", type=int, default=600)
    parser.add_argument("--stop-on-change", action="store_true")
    args = parser.parse_args()

    admin_key = args.admin_key
    if args.admin_key_from_fly:
        admin_key = admin_key_from_fly(args.fly_app)
    if not admin_key:
        raise RuntimeError("Provide --admin-key, VICALL_ADMIN_API_KEY, or --admin-key-from-fly")

    base_url = args.base_url.rstrip("/")
    url = f"{base_url}/admin/msps/{args.msp_id}/billing/preview"
    started = time.time()
    baseline: dict[str, Any] | None = None
    last: dict[str, Any] | None = None
    iteration = 0
    while time.time() - started <= args.timeout_seconds:
        iteration += 1
        snapshot = request_json(url, admin_key=admin_key)
        compact = compact_snapshot(snapshot, phone_suffix=args.phone_suffix or None)
        if baseline is None:
            baseline = compact
        last = compact
        delta_minutes = compact["total_billable_minutes"] - baseline["total_billable_minutes"]
        user_delta_minutes = sum(user["billable_minutes"] for user in compact["users"]) - sum(
            user["billable_minutes"] for user in baseline["users"]
        )
        event = {
            "iteration": iteration,
            "elapsed_seconds": round(time.time() - started, 1),
            "delta_total_billable_minutes": delta_minutes,
            "delta_matching_user_minutes": user_delta_minutes,
            "snapshot": compact,
        }
        print(json.dumps(event, sort_keys=True), flush=True)
        if args.stop_on_change and (delta_minutes > 0 or user_delta_minutes > 0):
            return 0
        time.sleep(max(args.interval_seconds, 1))

    if last is None:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
