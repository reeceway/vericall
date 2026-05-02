#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import uuid
from http.cookiejar import CookieJar
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, Request, build_opener


APP_PUBLIC_KEY = "dmljYWxsLXNtb2tlLXB1YmxpYy1rZXk="


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def request_json(
    opener: Any,
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    form: dict[str, str] | None = None,
) -> tuple[int, dict[str, Any]]:
    body: bytes | None = None
    request_headers = dict(headers or {})
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    elif form is not None:
        body = urlencode(form).encode("utf-8")
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"

    request = Request(url, data=body, headers=request_headers, method=method)
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        payload_text = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: {exc.code} {payload_text}") from exc


def request_html(
    opener: Any,
    method: str,
    url: str,
    *,
    form: dict[str, str] | None = None,
) -> tuple[int, str]:
    body: bytes | None = None
    headers: dict[str, str] = {}
    if form is not None:
        body = urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    request = Request(url, data=body, headers=headers, method=method)
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, response.read().decode("utf-8")
    except HTTPError as exc:
        payload_text = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: {exc.code} {payload_text}") from exc


def extract(pattern: str, html: str, label: str) -> str:
    match = re.search(pattern, html)
    if not match:
        raise RuntimeError(f"Could not find {label} in HTML response")
    return match.group(1)


def default_otp_fetch_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/_ops/staging/otp/latest"


def fetch_staging_otp(
    opener: Any,
    *,
    otp_fetch_url: str,
    phone_number: str,
    otp_secret: str | None,
    timeout_seconds: int,
    poll_interval_seconds: int,
) -> str:
    headers: dict[str, str] = {}
    if otp_secret:
        headers["X-Vicall-Staging-Ops-Secret"] = otp_secret
    query_url = f"{otp_fetch_url}?{urlencode({'phone_number': phone_number})}"
    deadline = time.time() + max(timeout_seconds, 1)
    last_error = "OTP was not available yet"
    while time.time() <= deadline:
        try:
            _, payload = request_json(opener, "GET", query_url, headers=headers)
            otp = str(payload.get("otp") or "").strip()
            if otp:
                return otp
            last_error = str(payload.get("detail") or payload.get("message") or last_error)
        except RuntimeError as exc:
            message = str(exc)
            if not any(code in message for code in ("404", "409", "423", "425", "429", "503", "504")):
                raise
            last_error = message
        time.sleep(max(poll_interval_seconds, 1))
    raise RuntimeError(f"Timed out waiting for staging OTP for {phone_number}: {last_error}")


def resolve_otp(
    opener: Any,
    *,
    otp_code: str | None,
    otp_fetch_url: str,
    phone_number: str,
    otp_secret: str | None,
    timeout_seconds: int,
    poll_interval_seconds: int,
) -> str:
    if otp_code:
        return otp_code
    return fetch_staging_otp(
        opener,
        otp_fetch_url=otp_fetch_url,
        phone_number=phone_number,
        otp_secret=otp_secret,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_interval_seconds,
    )


