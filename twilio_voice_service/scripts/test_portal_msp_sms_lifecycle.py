#!/usr/bin/env python3
from __future__ import annotations

import base64
import asyncio
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import HTTPException
from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

BOOTSTRAP_DIR = Path(tempfile.mkdtemp(prefix="vicall-msp-sms-bootstrap-"))
os.environ.setdefault("VICALL_CONTROL_DB_PATH", str(BOOTSTRAP_DIR / "control.db"))
os.environ.setdefault("DEVICE_BINDINGS_PATH", str(BOOTSTRAP_DIR / "device_bindings.json"))
os.environ.setdefault("VICALL_ADMIN_API_KEY", "test-admin-key")

import app as service_app  # noqa: E402
from control_plane import ControlPlaneStore  # noqa: E402


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def extract(pattern: str, html: str, label: str) -> str:
    match = re.search(pattern, html)
    if not match:
        raise AssertionError(f"Could not find {label} in HTML response")
    return match.group(1)


def twilio_identity(phone_number: str) -> str:
    digits = "".join(ch for ch in phone_number if ch.isdigit())
    if len(digits) == 10:
        digits = f"1{digits}"
    return f"user_{digits}_prod1"


def portal_sign_in(client: TestClient, *, email: str, password: str, phone_number: str) -> None:
    login_credentials = client.post(
        "/portal/login",
        data={"email": email, "password": password},
        follow_redirects=False,
    )
    expect(login_credentials.status_code == 303, login_credentials.text)
    expect(login_credentials.headers.get("location") == "/portal/login/phone", "Credential step did not redirect to phone step")

    phone_step = client.get("/portal/login/phone")
    expect(phone_step.status_code == 200, phone_step.text)
    expect("Confirm your mobile number" in phone_step.text, "Phone step did not render")

    sms_request = client.post(
        "/portal/login/phone",
        data={"phone_number": phone_number},
        follow_redirects=False,
    )
    expect(sms_request.status_code == 303, sms_request.text)
    expect(sms_request.headers.get("location") == "/portal/login/code?notice=We+sent+your+one-time+code.", "Phone step did not redirect to code step")

    code_step = client.get("/portal/login/code")
    expect(code_step.status_code == 200, code_step.text)
    expect("Enter your one-time code" in code_step.text, "Code step did not render")

    sms_verify = client.post("/portal/login/code", data={"otp": "123456"}, follow_redirects=False)
    expect(sms_verify.status_code == 303, sms_verify.text)
    expect(sms_verify.headers.get("location") == "/portal/dashboard", "SMS login did not redirect to dashboard")


