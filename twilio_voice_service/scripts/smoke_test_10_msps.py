#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
SMOKE_SCRIPT = SCRIPT_DIR / "smoke_test_msp_lifecycle.py"


def run_one(index: int, args: argparse.Namespace, batch_id: str, owner_phone_block: str) -> dict[str, Any]:
    run_id = f"{batch_id}{index:04d}"[-10:]
    owner_phone = f"+1555{owner_phone_block}{index:04d}"
    cmd = [
        sys.executable,
        str(SMOKE_SCRIPT),
        "--base-url",
        args.base_url,
        "--admin-key",
        args.admin_key,
        "--owner-phone",
        owner_phone,
        "--run-id",
        run_id,
        "--seat-price-cents",
        str(args.seat_price_cents),
        "--otp-timeout-seconds",
        str(args.otp_timeout_seconds),
        "--otp-poll-interval-seconds",
        str(args.otp_poll_interval_seconds),
    ]
    if args.otp_code:
        cmd.extend(["--otp-code", args.otp_code])
    if args.otp_fetch_url:
        cmd.extend(["--otp-fetch-url", args.otp_fetch_url])
    if args.otp_secret:
        cmd.extend(["--otp-secret", args.otp_secret])

    started_at = time.time()
    completed = subprocess.run(
        cmd,
        cwd=str(SCRIPT_DIR.parents[1]),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    duration_seconds = round(time.time() - started_at, 2)
    if completed.returncode != 0:
        return {
            "index": index,
            "run_id": run_id,
            "owner_phone": owner_phone,
            "ok": False,
            "duration_seconds": duration_seconds,
            "stdout": completed.stdout[-4000:],
            "stderr": completed.stderr[-4000:],
        }

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = {"raw_stdout": completed.stdout[-4000:]}

    return {
        "index": index,
        "run_id": run_id,
        "owner_phone": owner_phone,
        "ok": True,
        "duration_seconds": duration_seconds,
        "msp_id": payload.get("msp_id"),
        "stripe_customer_id": payload.get("stripe_customer_id"),
        "org1_id": payload.get("org1_id"),
        "org2_id": payload.get("org2_id"),
        "total_billable_seats": payload.get("preview_after_company_off", {}).get("total_billable_seats"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the full MSP portal/app/billing smoke across multiple independent MSP tenants."
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("VICALL_MSP_SMOKE_BASE_URL") or "http://127.0.0.1:8091",
    )
    parser.add_argument(
        "--admin-key",
        default=os.getenv("VICALL_MSP_SMOKE_ADMIN_KEY") or os.getenv("VICALL_ADMIN_API_KEY"),
    )
    parser.add_argument(
        "--msps",
        type=int,
        default=int(os.getenv("VICALL_MSP_BULK_SMOKE_COUNT") or "10"),
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=int(os.getenv("VICALL_MSP_BULK_SMOKE_CONCURRENCY") or "1"),
    )
    parser.add_argument(
        "--seat-price-cents",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_SEAT_PRICE_CENTS") or "2000"),
    )
    parser.add_argument("--otp-code", default=os.getenv("VICALL_MSP_SMOKE_OTP_CODE"))
    parser.add_argument("--otp-fetch-url", default=os.getenv("VICALL_MSP_SMOKE_OTP_FETCH_URL"))
    parser.add_argument("--otp-secret", default=os.getenv("VICALL_MSP_SMOKE_OTP_SECRET"))
    parser.add_argument(
        "--otp-timeout-seconds",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_OTP_TIMEOUT_SECONDS") or "90"),
    )
    parser.add_argument(
        "--otp-poll-interval-seconds",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_OTP_POLL_INTERVAL_SECONDS") or "3"),
    )
    args = parser.parse_args()

    if not args.admin_key:
        raise RuntimeError("Provide --admin-key or set VICALL_ADMIN_API_KEY")
    if args.msps < 1:
        raise RuntimeError("--msps must be at least 1")
    if args.concurrency < 1:
        raise RuntimeError("--concurrency must be at least 1")

    batch_uuid = uuid.uuid4()
    batch_id = batch_uuid.hex[:6]
    owner_phone_block = f"{100 + (batch_uuid.int % 899):03d}"
    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        future_to_index = {
            executor.submit(run_one, index, args, batch_id, owner_phone_block): index
            for index in range(1, args.msps + 1)
        }
        for future in concurrent.futures.as_completed(future_to_index):
            result = future.result()
            results.append(result)
            status = "PASS" if result["ok"] else "FAIL"
            print(
                f"{status} MSP {result['index']}/{args.msps} "
                f"run_id={result['run_id']} duration={result['duration_seconds']}s",
                file=sys.stderr,
            )

    results.sort(key=lambda item: item["index"])
    failures = [result for result in results if not result["ok"]]
    summary = {
        "ok": not failures,
        "requested_msps": args.msps,
        "passed_msps": args.msps - len(failures),
        "failed_msps": len(failures),
        "concurrency": args.concurrency,
        "base_url": args.base_url,
        "results": results,
    }
    print(json.dumps(summary, indent=2))
    if failures:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