def onboard_app_seat(
    opener: Any,
    *,
    base_url: str,
    code: str,
    phone_number: str,
    expected_org_id: str,
    otp_code: str | None,
    otp_fetch_url: str,
    otp_secret: str | None,
    otp_timeout_seconds: int,
    otp_poll_interval_seconds: int,
) -> dict[str, Any]:
    _, access_payload = request_json(
        opener,
        "POST",
        f"{base_url}/access/validate",
        payload={"code": code, "phone_number": phone_number},
    )
    expect(
        access_payload.get("organization_id") == expected_org_id,
        f"Access code resolved to the wrong organization for {expected_org_id}",
    )
    grant_token = str(access_payload.get("grant_token") or "")
    expect(grant_token.startswith("vicg_"), "Access validation did not return a grant token")
    request_json(
        opener,
        "POST",
        f"{base_url}/access/request-otp",
        payload={
            "access_grant_token": grant_token,
            "phone_number": phone_number,
        },
    )
    otp = resolve_otp(
        opener,
        otp_code=otp_code,
        otp_fetch_url=otp_fetch_url,
        phone_number=phone_number,
        otp_secret=otp_secret,
        timeout_seconds=otp_timeout_seconds,
        poll_interval_seconds=otp_poll_interval_seconds,
    )
    _, verify_payload = request_json(
        opener,
        "POST",
        f"{base_url}/access/verify-otp",
        payload={
            "access_grant_token": grant_token,
            "phone_number": phone_number,
            "otp": otp,
            "public_key": APP_PUBLIC_KEY,
        },
    )
    expect(verify_payload.get("organization_id") == expected_org_id, "OTP verify attached the seat to the wrong organization")
    expect(str(verify_payload.get("membership_id") or ""), "OTP verify did not return a membership id")
    return verify_payload


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Smoke-test Vicall MSP/company/employee lifecycle with the real 3-step portal login flow."
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("VICALL_MSP_SMOKE_BASE_URL") or "https://vericall-twilio-voice.fly.dev",
    )
    parser.add_argument(
        "--admin-key",
        default=os.getenv("VICALL_MSP_SMOKE_ADMIN_KEY") or os.getenv("VICALL_ADMIN_API_KEY"),
    )
    parser.add_argument(
        "--seat-price-cents",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_SEAT_PRICE_CENTS") or "2000"),
    )
    parser.add_argument(
        "--owner-phone",
        default=os.getenv("VICALL_MSP_SMOKE_OWNER_PHONE"),
        help="Mobile number that will receive the portal OTP for the provisioned MSP owner",
    )
    parser.add_argument(
        "--otp-code",
        default=os.getenv("VICALL_MSP_SMOKE_OTP_CODE"),
        help="The OTP code sent to --owner-phone for the provisioned MSP owner",
    )
    parser.add_argument(
        "--otp-fetch-url",
        default=os.getenv("VICALL_MSP_SMOKE_OTP_FETCH_URL"),
        help="Optional staging-only endpoint that returns the latest OTP for --owner-phone",
    )
    parser.add_argument(
        "--otp-secret",
        default=os.getenv("VICALL_MSP_SMOKE_OTP_SECRET"),
        help="Secret sent as X-Vicall-Staging-Ops-Secret when polling --otp-fetch-url",
    )
    parser.add_argument(
        "--otp-timeout-seconds",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_OTP_TIMEOUT_SECONDS") or "90"),
        help="How long to wait for a staging OTP before failing",
    )
    parser.add_argument(
        "--otp-poll-interval-seconds",
        type=int,
        default=int(os.getenv("VICALL_MSP_SMOKE_OTP_POLL_INTERVAL_SECONDS") or "3"),
        help="How often to poll the staging OTP endpoint",
    )
    parser.add_argument(
        "--run-id",
        default=os.getenv("VICALL_MSP_SMOKE_RUN_ID"),
        help="Optional unique suffix for generated test MSP, company, user, and email data",
    )
    args = parser.parse_args()

    if not args.admin_key:
        raise RuntimeError("Provide --admin-key or set VICALL_ADMIN_API_KEY")
    if not args.owner_phone:
        raise RuntimeError("Provide --owner-phone to complete the real MSP portal login flow")
    otp_fetch_url = args.otp_fetch_url or default_otp_fetch_url(args.base_url)
    if not args.otp_code and not otp_fetch_url:
        raise RuntimeError("Provide --otp-code or configure --otp-fetch-url for unattended staging smoke")

    opener = build_opener(HTTPCookieProcessor(CookieJar()))
    run_id = re.sub(r"[^A-Za-z0-9]", "", args.run_id or "")[-10:]
    if not run_id:
        run_id = f"{int(time.time()) % 1000000:06d}{uuid.uuid4().hex[:4]}"
    phone_suffix = int(hashlib.sha256(run_id.encode("utf-8")).hexdigest()[:8], 16) % 10000000
    phone1 = f"+1555{phone_suffix:07d}"
    phone2 = f"+1666{phone_suffix:07d}"
    phone3 = f"+1777{phone_suffix:07d}"
    email = f"codex+{run_id}@example.com"
    owner_email = f"owner+{run_id}@example.com"
    owner_phone = args.owner_phone
    owner_password = "VicallTest123!"
    invite_email = f"operator+{run_id}@example.com"
    invite_phone = f"+1888{phone_suffix:07d}"

    provision_url = f"{args.base_url}/admin/provision-msp?key={args.admin_key}"
    status, html = request_html(
        opener,
        "POST",
        provision_url,
        form={
            "msp_name": f"Codex MSP {run_id}",
            "billing_email": email,
            "owner_full_name": "Codex Owner",
            "owner_email": owner_email,
            "owner_phone_number": owner_phone,
            "owner_password": owner_password,
            "company_name": f"Alpha Co {run_id}",
            "external_ref": f"PSA-{run_id}",
            "seat_price_cents": str(args.seat_price_cents),
        },
    )
    expect(status == 200, "MSP provisioning did not return 200")
    msp_id = extract(r"MSP ID:</strong> <code>([^<]+)</code>", html, "MSP ID")
    org1_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", html, "organization ID")
    code1 = extract(r"Access Code:</strong> <code>([^<]+)</code>", html, "access code")
    stripe_customer = extract(r"Stripe Customer:</strong> ([^<]+)</p>", html, "Stripe customer").replace("<code>", "").replace("</code>", "")
    expect(stripe_customer.startswith("cus_"), "Stripe customer was not attached during MSP signup")
    expect(owner_email in html, "Provisioning response did not include the owner login email")
    expect("Portal Key:" not in html, "Provisioning response still exposed the MSP portal key")

    status, login_html = request_html(opener, "GET", f"{args.base_url}/portal/login")
    expect(status == 200, "Portal login page failed to load")
    expect("Sign In with Portal Key" not in login_html, "Portal login page still exposed shared portal-key sign-in")

    status, _ = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/login",
        form={"email": owner_email, "password": owner_password},
    )
    expect(status == 200, "Credential step did not reach the phone-confirmation page")
    status, _ = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/login/phone",
        form={"phone_number": owner_phone},
    )
    expect(status == 200, "Phone-confirmation step did not reach the OTP page")
    otp_code = resolve_otp(
        opener,
        otp_code=args.otp_code,
        otp_fetch_url=otp_fetch_url,
        phone_number=owner_phone,
        otp_secret=args.otp_secret,
        timeout_seconds=args.otp_timeout_seconds,
        poll_interval_seconds=args.otp_poll_interval_seconds,
    )
    status, _ = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/login/code",
        form={"otp": otp_code},
    )
    expect(status == 200, "OTP step did not complete the portal sign-in flow")

    portal_dashboard_url = f"{args.base_url}/portal/dashboard"
    status, dashboard_html = request_html(opener, "GET", portal_dashboard_url)
    expect(status == 200, "Portal dashboard failed to load")
    expect("Offboard Company" in dashboard_html, "Portal dashboard is missing company offboarding")
    expect("Offboard Employee" in dashboard_html, "Portal dashboard is missing employee offboarding")
    expect("Issue Access Code" in dashboard_html, "Portal dashboard is missing access-code issuance")
    expect("MSP Team" in dashboard_html, "Portal dashboard is missing team management")
    expect("Stripe billing status" in dashboard_html, "Portal dashboard is missing Stripe billing readiness")
    expect("Open Billing Center" in dashboard_html, "Portal dashboard is missing the billing-center entry point")
    expect("View Audit Log" in dashboard_html, "Portal dashboard is missing the audit-log entry point")

    status, billing_html = request_html(opener, "GET", f"{args.base_url}/portal/billing")
    expect(status == 200, "Portal billing center failed to load")
    expect("Billing Center" in billing_html, "Portal billing center heading is missing")
    expect("Invoice Timeline" in billing_html, "Portal billing center is missing invoice history")
    expect("Company Rollup" in billing_html, "Portal billing center is missing company rollup")
    expect("User Usage" in billing_html, "Portal billing center is missing user usage detail")

    status, audit_html = request_html(opener, "GET", f"{args.base_url}/portal/audit")
    expect(status == 200, "Portal audit log failed to load")
    expect("Audit Log" in audit_html, "Portal audit log heading is missing")
    expect("Recent Events" in audit_html, "Portal audit log is missing recent events")

    _, portal_session_payload = request_json(
        opener,
        "POST",
        f"{args.base_url}/portal/customer-portal-session",
        payload={"return_url": f"{args.base_url}/portal/dashboard"},
    )
    portal_session_url = str(portal_session_payload.get("url") or "")
    expect(
        portal_session_url.startswith("https://billing.stripe.com/")
        or "/__test/stripe/billing-portal" in portal_session_url,
        "Stripe billing portal session was not created",
    )

    status, html = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/team/invite",
        form={
            "full_name": "Jordan Operator",
            "email": invite_email,
            "phone_number": invite_phone,
        },
    )
    expect(status == 200, "Portal team invite failed")
    expect("MSP User Ready" in html, "Portal team invite confirmation did not render")

    create_company_url = f"{args.base_url}/portal/companies/create"
    status, html = request_html(
        opener,
        "POST",
        create_company_url,
        form={
            "company_name": f"Beta Co {run_id}",
            "external_ref": f"CRM-{run_id}",
        },
    )
    expect(status == 200, "Portal company creation failed")
    org2_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", html, "second organization ID")
    code2 = extract(r"Access Code:</strong> <code>([^<]+)</code>", html, "second access code")

    status, html = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/access-codes/create",
        form={
            "organization_id": org1_id,
            "label": "Second office",
        },
    )
    expect(status == 200, "Additional access code creation failed")
    code3 = extract(r"Access Code:</strong> <code>([^<]+)</code>", html, "third access code")

    app_onboarding_results = []
    for code, phone, org_id in ((code1, phone1, org1_id), (code2, phone2, org2_id), (code3, phone3, org1_id)):
        app_onboarding_results.append(
            onboard_app_seat(
                opener,
                base_url=args.base_url,
                code=code,
                phone_number=phone,
                expected_org_id=org_id,
                otp_code=args.otp_code,
                otp_fetch_url=otp_fetch_url,
                otp_secret=args.otp_secret,
                otp_timeout_seconds=args.otp_timeout_seconds,
                otp_poll_interval_seconds=args.otp_poll_interval_seconds,
            )
        )
    expect(app_onboarding_results[0].get("billing", {}).get("status") == "skipped_billing_exempt", "MSP firm seat should be non-billable")
    expect(app_onboarding_results[1].get("billing", {}).get("status") == "invoiced", "Customer company seat should invoice immediately")
    expect(app_onboarding_results[2].get("billing", {}).get("status") == "skipped_billing_exempt", "Additional MSP firm code should stay non-billable")

    duplicate_customer_signup = onboard_app_seat(
        opener,
        base_url=args.base_url,
        code=code2,
        phone_number=phone2,
        expected_org_id=org2_id,
        otp_code=args.otp_code,
        otp_fetch_url=otp_fetch_url,
        otp_secret=args.otp_secret,
        otp_timeout_seconds=args.otp_timeout_seconds,
        otp_poll_interval_seconds=args.otp_poll_interval_seconds,
    )
    expect(
        duplicate_customer_signup.get("billing", {}).get("status") == "already_invoiced",
        "Duplicate customer-company signup should reuse the existing membership invoice",
    )

    _, preview_after_onboarding = request_json(opener, "GET", f"{args.base_url}/portal/summary")
    if not msp_id:
        msp_id = str(preview_after_onboarding["msp"]["id"])
    expect(preview_after_onboarding["msp"]["stripe_customer_id"] == stripe_customer, "Portal summary did not resolve the correct Stripe customer")
    preview_after_onboarding = preview_after_onboarding["current_billing_snapshot"]
    expect(preview_after_onboarding["total_active_seats"] == 3, "Expected 3 active seats after onboarding")
    expect(preview_after_onboarding["total_billable_seats"] == 1, "Expected only customer-company seats to be billable after onboarding")
    expect(preview_after_onboarding["total_amount_cents"] == args.seat_price_cents, "Projected bill should exclude the MSP firm seats")
    org1_line = next((line for line in preview_after_onboarding["lines"] if line["organization_id"] == org1_id), None)
    org2_line = next((line for line in preview_after_onboarding["lines"] if line["organization_id"] == org2_id), None)
    expect(org1_line is not None and org1_line["organization_billing_exempt"] is True, "Primary MSP firm was not marked billing-exempt")
    expect(org1_line["active_seats"] == 2 and org1_line["billable_seats"] == 0, "MSP firm seats should be active but non-billable")
    expect(org2_line is not None and org2_line["billable_seats"] == 1, "Secondary company seat count is wrong")

    status, users_csv = request_html(opener, "GET", f"{args.base_url}/portal/export/users.csv")
    expect(status == 200, "User CSV export failed")
    expect("phone_number" in users_csv, "User CSV header is missing")
    expect(phone1 in users_csv and phone2 in users_csv and phone3 in users_csv, "User CSV did not include all onboarded seats")

    status, usage_csv = request_html(opener, "GET", f"{args.base_url}/portal/export/usage.csv")
    expect(status == 200, "Usage CSV export failed")
    expect("phone_number" in usage_csv, "Usage CSV header is missing")

    status, html = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/memberships/deactivate",
        form={"phone_number": phone1},
    )
    expect(status == 200 and "Removed memberships:</strong> 1" in html, "Employee offboarding failed")

    _, preview_after_employee_off_payload = request_json(opener, "GET", f"{args.base_url}/portal/summary")
    preview_after_employee_off = preview_after_employee_off_payload["current_billing_snapshot"]
    expect(preview_after_employee_off["total_active_seats"] == 2, "Expected 2 active seats after employee offboarding")
    expect(preview_after_employee_off["total_billable_seats"] == 1, "MSP firm offboarding should not change billable customer seats")

    onboard_app_seat(
        opener,
        base_url=args.base_url,
        code=code1,
        phone_number=phone1,
        expected_org_id=org1_id,
        otp_code=args.otp_code,
        otp_fetch_url=otp_fetch_url,
        otp_secret=args.otp_secret,
        otp_timeout_seconds=args.otp_timeout_seconds,
        otp_poll_interval_seconds=args.otp_poll_interval_seconds,
    )

    _, preview_after_rejoin_payload = request_json(opener, "GET", f"{args.base_url}/portal/summary")
    preview_after_rejoin = preview_after_rejoin_payload["current_billing_snapshot"]
    expect(preview_after_rejoin["total_active_seats"] == 3, "Expected 3 active seats after employee rejoin")

    status, html = request_html(
        opener,
        "POST",
        f"{args.base_url}/portal/organizations/deactivate",
        form={"organization_id": org2_id},
    )
    expect(status == 200 and "Company Disabled" in html, "Company offboarding failed")

    _, preview_after_company_off_payload = request_json(opener, "GET", f"{args.base_url}/portal/summary")
    preview_after_company_off = preview_after_company_off_payload["current_billing_snapshot"]
    expect(preview_after_company_off["total_active_seats"] == 2, "Expected 2 active seats after company offboarding")
    expect(preview_after_company_off["total_billable_seats"] == 1, "Customer seats should remain billable through the current period after company offboarding")
    company_line = next((line for line in preview_after_company_off["lines"] if line["organization_id"] == org2_id), None)
    expect(company_line is not None, "Offboarded company dropped out of billing preview")
    expect(company_line["organization_active"] is False, "Offboarded company was still marked active in billing preview")

    try:
        request_json(
            opener,
            "POST",
            f"{args.base_url}/access/validate",
            payload={"code": code2, "phone_number": phone2},
        )
    except RuntimeError as exc:
        expect("403" in str(exc), "Offboarded company code failed for the wrong reason")
    else:
        raise RuntimeError("Offboarded company code still validated")

    status, filtered_audit_html = request_html(
        opener,
        "GET",
        f"{args.base_url}/portal/audit?action=portal.company.create",
    )
    expect(status == 200, "Filtered audit log failed to load")
    expect("portal.company.create" in filtered_audit_html, "Audit log did not include company-create events")
    status, refreshed_audit_html = request_html(opener, "GET", f"{args.base_url}/portal/audit")
    expect(status == 200, "Audit log reload failed")
    expect(
        "portal.membership.deactivate" in refreshed_audit_html or "portal.organization.deactivate" in refreshed_audit_html,
        "Audit log did not record destructive portal actions",
    )

    summary = {
        "msp_id": msp_id,
        "stripe_customer_id": stripe_customer,
        "org1_id": org1_id,
        "org1_code": code1,
        "org2_id": org2_id,
        "org2_code": code2,
        "org1_additional_code": code3,
        "preview_after_onboarding": preview_after_onboarding,
        "preview_after_employee_off": preview_after_employee_off,
        "preview_after_rejoin": preview_after_rejoin,
        "preview_after_company_off": preview_after_company_off,
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