def main() -> None:
    original_admin_key = os.environ.get("VICALL_ADMIN_API_KEY")
    original_control_plane = service_app.control_plane
    original_forward = service_app.forward_main_api_request
    original_fetch_staging_main_api_otp = service_app.fetch_staging_main_api_otp
    original_create_customer = service_app.create_customer
    original_fetch_customer = service_app.fetch_customer
    original_create_billing_portal_session = service_app.create_billing_portal_session
    original_create_immediate_seat_invoice = service_app.create_immediate_seat_invoice
    original_create_monthly_invoice = service_app.create_monthly_invoice
    original_stripe_enabled = service_app.stripe_enabled
    original_verify_webhook_signature = service_app.verify_webhook_signature
    original_staging_enabled = os.environ.get("VICALL_STAGING_SMOKE_ENABLED")
    original_staging_secret = os.environ.get("VICALL_STAGING_SMOKE_SECRET")
    original_main_api_base_url = os.environ.get("MAIN_API_BASE_URL")
    original_twilio_env = {
        name: os.environ.get(name)
        for name in (
            "TWILIO_ACCOUNT_SID",
            "TWILIO_API_KEY",
            "TWILIO_API_SECRET",
            "TWILIO_TWIML_APP_SID",
            "TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION",
            "VICALL_SUSPEND_MSP_ON_PAYMENT_FAILED",
        )
    }

    os.environ["VICALL_ADMIN_API_KEY"] = "test-admin-key"
    os.environ["TWILIO_ACCOUNT_SID"] = "AC00000000000000000000000000000000"
    os.environ["TWILIO_API_KEY"] = "SK00000000000000000000000000000000"
    os.environ["TWILIO_API_SECRET"] = "test_twilio_api_secret"
    os.environ["TWILIO_TWIML_APP_SID"] = "AP00000000000000000000000000000000"
    os.environ["TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION"] = "CR00000000000000000000000000000000"
    os.environ["VICALL_SUSPEND_MSP_ON_PAYMENT_FAILED"] = "true"

    otp_codes: dict[str, str] = {}
    invoice_counter = {"value": 0}
    seat_invoice_counter = {"value": 0}
    customer_payment_ready = {"value": True}

    async def fake_forward_main_api_request(
        path: str,
        *,
        method: str = "POST",
        payload: dict[str, object] | None = None,
        access_token: str | None = None,
    ) -> dict[str, object]:
        payload = payload or {}
        if path == "/auth/request-otp":
            phone_number = str(payload.get("phone_number") or "").strip()
            if not phone_number:
                raise HTTPException(status_code=400, detail="Missing phone_number")
            otp_codes[phone_number] = "123456"
            return {"status": "sent"}

        if path == "/auth/verify-otp":
            phone_number = str(payload.get("phone_number") or "").strip()
            otp = str(payload.get("otp") or "").strip()
            if not phone_number or not otp:
                raise HTTPException(status_code=400, detail="Missing phone_number or otp")
            public_key = payload.get("public_key")
            if not isinstance(public_key, str) or not public_key.strip():
                raise AssertionError("verify-otp payload must include a real public_key string")
            try:
                base64.b64decode(public_key, validate=True)
            except Exception as exc:
                raise AssertionError("verify-otp payload public_key must be valid base64") from exc
            if otp_codes.get(phone_number) != otp:
                raise HTTPException(status_code=401, detail="Invalid OTP")
            digits = "".join(ch for ch in phone_number if ch.isdigit())[-10:] or "0000000000"
            return {
                "user_id": f"user_{digits}",
                "access_token": f"access_{digits}",
                "refresh_token": f"refresh_{digits}",
            }

        if path == "/auth/check-otp":
            phone_number = str(payload.get("phone_number") or "").strip()
            otp = str(payload.get("otp") or "").strip()
            if not phone_number or not otp:
                raise HTTPException(status_code=400, detail="Missing phone_number or otp")
            if otp_codes.get(phone_number) != otp:
                raise HTTPException(status_code=401, detail="Invalid OTP")
            return {"status": "verified"}

        if path == "/contacts/sync":
            if not access_token:
                raise HTTPException(status_code=401, detail="Missing access token")
            return {}

        raise AssertionError(f"Unexpected forwarded main API request: {method} {path}")

    async def fake_create_customer(*, name: str, email: str | None, metadata: dict[str, str]) -> dict[str, str]:
        return {"id": f"cus_{metadata['msp_id'][-10:]}"}

    async def fake_fetch_customer(customer_id: str) -> dict[str, object]:
        return {
            "id": customer_id,
            "invoice_settings": {"default_payment_method": "pm_test_visa" if customer_payment_ready["value"] else None},
        }

    async def fake_create_billing_portal_session(*, customer_id: str, return_url: str) -> dict[str, str]:
        return {"url": f"https://billing.stripe.com/p/session_{customer_id[-6:]}"}

    async def fake_fetch_staging_main_api_otp(*, phone_number: str, ops_secret: str) -> dict[str, object]:
        expect(ops_secret == "staging-ops-secret", "Staging OTP lookup used the wrong shared secret")
        normalized_phone = service_app.normalize_phone_number(phone_number)
        expect(normalized_phone is not None, "Staging OTP lookup did not normalize the phone number")
        return {
            "status": "ready",
            "phone_number": normalized_phone,
            "otp": otp_codes.get(normalized_phone, "123456"),
        }

    async def fake_create_monthly_invoice(
        *,
        customer_id: str,
        msp_id: str,
        period_start: str,
        lines: list[dict[str, object]],
        idempotency_suffix: str | None = None,
    ) -> dict[str, object]:
        invoice_counter["value"] += 1
        suffix = str(invoice_counter["value"]).zfill(4)
        return {
            "invoice": {
                "id": f"in_test_{suffix}",
                "status": "open",
                "hosted_invoice_url": f"https://billing.stripe.com/invoice/in_test_{suffix}",
            },
            "line_item_ids_by_org": {
                str(line["organization_id"]): f"ili_{suffix}_{index}"
                for index, line in enumerate(lines, start=1)
            },
        }

    async def fake_create_immediate_seat_invoice(
        *,
        customer_id: str,
        msp_id: str,
        period_start: str,
        membership: dict[str, object],
        organization_name: str,
        amount_cents: int,
    ) -> dict[str, object]:
        seat_invoice_counter["value"] += 1
        suffix = str(seat_invoice_counter["value"]).zfill(4)
        return {
            "invoice": {
                "id": f"in_seat_{suffix}",
                "status": "open",
                "hosted_invoice_url": f"https://billing.stripe.com/invoice/in_seat_{suffix}",
            },
            "invoice_item": {
                "id": f"ili_seat_{suffix}",
                "customer": customer_id,
                "amount": amount_cents,
                "metadata": {
                    "msp_id": msp_id,
                    "period_start": period_start,
                    "membership_id": str(membership["membership_id"]),
                    "organization_name": organization_name,
                },
            },
        }

    try:
        tempdir = Path(tempfile.mkdtemp(prefix="vicall-msp-sms-flow-"))
        os.environ["VICALL_STAGING_SMOKE_ENABLED"] = "true"
        os.environ["VICALL_STAGING_SMOKE_SECRET"] = "staging-ops-secret"
        os.environ["MAIN_API_BASE_URL"] = "https://staging-api.example.test"
        service_app.control_plane = ControlPlaneStore(tempdir / "control.db")
        service_app.forward_main_api_request = fake_forward_main_api_request
        service_app.fetch_staging_main_api_otp = fake_fetch_staging_main_api_otp
        service_app.create_customer = fake_create_customer
        service_app.fetch_customer = fake_fetch_customer
        service_app.create_billing_portal_session = fake_create_billing_portal_session
        service_app.create_immediate_seat_invoice = fake_create_immediate_seat_invoice
        service_app.create_monthly_invoice = fake_create_monthly_invoice
        service_app.stripe_enabled = lambda: True
        service_app.verify_webhook_signature = lambda payload, signature_header: True

        client = TestClient(service_app.app, base_url="https://testserver")
        admin_key = "test-admin-key"
        owner_email = "owner@testmsp.com"
        owner_phone = "+14155550123"
        owner_password = "VicallOwner123!"
        invite_email = "operator@testmsp.com"
        invite_phone = "+14155550124"
        read_only_email = "readonly@testmsp.com"
        read_only_phone = "+14155550125"
        read_only_password = "ReadOnlyUser123!"
        employee_phones = {
            "alpha_primary": "+14155550131",
            "beta_primary": "+14155550132",
            "beta_second": "+14155550136",
            "alpha_second": "+14155550133",
            "beta_overflow": "+14155550134",
            "alpha_code_overflow": "+14155550135",
        }

        provision = client.post(
            f"/admin/provision-msp?key={admin_key}",
            data={
                "msp_name": "SMS Test MSP",
                "billing_email": "billing@testmsp.com",
                "seat_price_cents": "2000",
                "owner_full_name": "Taylor MSP",
                "owner_email": owner_email,
                "owner_phone_number": owner_phone,
                "owner_password": owner_password,
                "company_name": "Alpha Co",
                "external_ref": "PSA-ALPHA",
            },
        )
        expect(provision.status_code == 200, provision.text)
        msp_id = extract(r"MSP ID:</strong> <code>([^<]+)</code>", provision.text, "MSP ID")
        org1_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", provision.text, "organization ID")
        code1 = extract(r"Access Code:</strong> <code>([^<]+)</code>", provision.text, "primary access code")
        stripe_customer = extract(r"Stripe Customer:</strong> ([^<]+)</p>", provision.text, "Stripe customer").replace("<code>", "").replace("</code>", "")
        expect(owner_phone in provision.text, "Provisioning response did not include the MSP phone number")
        expect("Non-billable MSP firm" in provision.text, "Provisioning did not mark the MSP firm as non-billable")
        expect("Portal Key:" not in provision.text, "Provisioning response still exposed the MSP portal key")
        expect(owner_password not in provision.text, "Provisioning response exposed the owner password")
        expect("/portal/setup-password?token=" in provision.text, "Provisioning response did not include a one-time setup link")

        login_page = client.get("/portal/login")
        expect(login_page.status_code == 200, login_page.text)
        expect("Email + Password" in login_page.text, "Login page did not render the email/password step")
        expect("Mobile Number" not in login_page.text, "Landing page should not ask for phone number yet")
        expect("Sign In with Portal Key" not in login_page.text, "Login page still exposed shared portal-key sign-in")

        magic_link_request = client.post("/portal/login/request", data={"email": owner_email})
        expect(magic_link_request.status_code == 200, magic_link_request.text)
        expect("Sign-In Link Unavailable" in magic_link_request.text, "Magic-link fallback response was not rendered safely")
        expect("/portal/login/verify?token=" not in magic_link_request.text, "Magic-link fallback still exposed a live login URL")

        lockout_client = TestClient(service_app.app, base_url="https://testserver")
        lockout_login = lockout_client.post(
            "/portal/login",
            data={"email": owner_email, "password": owner_password},
            follow_redirects=False,
        )
        expect(lockout_login.status_code == 303, lockout_login.text)
        phone_lockout_response = None
        for _ in range(service_app.PORTAL_LOGIN_MAX_ATTEMPTS):
            phone_lockout_response = lockout_client.post(
                "/portal/login/phone",
                data={"phone_number": "4155550000"},
            )
        expect(phone_lockout_response is not None, "Phone lockout response was not captured")
        expect(phone_lockout_response.status_code == 429, "Repeated bad phone confirmation did not lock the challenge")
        expect("Too many sign-in attempts" in phone_lockout_response.text, "Lockout response did not explain the login reset")

        portal_sign_in(
            client,
            email=owner_email,
            password=owner_password,
            phone_number="415-555-0123",
        )
        staging_otp = client.get(
            "/_ops/staging/otp/latest",
            params={"phone_number": "415-555-0123"},
            headers={"X-Vicall-Staging-Ops-Secret": "staging-ops-secret"},
        )
        expect(staging_otp.status_code == 200, staging_otp.text)
        expect(staging_otp.json().get("otp") == "123456", "Staging OTP endpoint did not return the issued login code")
        blocked_staging_otp = client.get(
            "/_ops/staging/otp/latest",
            params={"phone_number": "415-555-0123"},
        )
        expect(blocked_staging_otp.status_code == 401, blocked_staging_otp.text)

        dashboard = client.get("/portal/dashboard")
        expect(dashboard.status_code == 200, dashboard.text)
        for marker in (
            "Customer Companies",
            "Billable Seats",
            "Used / Included Minutes",
            "Projected Monthly Bill",
            "MSP Team",
            "Stripe billing status",
        ):
            expect(marker in dashboard.text, f"Portal dashboard is missing {marker}")

        billing_center = client.get("/portal/billing")
        expect(billing_center.status_code == 200, billing_center.text)
        for marker in (
            "Billing Center",
            "Invoice Timeline",
            "Company Rollup",
            "User Usage",
        ):
            expect(marker in billing_center.text, f"Billing center is missing {marker}")

        portal_session = client.post(
            "/portal/customer-portal-session",
            json={"return_url": "https://example.com/portal"},
        )
        expect(portal_session.status_code == 200, portal_session.text)
        expect(
            str(portal_session.json().get("url") or "").startswith("https://billing.stripe.com/"),
            "Stripe customer portal session was not created",
        )

        invite = client.post(
            "/portal/team/invite",
            data={
                "full_name": "Jordan Operator",
                "email": invite_email,
                "phone_number": invite_phone,
            },
        )
        expect(invite.status_code == 200, invite.text)
        expect(invite_phone in invite.text, "Team invite response did not include the phone number")
        expect("/portal/setup-password?token=" in invite.text, "Team invite did not include a one-time setup link")
        invite_setup_token = extract(r"/portal/setup-password\?token=([^\"<]+)", invite.text, "team setup token")
        setup_page = client.get(f"/portal/setup-password?token={invite_setup_token}")
        expect(setup_page.status_code == 200, setup_page.text)
        expect(invite_email in setup_page.text, "Setup page did not identify the invited user")
        operator_password = "OperatorSetup123!"
        setup_submit = client.post(
            "/portal/setup-password",
            data={
                "token": invite_setup_token,
                "password": operator_password,
                "password_confirm": operator_password,
            },
        )
        expect(setup_submit.status_code == 200, setup_submit.text)
        expect("Portal Password Ready" in setup_submit.text, "Setup password confirmation did not render")
        setup_reuse = client.get(f"/portal/setup-password?token={invite_setup_token}")
        expect(setup_reuse.status_code == 410, "Setup link could be reused after password creation")
        operator_client = TestClient(service_app.app, base_url="https://testserver")
        portal_sign_in(
            operator_client,
            email=invite_email,
            password=operator_password,
            phone_number=invite_phone,
        )
        operator_dashboard = operator_client.get("/portal/dashboard")
        expect(operator_dashboard.status_code == 200, operator_dashboard.text)
        expect("Operator" in operator_dashboard.text, "Setup-password operator could not reach the portal")

        read_only_invite = client.post(
            "/portal/team/invite",
            data={
                "full_name": "Avery Readonly",
                "email": read_only_email,
                "phone_number": read_only_phone,
                "role": "read_only",
                "password": read_only_password,
            },
        )
        expect(read_only_invite.status_code == 200, read_only_invite.text)
        expect("Read Only" in read_only_invite.text, "Read-only invite did not preserve the requested role")
        expect(read_only_password not in read_only_invite.text, "Read-only invite exposed the submitted password")

        customer_payment_ready["value"] = False
        blocked_customer_company = client.post(
            "/portal/companies/create",
            data={
                "company_name": "Blocked Billing Co",
                "external_ref": "CRM-BLOCKED",
            },
        )
        expect(blocked_customer_company.status_code == 200, blocked_customer_company.text)
        expect("Payment Method Required" in blocked_customer_company.text, "Customer company creation was not blocked without payment")
        customer_payment_ready["value"] = True

        create_company = client.post(
            "/portal/companies/create",
            data={
                "company_name": "Beta Co",
                "external_ref": "CRM-BETA",
                "provisioned_seats": "2",
            },
        )
        expect(create_company.status_code == 200, create_company.text)
        expect("Provisioned Seats:</strong> 2" in create_company.text, "Company creation did not record provisioned seats")
        expect("Billable customer company" in create_company.text, "Customer company was not marked billable")
        org2_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", create_company.text, "second organization ID")
        code2 = extract(r"Access Code:</strong> <code>([^<]+)</code>", create_company.text, "second access code")

        second_code = client.post(
            "/portal/access-codes/create",
            data={
                "organization_id": org1_id,
                "label": "Second office",
                "max_activations": "1",
            },
        )
        expect(second_code.status_code == 200, second_code.text)
        expect("Seat Cap On This Code:</strong> 1" in second_code.text, "Access code creation did not record the seat cap")
        code3 = extract(r"Access Code:</strong> <code>([^<]+)</code>", second_code.text, "third access code")
        code3_id = extract(r"Access Code ID:</strong> <code>([^<]+)</code>", second_code.text, "third access code ID")

        access_validation = client.post(
            "/access/validate",
            json={"code": code1, "phone_number": employee_phones["alpha_primary"]},
        )
        expect(access_validation.status_code == 200, access_validation.text)
        access_payload = access_validation.json()
        expect(access_payload.get("organization_id") == org1_id, "Primary access code resolved to the wrong organization")
        expect(access_payload.get("grant_token"), "Access validation did not return an access grant token")

        request_otp = client.post(
            "/access/request-otp",
            json={
                "phone_number": employee_phones["alpha_primary"],
                "access_grant_token": access_payload["grant_token"],
            },
        )
        expect(request_otp.status_code == 200, request_otp.text)

        verify_otp = client.post(
            "/access/verify-otp",
            json={
                "phone_number": employee_phones["alpha_primary"],
                "otp": "123456",
                "public_key": service_app.generate_ephemeral_public_key(),
                "access_grant_token": access_payload["grant_token"],
            },
        )
        expect(verify_otp.status_code == 200, verify_otp.text)
        expect(
            verify_otp.json().get("organization_id") == org1_id,
            "Access OTP verification did not preserve the organization context",
        )
        first_billing = verify_otp.json().get("billing") or {}
        expect(first_billing.get("status") == "skipped_billing_exempt", f"MSP firm signup should be non-billable: {first_billing}")
        service_app.control_plane.record_seat_billing_event(
            membership={
                "membership_id": verify_otp.json()["membership_id"],
                "organization_id": org1_id,
                "msp_id": msp_id,
                "phone_number": employee_phones["alpha_primary"],
                "user_id": "user_0131",
            },
            period_start=service_app.isoformat(service_app.month_start()),
            seat_price_cents=2000,
            amount_cents=2000,
            stripe_invoice_id="in_legacy_firm",
            stripe_invoice_item_id="ili_legacy_firm",
            hosted_invoice_url="https://billing.stripe.com/invoice/in_legacy_firm",
            status="paid",
        )
        firm_snapshot = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(firm_snapshot["total_billable_seats"] == 0, "Legacy firm invoice events should not make firm seats billable")
        expect(firm_snapshot["total_invoiced_seats"] == 0, "Legacy firm invoice events should not count as invoiced seats")
        expect(firm_snapshot["total_invoiced_amount_cents"] == 0, "Legacy firm invoice events should not count as invoiced revenue")
        alpha_primary_identity = twilio_identity(employee_phones["alpha_primary"])
        active_binding = client.post(
            "/calls/device-binding",
            json={
                "identity": alpha_primary_identity,
                "voip_token": "abcdef1234567890",
                "platform": "ios",
                "context": "active-seat-test",
            },
        )
        expect(active_binding.status_code == 200, active_binding.text)
        active_token = client.post(
            "/calls/twilio-token",
            json={
                "identity": alpha_primary_identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        )
        expect(active_token.status_code == 200, active_token.text)
        active_voice = client.post(
            "/calls/twilio-voice",
            data={
                "From": alpha_primary_identity,
                "To": alpha_primary_identity,
                "CallSid": "CAactivevoice0001",
            },
        )
        expect(active_voice.status_code == 200, active_voice.text)
        expect("<Client" in active_voice.text, "Active voice routing did not return client TwiML")

        duplicate_validation = client.post(
            "/access/validate",
            json={"code": code1, "phone_number": employee_phones["alpha_primary"]},
        )
        expect(duplicate_validation.status_code == 200, duplicate_validation.text)
        duplicate_request_otp = client.post(
            "/access/request-otp",
            json={
                "phone_number": employee_phones["alpha_primary"],
                "access_grant_token": duplicate_validation.json()["grant_token"],
            },
        )
        expect(duplicate_request_otp.status_code == 200, duplicate_request_otp.text)
        duplicate_verify_otp = client.post(
            "/access/verify-otp",
            json={
                "phone_number": employee_phones["alpha_primary"],
                "otp": "123456",
                "public_key": service_app.generate_ephemeral_public_key(),
                "access_grant_token": duplicate_validation.json()["grant_token"],
            },
        )
        expect(duplicate_verify_otp.status_code == 200, duplicate_verify_otp.text)
        duplicate_billing = duplicate_verify_otp.json().get("billing") or {}
        expect(
            duplicate_billing.get("status") == "skipped_billing_exempt",
            f"Duplicate firm signup should stay non-billable: {duplicate_billing}",
        )
        expect(seat_invoice_counter["value"] == 0, "Firm signup created an immediate seat invoice")

        beta_validation = client.post(
            "/access/validate",
            json={"code": code2, "phone_number": employee_phones["beta_primary"]},
        )
        expect(beta_validation.status_code == 200, beta_validation.text)
        beta_request_otp = client.post(
            "/access/request-otp",
            json={
                "phone_number": employee_phones["beta_primary"],
                "access_grant_token": beta_validation.json()["grant_token"],
            },
        )
        expect(beta_request_otp.status_code == 200, beta_request_otp.text)
        beta_verify_otp = client.post(
            "/access/verify-otp",
            json={
                "phone_number": employee_phones["beta_primary"],
                "otp": "123456",
                "public_key": service_app.generate_ephemeral_public_key(),
                "access_grant_token": beta_validation.json()["grant_token"],
            },
        )
        expect(beta_verify_otp.status_code == 200, beta_verify_otp.text)
        beta_billing = beta_verify_otp.json().get("billing") or {}
        expect(beta_billing.get("status") == "invoiced", f"Customer seat signup did not create an immediate invoice: {beta_billing}")
        expect(beta_billing.get("invoice_id") == "in_seat_0001", "First customer seat invoice ID was not returned")
        expect(seat_invoice_counter["value"] == 1, "Customer signup did not create exactly one immediate invoice")

        for code, phone_number, org_id in (
            (code2, employee_phones["beta_second"], org2_id),
            (code3, employee_phones["alpha_second"], org1_id),
        ):
            access_validation = client.post(
                "/access/validate",
                json={"code": code, "phone_number": phone_number},
            )
            expect(access_validation.status_code == 200, access_validation.text)
            access_payload = access_validation.json()
            expect(access_payload.get("organization_id") == org_id, f"Access code resolved to the wrong organization for {org_id}")

            activate = client.post(
                "/admin/memberships/activate",
                headers={"X-Admin-Key": admin_key},
                json={
                    "organization_id": org_id,
                    "phone_number": phone_number,
                    "user_id": f"user_{phone_number[-4:]}",
                    "access_code_id": access_payload.get("access_code_id"),
                },
            )
            expect(activate.status_code == 200, activate.text)

        summary_after_onboarding = client.get("/portal/summary")
        expect(summary_after_onboarding.status_code == 200, summary_after_onboarding.text)
        onboarding_payload = summary_after_onboarding.json()
        expect(onboarding_payload["msp"]["stripe_customer_id"] == stripe_customer, "Portal summary resolved the wrong Stripe customer")
        billing_after_onboarding = onboarding_payload["current_billing_snapshot"]
        expect(billing_after_onboarding["total_active_seats"] == 4, "Expected 4 active seats after onboarding")
        expect(billing_after_onboarding["total_billable_seats"] == 2, "Expected only customer-company seats to be billable")
        expect(billing_after_onboarding["total_invoiced_seats"] == 1, "Expected the app-verified seat to be invoiced immediately")
        expect(billing_after_onboarding["total_unbilled_seats"] == 1, "Expected the second customer seat to remain in monthly catch-up")
        expect(billing_after_onboarding["total_amount_cents"] == 4000, "Projected bill should only include customer seats")
        expect(billing_after_onboarding["total_unbilled_amount_cents"] == 2000, "Monthly catch-up should only include uninvoiced customer seats")
        org1_line = next((line for line in billing_after_onboarding["lines"] if line["organization_id"] == org1_id), None)
        org2_line = next((line for line in billing_after_onboarding["lines"] if line["organization_id"] == org2_id), None)
        expect(org1_line is not None and org1_line["billable_seats"] == 0, "MSP firm seats should not be billable")
        expect(org1_line is not None and org1_line["organization_billing_exempt"], "MSP firm line was not marked billing-exempt")
        expect(org2_line is not None and org2_line["billable_seats"] == 2, "Customer company seat count is wrong")

        service_app.control_plane.record_call_event(
            canonical_key="test:overage-beta-primary",
            caller_identity=twilio_identity(employee_phones["beta_primary"]),
            callee_identity=twilio_identity(employee_phones["beta_primary"]),
            twilio_call_sid="CAoveragealpha0001",
            leg_role="client",
            status="completed",
            callback_event="completed",
            duration_seconds=(450 * 2 + 10) * 60,
        )
        overage_snapshot = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(overage_snapshot["total_billable_minutes"] == 910, "Call minutes did not roll up into the billing snapshot")
        expect(overage_snapshot["total_included_minutes"] == 900, "Included minutes should equal 450 minutes times customer seats")
        expect(overage_snapshot["total_overage_minutes"] == 10, "Overage should start after 450 minutes times billable seats")
        expect(overage_snapshot["total_overage_amount_decicents"] == 10, "Overage should accrue at $0.001 per minute")
        expect(overage_snapshot["total_overage_amount_cents"] == 1, "Overage should round at the company invoice line")
        expect(overage_snapshot["total_amount_cents"] == 4001, "Projected bill did not include overage cents")
        beta_usage = next(
            (
                row
                for row in overage_snapshot["user_usage"]
                if row["phone_number"] == employee_phones["beta_primary"]
            ),
            None,
        )
        expect(beta_usage is not None, "User-level usage did not include the active customer phone number")
        expect(beta_usage["billable_minutes"] == 910, "User-level minutes did not track the overage call")

        company_manage = client.get(f"/portal/companies/{org1_id}")
        expect(company_manage.status_code == 200, company_manage.text)
        for marker in (
            "Company Settings",
            "Create Access Code",
            "Access Codes",
            "Signed-Up Numbers",
            employee_phones["alpha_primary"],
            employee_phones["alpha_second"],
            "Second office",
        ):
            expect(marker in company_manage.text, f"Company manage page is missing {marker}")

        update_company = client.post(
            "/portal/companies/update",
            data={
                "organization_id": org2_id,
                "external_ref": "CRM-BETA-UPDATED",
                "provisioned_seats": "2",
            },
        )
        expect(update_company.status_code == 200, update_company.text)
        expect("Company Updated" in update_company.text, "Company update confirmation did not render")
        expect("CRM-BETA-UPDATED" in update_company.text, "Company update did not persist external reference")
        updated_org2 = service_app.control_plane.get_organization_for_msp(msp_id=msp_id, organization_id=org2_id)
        expect(updated_org2 is not None and updated_org2["external_ref"] == "CRM-BETA-UPDATED", "Company update was not stored")

        beta_overflow = client.post(
            "/access/validate",
            json={"code": code2, "phone_number": employee_phones["beta_overflow"]},
        )
        expect(beta_overflow.status_code == 409, beta_overflow.text)
        expect("provisioned seat limit" in beta_overflow.text, "Company seat limit was not enforced")

        alpha_code_overflow = client.post(
            "/access/validate",
            json={"code": code3, "phone_number": employee_phones["alpha_code_overflow"]},
        )
        expect(alpha_code_overflow.status_code == 409, alpha_code_overflow.text)
        expect("access code has no seats remaining" in alpha_code_overflow.text, "Access-code seat cap was not enforced")

        deactivate_code = client.post(
            "/portal/access-codes/deactivate",
            data={"organization_id": org1_id, "access_code_id": code3_id},
        )
        expect(deactivate_code.status_code == 200, deactivate_code.text)
        expect("Access Code Disabled" in deactivate_code.text, "Access-code deactivation confirmation did not render")
        disabled_code_validate = client.post(
            "/access/validate",
            json={"code": code3, "phone_number": "+14155550137"},
        )
        expect(disabled_code_validate.status_code == 403, disabled_code_validate.text)
        expect("Invalid access code" in disabled_code_validate.text, "Disabled access code did not fail closed")

        employee_offboard = client.post(
            "/portal/memberships/deactivate",
            data={"organization_id": org1_id, "phone_number": employee_phones["alpha_primary"]},
        )
        expect(employee_offboard.status_code == 200, employee_offboard.text)
        expect("Removed memberships:</strong> 1" in employee_offboard.text, "Employee offboarding did not deactivate a seat")
        expect(org1_id in employee_offboard.text, "Employee offboarding did not report the scoped company it touched")

        summary_after_employee_offboard = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(summary_after_employee_offboard["total_active_seats"] == 3, "Expected 3 active seats after employee offboarding")
        expect(summary_after_employee_offboard["total_billable_seats"] == 2, "Expected 2 billable customer seats after firm employee offboarding")
        inactive_binding = client.post(
            "/calls/device-binding",
            json={
                "identity": alpha_primary_identity,
                "voip_token": "abcdef1234567890",
                "platform": "ios",
                "context": "offboarded-seat-test",
            },
        )
        expect(inactive_binding.status_code == 403, inactive_binding.text)
        inactive_token = client.post(
            "/calls/twilio-token",
            json={
                "identity": alpha_primary_identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        )
        expect(inactive_token.status_code == 403, inactive_token.text)
        inactive_voice = client.post(
            "/calls/twilio-voice",
            data={
                "From": alpha_primary_identity,
                "To": alpha_primary_identity,
                "CallSid": "CAinactivevoice0001",
            },
        )
        expect(inactive_voice.status_code == 200, inactive_voice.text)
        expect("caller account is inactive" in inactive_voice.text, "Offboarded voice route did not fail closed")

        revalidate = client.post(
            "/access/validate",
            json={"code": code1, "phone_number": employee_phones["alpha_primary"]},
        )
        expect(revalidate.status_code == 200, revalidate.text)
        reactivate = client.post(
            "/admin/memberships/activate",
            headers={"X-Admin-Key": admin_key},
            json={
                "organization_id": org1_id,
                "phone_number": employee_phones["alpha_primary"],
                "user_id": f"user_{employee_phones['alpha_primary'][-4:]}",
                "access_code_id": revalidate.json().get("access_code_id"),
            },
        )
        expect(reactivate.status_code == 200, reactivate.text)

        summary_after_rejoin = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(summary_after_rejoin["total_active_seats"] == 4, "Expected 4 active seats after employee rejoin")

        account_delete = client.post(
            "/account/delete",
            headers={"Authorization": "Bearer access_4155550131"},
            json={
                "phone_number": employee_phones["alpha_primary"],
                "identity": alpha_primary_identity,
            },
        )
        expect(account_delete.status_code == 200, account_delete.text)
        expect(account_delete.json()["deactivated_memberships"] == 1, "Account deletion did not deactivate the active membership")
        expect(account_delete.json()["device_bindings_removed"] >= 1, "Account deletion did not remove the stored device binding")
        deleted_token = client.post(
            "/calls/twilio-token",
            json={
                "identity": alpha_primary_identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        )
        expect(deleted_token.status_code == 403, deleted_token.text)
        deletion_audit_events = service_app.control_plane.list_msp_audit_events(msp_id, limit=50)
        expect(
            any(event["action"] == "system.account.deleted_access_removed" for event in deletion_audit_events),
            "Account deletion did not write an MSP-visible audit event",
        )

        reactivate_after_delete = client.post(
            "/admin/memberships/activate",
            headers={"X-Admin-Key": admin_key},
            json={
                "organization_id": org1_id,
                "phone_number": employee_phones["alpha_primary"],
                "user_id": "user_0131",
                "access_code_id": revalidate.json().get("access_code_id"),
            },
        )
        expect(reactivate_after_delete.status_code == 200, reactivate_after_delete.text)
        summary_after_delete_rejoin = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(summary_after_delete_rejoin["total_active_seats"] == 4, "Expected 4 active seats after deletion reprovisioning")

        company_offboard = client.post(
            "/portal/organizations/deactivate",
            data={"organization_id": org2_id},
        )
        expect(company_offboard.status_code == 200, company_offboard.text)
        expect("Company Disabled" in company_offboard.text, "Company offboarding confirmation did not render")

        summary_after_company_offboard = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(summary_after_company_offboard["total_active_seats"] == 2, "Expected 2 active seats after company offboarding")
        expect(summary_after_company_offboard["total_billable_seats"] == 2, "Expected customer seats to remain billable through the period after company offboarding")
        company_line = next((line for line in summary_after_company_offboard["lines"] if line["organization_id"] == org2_id), None)
        expect(company_line is not None and company_line["billable_seats"] == 2, "Offboarded company dropped out of grouped billing")

        offboarded_code_validate = client.post(
            "/access/validate",
            json={"code": code2, "phone_number": employee_phones["beta_primary"]},
        )
        expect(offboarded_code_validate.status_code == 403, offboarded_code_validate.text)
        expect("Invalid access code" in offboarded_code_validate.text, "Offboarded company code did not fail closed")
        beta_identity = twilio_identity(employee_phones["beta_primary"])
        offboarded_company_token = client.post(
            "/calls/twilio-token",
            json={
                "identity": beta_identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        )
        expect(offboarded_company_token.status_code == 403, offboarded_company_token.text)

        billing_period = service_app.month_start()
        billing_period_month = billing_period.strftime("%Y-%m")
        billing_run = client.post(
            f"/admin/billing/run-all?key={admin_key}",
            data={"period_start": billing_period_month},
        )
        expect(billing_run.status_code == 200, billing_run.text)
        expect("Monthly Billing Run Complete" in billing_run.text, "Billing run confirmation did not render")
        expect(service_app.isoformat(billing_period) in billing_run.text, "Billing run did not confirm the selected period")

        recorded_runs = service_app.control_plane.billing_runs_for_msp(msp_id)
        expect(len(recorded_runs) == 1, "Expected one billing run to be recorded")
        expect(str(recorded_runs[0].get("stripe_invoice_id") or "").startswith("in_test_"), "Expected a fake invoice to be recorded")
        expect(recorded_runs[0]["status"] == "open", "Billing run status should mirror the created invoice status")
        billing_period_summary = service_app.control_plane.billing_period_summaries_for_msp(msp_id, limit=1)[0]
        expect(int(billing_period_summary["company_count"]) >= 1, "Billing run did not persist organization usage rows")
        expect(int(billing_period_summary["total_billable_minutes"]) >= 910, "Billing run did not persist monthly minute usage")
        expect(
            str(recorded_runs[0].get("hosted_invoice_url") or "").startswith("https://billing.stripe.com/invoice/"),
            "Expected the hosted invoice URL to be stored with the billing run",
        )

        invoice_finalized = client.post(
            "/stripe/webhook",
            content=json.dumps(
                {
                    "type": "invoice.finalized",
                    "data": {
                        "object": {
                            "id": "in_test_0001",
                            "hosted_invoice_url": "https://billing.stripe.com/invoice/in_test_0001",
                            "metadata": {"msp_id": msp_id},
                        }
                    },
                }
            ),
            headers={"stripe-signature": "test"},
        )
        expect(invoice_finalized.status_code == 200, invoice_finalized.text)
        finalized_run = service_app.control_plane.billing_run_by_invoice_id("in_test_0001")
        expect(finalized_run is not None and finalized_run["status"] == "finalized", "Invoice finalized webhook did not update billing run status")

        invoice_paid = client.post(
            "/stripe/webhook",
            content=json.dumps(
                {
                    "type": "invoice.paid",
                    "data": {
                        "object": {
                            "id": "in_test_0001",
                            "hosted_invoice_url": "https://billing.stripe.com/invoice/in_test_0001",
                            "metadata": {"msp_id": msp_id},
                        }
                    },
                }
            ),
            headers={"stripe-signature": "test"},
        )
        expect(invoice_paid.status_code == 200, invoice_paid.text)
        paid_run = service_app.control_plane.billing_run_by_invoice_id("in_test_0001")
        expect(paid_run is not None and paid_run["status"] == "paid", "Invoice paid webhook did not update billing run status")

        billing_center_after_run = client.get("/portal/billing")
        expect(billing_center_after_run.status_code == 200, billing_center_after_run.text)
        expect("in_test_0001" in billing_center_after_run.text, "Billing center did not render the created invoice")
        expect("https://billing.stripe.com/invoice/in_test_0001" in billing_center_after_run.text, "Billing center did not link to the hosted invoice")
        summary_after_billing_run = client.get("/portal/summary").json()["current_billing_snapshot"]
        expect(summary_after_billing_run["total_invoiced_seats"] == 2, "Monthly catch-up did not mark all customer seats invoiced")
        expect(summary_after_billing_run["total_unbilled_seats"] == 0, "Monthly catch-up left seats uninvoiced")
        expect(
            service_app.first_day_billing_period(datetime(2026, 4, 26, tzinfo=timezone.utc)) is None,
            "Automatic billing should only run on the 1st of the month",
        )
        expect(
            service_app.first_day_billing_period(datetime(2026, 5, 1, 12, 0, tzinfo=timezone.utc))
            == datetime(2026, 4, 1, tzinfo=timezone.utc),
            "Automatic billing should invoice the previous completed month",
        )
        service_app.auto_billing_last_period = None
        next_billing_day = (billing_period.replace(day=28) + timedelta(days=4)).replace(day=1, hour=12)
        automatic_run = asyncio.run(
            service_app.maybe_run_first_day_auto_billing(
                next_billing_day
            )
        )
        expect(len(automatic_run) == 1, "Automatic billing did not evaluate the MSP on the 1st")
        expect(automatic_run[0]["status"] == "already_ran", "Automatic billing should reuse the existing monthly invoice")
        expect(invoice_counter["value"] == 1, "Automatic billing created a duplicate Stripe invoice")
        automatic_second_pass = asyncio.run(
            service_app.maybe_run_first_day_auto_billing(
                next_billing_day.replace(hour=18)
            )
        )
        expect(automatic_second_pass == [], "Automatic billing should be idempotent after the first successful pass")

        create_third_company = client.post(
            "/portal/companies/create",
            data={
                "company_name": "Gamma Co",
                "external_ref": "CRM-GAMMA",
                "provisioned_seats": "2",
            },
        )
        expect(create_third_company.status_code == 200, create_third_company.text)
        org3_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", create_third_company.text, "third organization ID")

        shared_phone = "+14155550139"
        for org_id in (org1_id, org3_id):
            activate_shared = client.post(
                "/admin/memberships/activate",
                headers={"X-Admin-Key": admin_key},
                json={
                    "organization_id": org_id,
                    "phone_number": shared_phone,
                    "user_id": "user_shared_0139",
                },
            )
            expect(activate_shared.status_code == 200, activate_shared.text)

        scoped_offboard = client.post(
            "/portal/memberships/deactivate",
            data={"organization_id": org1_id, "phone_number": "4155550139", "user_id": "user_shared_0139"},
        )
        expect(scoped_offboard.status_code == 200, scoped_offboard.text)
        expect("Removed memberships:</strong> 1" in scoped_offboard.text, "Scoped employee offboarding removed the wrong number of memberships")
        expect(org1_id in scoped_offboard.text and org3_id not in scoped_offboard.text, "Scoped employee offboarding touched the wrong company")

        org1_detail = service_app.control_plane.organization_detail_for_msp(msp_id=msp_id, organization_id=org1_id)
        org3_detail = service_app.control_plane.organization_detail_for_msp(msp_id=msp_id, organization_id=org3_id)
        org1_shared = next(
            membership for membership in org1_detail["memberships"] if membership["phone_number"] == shared_phone
        )
        org3_shared = next(
            membership for membership in org3_detail["memberships"] if membership["phone_number"] == shared_phone
        )
        expect(org1_shared["status"] == "inactive", "Scoped offboarding did not deactivate the selected company membership")
        expect(org3_shared["status"] == "active", "Scoped offboarding incorrectly deactivated the second company membership")

        export_companies = client.get("/portal/export/companies.csv")
        expect(export_companies.status_code == 200, export_companies.text)
        expect("text/csv" in str(export_companies.headers.get("content-type") or ""), "Companies export did not return CSV")

        export_users = client.get("/portal/export/users.csv")
        expect(export_users.status_code == 200, export_users.text)
        expect("text/csv" in str(export_users.headers.get("content-type") or ""), "Users export did not return CSV")

        export_usage = client.get("/portal/export/usage.csv")
        expect(export_usage.status_code == 200, export_usage.text)
        expect("text/csv" in str(export_usage.headers.get("content-type") or ""), "Usage export did not return CSV")

        audit_page = client.get("/portal/audit")
        expect(audit_page.status_code == 200, audit_page.text)
        for marker in (
            "Audit Log",
            "portal.company.create",
            "portal.company.update",
            "portal.access_code.deactivate",
            "portal.membership.deactivate",
            "system.billing.run",
        ):
            expect(marker in audit_page.text, f"Audit log page is missing {marker}")

        filtered_audit_page = client.get("/portal/audit?action=portal.export.users")
        expect(filtered_audit_page.status_code == 200, filtered_audit_page.text)
        expect("portal.export.users" in filtered_audit_page.text, "Filtered audit log did not render the export action")

        audit_events = service_app.control_plane.list_msp_audit_events(msp_id, limit=250)
        action_names = {event["action"] for event in audit_events}
        for required_action in (
            "admin.msp.provisioned",
            "portal.login.success.sms",
            "portal.billing.portal_session",
            "portal.company.create",
            "portal.company.update",
            "portal.access_code.create",
            "portal.access_code.deactivate",
            "portal.membership.deactivate",
            "portal.organization.deactivate",
            "portal.msp_user.upsert",
            "portal.export.companies",
            "portal.export.users",
            "portal.export.usage",
            "system.billing.run",
            "system.billing.invoice_status_updated",
        ):
            expect(required_action in action_names, f"Missing audit event for {required_action}")

        read_only_client = TestClient(service_app.app, base_url="https://testserver")
        portal_sign_in(
            read_only_client,
            email=read_only_email,
            password=read_only_password,
            phone_number=read_only_phone,
        )
        read_only_dashboard = read_only_client.get("/portal/dashboard")
        expect(read_only_dashboard.status_code == 200, read_only_dashboard.text)
        expect("Read Only" in read_only_dashboard.text, "Dashboard did not show the read-only actor role")

        read_only_billing = read_only_client.get("/portal/billing")
        expect(read_only_billing.status_code == 200, read_only_billing.text)
        expect("Billing Center" in read_only_billing.text, "Read-only role could not open the billing center")

        read_only_audit = read_only_client.get("/portal/audit")
        expect(read_only_audit.status_code == 200, read_only_audit.text)
        expect("Audit Log" in read_only_audit.text, "Read-only role could not open the audit log")

        read_only_create_company = read_only_client.post(
            "/portal/companies/create",
            data={"company_name": "Nope Co"},
        )
        expect(read_only_create_company.status_code == 403, read_only_create_company.text)
        expect("current role is Read Only" in read_only_create_company.text, "Read-only role was not blocked from company creation")

        pending_review = client.post(
            "/admin/msps/status",
            headers={"X-Admin-Key": admin_key},
            json={"msp_id": msp_id, "status": "pending_review"},
        )
        expect(pending_review.status_code == 200, pending_review.text)

        pending_dashboard = client.get("/portal/dashboard")
        expect(pending_dashboard.status_code == 200, pending_dashboard.text)
        expect("Pending Review" in pending_dashboard.text, "Dashboard did not surface pending-review MSP state")

        pending_access_code = client.post(
            "/portal/access-codes/create",
            data={"organization_id": org1_id, "label": "Blocked while pending"},
        )
        expect(pending_access_code.status_code == 423, pending_access_code.text)
        expect("pending review" in pending_access_code.text.lower(), "Pending-review MSP was not blocked from issuing access codes")

        pending_billing = client.post("/portal/billing/manage", follow_redirects=False)
        expect(pending_billing.status_code == 303, pending_billing.text)
        expect(
            str(pending_billing.headers.get("location") or "").startswith("https://billing.stripe.com/"),
            "Pending-review MSP should still be able to open Stripe billing",
        )

        pending_access_validate = client.post(
            "/access/validate",
            json={"code": code1, "phone_number": "+14155550140"},
        )
        expect(pending_access_validate.status_code == 409, pending_access_validate.text)
        expect("pending review" in pending_access_validate.text.lower(), "Pending-review MSP still allowed production access validation")

        reactivate_msp = client.post(
            "/admin/msps/status",
            headers={"X-Admin-Key": admin_key},
            json={"msp_id": msp_id, "status": "active"},
        )
        expect(reactivate_msp.status_code == 200, reactivate_msp.text)

        payment_failed = client.post(
            "/stripe/webhook",
            content=json.dumps(
                {
                    "type": "invoice.payment_failed",
                    "data": {
                        "object": {
                            "id": "in_test_0001",
                            "hosted_invoice_url": "https://billing.stripe.com/invoice/in_test_0001",
                            "metadata": {"msp_id": msp_id},
                        }
                    },
                }
            ),
            headers={"stripe-signature": "test"},
        )
        expect(payment_failed.status_code == 200, payment_failed.text)

        suspended_dashboard = client.get("/portal/dashboard")
        expect(suspended_dashboard.status_code == 200, suspended_dashboard.text)
        expect("Suspended" in suspended_dashboard.text, "Payment failure did not suspend the MSP")
        suspended_token = client.post(
            "/calls/twilio-token",
            json={
                "identity": alpha_primary_identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        )
        expect(suspended_token.status_code == 403, suspended_token.text)

        suspended_company = client.post(
            "/portal/companies/create",
            data={"company_name": "Blocked Co"},
        )
        expect(suspended_company.status_code == 423, suspended_company.text)
        expect("suspended" in suspended_company.text.lower(), "Suspended MSP was not blocked from provisioning companies")

        suspended_portal_session = client.post(
            "/portal/customer-portal-session",
            json={"return_url": "https://example.com/portal"},
        )
        expect(suspended_portal_session.status_code == 200, suspended_portal_session.text)
        expect(
            str(suspended_portal_session.json().get("url") or "").startswith("https://billing.stripe.com/"),
            "Suspended MSP should still be able to reach the Stripe billing portal",
        )

        logout = client.post("/portal/logout", follow_redirects=False)
        expect(logout.status_code == 303, logout.text)
        expect(logout.headers.get("location") == "/portal/login", "Logout did not redirect to login")
        logout_audit_events = service_app.control_plane.list_msp_audit_events(msp_id, limit=250)
        expect(
            any(event["action"] == "portal.logout" for event in logout_audit_events),
            "Portal logout did not write an audit event",
        )

        print("PASS: MSP auth, RBAC, lifecycle states, grouped companies, seat changes, and billing flows all work")
    finally:
        if original_admin_key is None:
            os.environ.pop("VICALL_ADMIN_API_KEY", None)
        else:
            os.environ["VICALL_ADMIN_API_KEY"] = original_admin_key
        if original_staging_enabled is None:
            os.environ.pop("VICALL_STAGING_SMOKE_ENABLED", None)
        else:
            os.environ["VICALL_STAGING_SMOKE_ENABLED"] = original_staging_enabled
        if original_staging_secret is None:
            os.environ.pop("VICALL_STAGING_SMOKE_SECRET", None)
        else:
            os.environ["VICALL_STAGING_SMOKE_SECRET"] = original_staging_secret
        if original_main_api_base_url is None:
            os.environ.pop("MAIN_API_BASE_URL", None)
        else:
            os.environ["MAIN_API_BASE_URL"] = original_main_api_base_url
        service_app.control_plane = original_control_plane
        service_app.forward_main_api_request = original_forward
        service_app.fetch_staging_main_api_otp = original_fetch_staging_main_api_otp
        service_app.create_customer = original_create_customer
        service_app.fetch_customer = original_fetch_customer
        service_app.create_billing_portal_session = original_create_billing_portal_session
        service_app.create_immediate_seat_invoice = original_create_immediate_seat_invoice
        service_app.create_monthly_invoice = original_create_monthly_invoice
        service_app.stripe_enabled = original_stripe_enabled
        service_app.verify_webhook_signature = original_verify_webhook_signature
        for name, value in original_twilio_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


if __name__ == "__main__":
    main()
