#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, Request, build_opener


PRODUCTION_BASE_URL = "https://vericall-twilio-voice.fly.dev"
APP_PUBLIC_KEY = base64.b64encode(b"vicall-production-smoke-public-key").decode("ascii")


class SmokeFailure(RuntimeError):
    pass


@dataclass
class HttpResponse:
    status: int
    body: str
    headers: dict[str, str]
    url: str

    def json(self) -> dict[str, Any]:
        try:
            payload = json.loads(self.body)
        except json.JSONDecodeError as exc:
            raise SmokeFailure(f"Expected JSON from {self.url}, got: {self.body[:300]}") from exc
        if not isinstance(payload, dict):
            raise SmokeFailure(f"Expected JSON object from {self.url}")
        return payload


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


def mask_phone(value: str | None) -> str:
    digits = "".join(ch for ch in str(value or "") if ch.isdigit())
    return f"***{digits[-4:]}" if len(digits) >= 4 else "***"


def mask_id(value: str | None, *, keep: int = 6) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if len(raw) <= keep * 2:
        return raw
    return f"{raw[:keep]}...{raw[-keep:]}"


def strip_private(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: strip_private(item) for key, item in value.items() if not str(key).startswith("_")}
    if isinstance(value, list):
        return [strip_private(item) for item in value]
    return value


def extract(pattern: str, html: str, label: str) -> str:
    match = re.search(pattern, html)
    if not match:
        raise SmokeFailure(f"Could not find {label} in HTML response")
    return match.group(1)


def normalize_base_url(value: str) -> str:
    return value.rstrip("/")


def request(
    opener: Any,
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    form: dict[str, str] | None = None,
    ok_statuses: set[int] | None = None,
) -> HttpResponse:
    request_headers = dict(headers or {})
    body: bytes | None = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    elif form is not None:
        body = urlencode(form).encode("utf-8")
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = Request(url, data=body, headers=request_headers, method=method)
    expected = ok_statuses or set(range(200, 300))
    try:
        with opener.open(req, timeout=35) as response:
            text = response.read().decode("utf-8", errors="replace")
            result = HttpResponse(
                status=int(response.status),
                body=text,
                headers={key.lower(): value for key, value in response.headers.items()},
                url=response.geturl(),
            )
    except HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        result = HttpResponse(
            status=int(exc.code),
            body=text,
            headers={key.lower(): value for key, value in exc.headers.items()},
            url=url,
        )
    if result.status not in expected:
        raise SmokeFailure(f"{method} {url} returned {result.status}: {result.body[:500]}")
    return result


def check(results: list[dict[str, Any]], name: str, fn) -> Any:
    started = time.perf_counter()
    try:
        value = fn()
    except Exception as exc:  # noqa: BLE001
        results.append(
            {
                "name": name,
                "ok": False,
                "elapsed_seconds": round(time.perf_counter() - started, 3),
                "error": str(exc),
            }
        )
        raise
    results.append(
        {
            "name": name,
            "ok": True,
            "elapsed_seconds": round(time.perf_counter() - started, 3),
        }
    )
    return value


def twilio_identity(phone_number: str) -> str:
    digits = "".join(ch for ch in phone_number if ch.isdigit())
    if len(digits) == 10:
        digits = f"1{digits}"
    return f"user_{digits}_prod1"


def generated_phone(run_id: str, prefix: str) -> str:
    digest = int(hashlib.sha256(f"{run_id}:{prefix}".encode("utf-8")).hexdigest()[:9], 16)
    return f"+1555{digest % 10_000_000:07d}"


def admin_key_from_fly(app_name: str) -> str:
    command = [
        "flyctl",
        "ssh",
        "console",
        "-a",
        app_name,
        "-C",
        "sh -lc 'printf %s \"$VICALL_ADMIN_API_KEY\"'",
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
        raise SmokeFailure("Could not read production admin key through Fly SSH")
    key = completed.stdout.strip()
    if not key:
        raise SmokeFailure("Production admin key is empty through Fly SSH")
    return key


def latest_otp_from_messages(*, since_ms: int) -> str | None:
    db_path = Path.home() / "Library" / "Messages" / "chat.db"
    if not db_path.exists():
        return None
    seconds_since_unix_epoch = since_ms // 1000
    seconds_since_messages_epoch = seconds_since_unix_epoch - 978307200
    since_ns = seconds_since_messages_epoch * 1_000_000_000
    sql = f"""
        SELECT text
        FROM message
        WHERE is_from_me = 0
          AND text IS NOT NULL
          AND date >= {since_ns}
        ORDER BY date DESC
        LIMIT 80;
    """
    try:
        output = subprocess.check_output(
            ["/usr/bin/sqlite3", "-readonly", str(db_path), sql],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception:
        return None
    for line in output.splitlines():
        if not re.search(r"(code|verify|verification|Vicall|VeriCall|Twilio)", line, flags=re.I):
            continue
        match = re.search(r"\b(\d{6})\b", line)
        if match:
            return match.group(1)
    return None


def resolve_otp(
    *,
    explicit_otp: str | None,
    source: str,
    since_ms: int,
    timeout_seconds: int,
    label: str,
) -> str:
    if explicit_otp:
        return explicit_otp.strip()
    if source == "messages":
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            otp = latest_otp_from_messages(since_ms=since_ms - 15_000)
            if otp:
                return otp
            time.sleep(2)
        raise SmokeFailure(f"Timed out waiting for {label} OTP in Messages")
    if source == "prompt":
        if not sys.stdin.isatty():
            raise SmokeFailure(f"{label} OTP required, but stdin is not interactive")
        return input(f"Enter {label} OTP: ").strip()
    raise SmokeFailure(f"{label} OTP required. Use --otp-source messages, --otp-source prompt, or provide the OTP flag.")


def public_preflight(opener: Any, base_url: str, results: list[dict[str, Any]]) -> None:
    def health() -> None:
        payload = request(opener, "GET", f"{base_url}/health").json()
        expect(payload.get("status") == "healthy", "Production health is not healthy")

    def privacy() -> None:
        response = request(opener, "GET", f"{base_url}/privacy")
        expect("Vicall Privacy Policy" in response.body, "Privacy page did not render")

    def portal_login() -> None:
        response = request(opener, "GET", f"{base_url}/portal/login")
        expect("Email + Password" in response.body, "Portal login missing email/password flow")
        expect("Sign In with Portal Key" not in response.body, "Portal key sign-in is exposed")

    def protected_pages() -> None:
        response = request(opener, "GET", f"{base_url}/portal/dashboard")
        expect("MSP portal recovery" in response.body or "Work Email" in response.body, "Unauthenticated dashboard did not land on login")

    check(results, "public.health", health)
    check(results, "public.privacy", privacy)
    check(results, "public.portal_login", portal_login)
    check(results, "security.unauthenticated_portal_redirect", protected_pages)


def negative_security_preflight(opener: Any, base_url: str, results: list[dict[str, Any]]) -> None:
    def invalid_access_code() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": f"NOPE-{uuid.uuid4().hex[:8]}", "phone_number": "+15550009999"},
            ok_statuses={403},
        )
        expect("Invalid access code" in response.body, "Invalid access code failed for the wrong reason")

    def inactive_device_binding() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/calls/device-binding",
            payload={"identity": f"user_1555{uuid.uuid4().hex[:7]}_prod1", "voip_token": "abcdef1234567890"},
            ok_statuses={403},
        )
        expect("inactive" in response.body.lower(), "Inactive device binding was not blocked")

    def inactive_twilio_token() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/calls/twilio-token",
            payload={
                "identity": f"user_1555{uuid.uuid4().hex[:7]}_prod1",
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
            ok_statuses={403},
        )
        expect("inactive" in response.body.lower(), "Inactive Twilio token was not blocked")

    def invalid_stripe_webhook() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/stripe/webhook",
            payload={"type": "invoice.paid", "data": {"object": {"id": "in_invalid"}}},
            headers={"stripe-signature": "invalid"},
            ok_statuses={400},
        )
        expect("Invalid Stripe webhook signature" in response.body, "Invalid Stripe webhook was not rejected")

    def admin_storage_protected() -> None:
        response = request(opener, "GET", f"{base_url}/admin/storage/health", ok_statuses={401, 403})
        expect("detail" in response.body, "Admin storage health is not protected")

    check(results, "security.invalid_access_code_rejected", invalid_access_code)
    check(results, "security.inactive_device_binding_rejected", inactive_device_binding)
    check(results, "security.inactive_twilio_token_rejected", inactive_twilio_token)
    check(results, "security.invalid_stripe_webhook_rejected", invalid_stripe_webhook)
    check(results, "security.admin_storage_requires_key", admin_storage_protected)


def admin_headers(admin_key: str) -> dict[str, str]:
    return {"X-Admin-Key": admin_key}


def production_admin_mutation(
    opener: Any,
    base_url: str,
    admin_key: str,
    results: list[dict[str, Any]],
    *,
    run_id: str,
    allow_billing_run: bool,
) -> dict[str, Any]:
    owner_phone = generated_phone(run_id, "owner")
    firm_phone = generated_phone(run_id, "firm")
    customer_phone = generated_phone(run_id, "customer")
    overflow_phone = generated_phone(run_id, "overflow")
    owner_email = f"owner+prod-smoke-{run_id}@example.com"
    billing_email = f"billing+prod-smoke-{run_id}@example.com"
    password = f"VicallSmoke{run_id}!"
    msp_id = ""
    org1_id = ""
    org2_id = ""
    code1 = ""
    code2 = ""
    stripe_customer_id = ""

    def storage_health() -> dict[str, Any]:
        payload = request(opener, "GET", f"{base_url}/admin/storage/health", headers=admin_headers(admin_key)).json()
        expect(payload.get("db"), "Storage health missing DB status")
        return payload

    def admin_overview() -> dict[str, Any]:
        payload = request(opener, "GET", f"{base_url}/admin/overview", headers=admin_headers(admin_key)).json()
        expect(int(payload.get("msp_count") or 0) >= 1, "Admin overview did not return MSP count")
        return payload

    check(results, "admin.storage_health", storage_health)
    check(results, "admin.overview", admin_overview)

    def provision_msp() -> dict[str, str]:
        nonlocal msp_id, org1_id, code1, stripe_customer_id
        response = request(
            opener,
            "POST",
            f"{base_url}/admin/provision-msp?{urlencode({'key': admin_key})}",
            form={
                "msp_name": f"Codex Production Smoke {run_id}",
                "billing_email": billing_email,
                "seat_price_cents": "2000",
                "owner_full_name": "Codex Production Smoke",
                "owner_email": owner_email,
                "owner_phone_number": owner_phone,
                "owner_password": password,
                "company_name": f"Codex Smoke Firm {run_id}",
                "external_ref": f"SMOKE-FIRM-{run_id}",
            },
        )
        msp_id = extract(r"MSP ID:</strong> <code>([^<]+)</code>", response.body, "MSP ID")
        org1_id = extract(r"Organization ID:</strong> <code>([^<]+)</code>", response.body, "firm organization ID")
        code1 = extract(r"Access Code:</strong> <code>([^<]+)</code>", response.body, "firm access code")
        stripe_customer_id = (
            extract(r"Stripe Customer:</strong> ([^<]+)</p>", response.body, "Stripe customer")
            .replace("<code>", "")
            .replace("</code>", "")
        )
        expect("Non-billable MSP firm" in response.body, "Provisioned firm was not marked non-billable")
        expect("Portal Key:" not in response.body, "Provisioning response exposed portal key")
        return {"msp_id": msp_id, "org1_id": org1_id, "stripe_customer_id": stripe_customer_id}

    check(results, "admin.provision_msp_with_firm_and_stripe_customer", provision_msp)

    def msp_summary() -> dict[str, Any]:
        payload = request(opener, "GET", f"{base_url}/admin/msps/{msp_id}", headers=admin_headers(admin_key)).json()
        expect(payload.get("msp", {}).get("id") == msp_id, "Admin MSP summary resolved wrong MSP")
        expect(payload.get("current_billing_snapshot", {}).get("total_billable_seats") == 0, "New firm should not be billable")
        return payload

    check(results, "admin.msp_summary_and_initial_billing_snapshot", msp_summary)

    def create_customer_org() -> dict[str, Any]:
        nonlocal org2_id, code2
        requested_code = f"SMOKE{run_id[-6:].upper()}"
        org = request(
            opener,
            "POST",
            f"{base_url}/admin/organizations",
            headers=admin_headers(admin_key),
            payload={"msp_id": msp_id, "name": f"Codex Smoke Customer {run_id}", "external_ref": f"SMOKE-CUST-{run_id}"},
        ).json()
        org2_id = str(org["id"])
        access_code = request(
            opener,
            "POST",
            f"{base_url}/admin/access-codes",
            headers=admin_headers(admin_key),
            payload={
                "organization_id": org2_id,
                "code": requested_code,
                "label": "Production smoke customer code",
                "max_activations": 1,
            },
        ).json()
        code2 = requested_code
        return {"org2_id": org2_id, "code_hint": code2[-4:]}

    check(results, "admin.create_customer_company_and_capped_access_code", create_customer_org)

    def firm_access_validate() -> None:
        payload = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": code1, "phone_number": firm_phone},
        ).json()
        expect(payload.get("organization_id") == org1_id, "Firm code resolved to wrong organization")
        expect(str(payload.get("grant_token") or "").startswith("vicg_"), "Firm code did not issue grant token")

    check(results, "app.access_validate_firm_code_non_billable", firm_access_validate)

    def customer_access_payment_gate() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": code2, "phone_number": customer_phone},
            ok_statuses={402},
        )
        expect("payment method" in response.body.lower(), "Customer access did not enforce Stripe payment method gate")

    check(results, "app.customer_access_requires_payment_method", customer_access_payment_gate)

    def admin_activate_customer_membership() -> dict[str, Any]:
        payload = request(
            opener,
            "POST",
            f"{base_url}/admin/memberships/activate",
            headers=admin_headers(admin_key),
            payload={
                "organization_id": org2_id,
                "phone_number": customer_phone,
                "user_id": f"prod-smoke-{run_id}",
            },
        ).json()
        expect(payload.get("membership", {}).get("organization_id") == org2_id, "Admin activation attached wrong org")
        return payload

    check(results, "admin.activate_customer_membership_for_usage_probe", admin_activate_customer_membership)

    def customer_code_capacity_gate() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": code2, "phone_number": overflow_phone},
            ok_statuses={409},
        )
        expect("seat" in response.body.lower(), "Capped access code did not enforce seat limit")

    check(results, "app.access_code_capacity_gate", customer_code_capacity_gate)

    def active_voice_paths() -> None:
        identity = twilio_identity(customer_phone)
        bind = request(
            opener,
            "POST",
            f"{base_url}/calls/device-binding",
            payload={
                "identity": identity,
                "voip_token": f"{uuid.uuid4().hex}{uuid.uuid4().hex}",
                "platform": "ios",
                "context": f"production-smoke-{run_id}",
            },
        ).json()
        expect(bind.get("status") == "ok", "Active device binding failed")
        token = request(
            opener,
            "POST",
            f"{base_url}/calls/twilio-token",
            payload={
                "identity": identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
        ).json()
        expect(str(token.get("token") or ""), "Twilio token was not returned")
        call_sid = f"CA{uuid.uuid4().hex[:30]}"
        twiml = request(
            opener,
            "POST",
            f"{base_url}/calls/twilio-voice",
            form={"From": identity, "To": identity, "CallSid": call_sid},
        )
        expect("<Client" in twiml.body, "Active Twilio voice webhook did not return Client TwiML")
        status = request(
            opener,
            "POST",
            f"{base_url}/calls/client-status?{urlencode({'from': identity, 'to': identity, 'session': f'call:{call_sid}'})}",
            form={
                "CallSid": f"CA{uuid.uuid4().hex[:30]}",
                "ParentCallSid": call_sid,
                "CallStatus": "completed",
                "CallbackEvent": "completed",
                "From": f"client:{identity}",
                "To": f"client:{identity}",
                "CallDuration": "181",
            },
        ).json()
        expect(status.get("status") == "ok", "Client status callback failed")

    check(results, "voice.device_token_twiml_and_minute_tracking_path", active_voice_paths)

    def billing_preview_and_exports() -> dict[str, Any]:
        preview = request(opener, "GET", f"{base_url}/admin/msps/{msp_id}/billing/preview", headers=admin_headers(admin_key)).json()
        expect(preview.get("total_billable_seats") == 1, "Billing preview did not include customer seat")
        expect(int(preview.get("total_billable_minutes") or 0) >= 4, "Billing preview did not include call minutes")
        expect(preview.get("total_amount_cents") == 2000, "Billing preview amount should be one $20 customer seat")
        for label, path in (
            ("companies", "companies.csv"),
            ("users", "users.csv"),
            ("usage", "usage.csv"),
        ):
            csv_response = request(
                opener,
                "GET",
                f"{base_url}/admin/msps/{msp_id}/export/{path}",
                headers=admin_headers(admin_key),
            )
            expect("text/csv" in str(csv_response.headers.get("content-type") or ""), f"{label} export did not return CSV")
        return preview

    billing_preview = check(results, "admin.billing_preview_and_exports_include_usage", billing_preview_and_exports)

    def billing_run_missing_payment_method() -> None:
        response = request(
            opener,
            "POST",
            f"{base_url}/admin/msps/{msp_id}/billing/run",
            headers=admin_headers(admin_key),
            ok_statuses={402},
        )
        expect("payment method" in response.body.lower(), "Billing run did not fail closed without payment method")
        restored = request(
            opener,
            "POST",
            f"{base_url}/admin/msps/status",
            headers=admin_headers(admin_key),
            payload={"msp_id": msp_id, "status": "active"},
        ).json()
        expect(restored.get("status") == "active", "MSP was not restored to active after missing-payment test")

    check(results, "billing.run_blocks_without_payment_method_and_restores_status", billing_run_missing_payment_method)

    if allow_billing_run:
        raise SmokeFailure(
            "Live billing run was requested, but this generated smoke MSP intentionally has no payment method. "
            "Run live billing only against a dedicated Stripe test/live customer with a default payment method."
        )

    def lifecycle_state_blocks_voice() -> None:
        identity = twilio_identity(customer_phone)
        suspended = request(
            opener,
            "POST",
            f"{base_url}/admin/msps/status",
            headers=admin_headers(admin_key),
            payload={"msp_id": msp_id, "status": "suspended"},
        ).json()
        expect(suspended.get("status") == "suspended", "MSP status did not become suspended")
        response = request(
            opener,
            "POST",
            f"{base_url}/calls/twilio-token",
            payload={
                "identity": identity,
                "push_environment": "production",
                "bundle_identifier": "com.vicall.app",
            },
            ok_statuses={403},
        )
        expect("inactive" in response.body.lower(), "Suspended MSP did not block voice token")
        restored = request(
            opener,
            "POST",
            f"{base_url}/admin/msps/status",
            headers=admin_headers(admin_key),
            payload={"msp_id": msp_id, "status": "active"},
        ).json()
        expect(restored.get("status") == "active", "MSP was not restored after suspended voice test")

    check(results, "lifecycle.suspended_msp_blocks_voice_and_restores", lifecycle_state_blocks_voice)

    def deactivate_customer_company() -> None:
        payload = request(
            opener,
            "POST",
            f"{base_url}/admin/organizations/deactivate",
            headers=admin_headers(admin_key),
            payload={"organization_id": org2_id},
        ).json()
        expect(not bool(payload.get("active")), "Customer organization did not deactivate")
        response = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": code2, "phone_number": customer_phone},
            ok_statuses={403},
        )
        expect("Invalid access code" in response.body, "Deactivated company access code did not fail closed")

    check(results, "admin.deactivate_company_and_access_fails_closed", deactivate_customer_company)

    return {
        "msp_id": msp_id,
        "firm_org_id": org1_id,
        "customer_org_id": org2_id,
        "_firm_access_code": code1,
        "stripe_customer_id_masked": mask_id(stripe_customer_id),
        "firm_phone": mask_phone(firm_phone),
        "customer_phone": mask_phone(customer_phone),
        "billing_preview": {
            "total_billable_seats": billing_preview.get("total_billable_seats"),
            "total_billable_minutes": billing_preview.get("total_billable_minutes"),
            "total_amount_cents": billing_preview.get("total_amount_cents"),
        },
    }


def real_app_firm_onboarding(
    opener: Any,
    base_url: str,
    results: list[dict[str, Any]],
    *,
    access_code: str,
    organization_id: str,
    phone_number: str,
    otp: str | None,
    otp_source: str,
    otp_timeout_seconds: int,
) -> dict[str, Any]:
    grant_token = ""

    def validate_code() -> dict[str, Any]:
        payload = request(
            opener,
            "POST",
            f"{base_url}/access/validate",
            payload={"code": access_code, "phone_number": phone_number},
        ).json()
        expect(payload.get("organization_id") == organization_id, "Real app phone resolved wrong firm organization")
        expect(str(payload.get("grant_token") or "").startswith("vicg_"), "Real app phone did not get grant token")
        return payload

    access_payload = check(results, "real_app.access_validate_with_real_phone", validate_code)
    grant_token = str(access_payload["grant_token"])

    otp_started_ms = int(time.time() * 1000)

    def request_otp() -> None:
        payload = request(
            opener,
            "POST",
            f"{base_url}/access/request-otp",
            payload={"phone_number": phone_number, "access_grant_token": grant_token},
        ).json()
        expect(payload.get("status") in {"sent", "ok", "success"} or payload, "Real app OTP request returned empty response")

    check(results, "real_app.request_sms_otp", request_otp)
    resolved_otp = resolve_otp(
        explicit_otp=otp,
        source=otp_source,
        since_ms=otp_started_ms,
        timeout_seconds=otp_timeout_seconds,
        label="real app onboarding",
    )

    def verify_otp() -> dict[str, Any]:
        payload = request(
            opener,
            "POST",
            f"{base_url}/access/verify-otp",
            payload={
                "phone_number": phone_number,
                "otp": resolved_otp,
                "public_key": APP_PUBLIC_KEY,
                "access_grant_token": grant_token,
            },
        ).json()
        expect(payload.get("organization_id") == organization_id, "Real app OTP attached wrong org")
        expect(payload.get("billing", {}).get("status") == "skipped_billing_exempt", "Real firm onboarding should stay non-billable")
        return payload

    verified = check(results, "real_app.verify_sms_otp_and_activate_non_billable_firm_seat", verify_otp)
    return {
        "organization_id": organization_id,
        "phone": mask_phone(phone_number),
        "membership_id": verified.get("membership_id"),
        "billing_status": verified.get("billing", {}).get("status"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extensive production smoke for Vicall MSP portal/app/billing/logging surfaces."
    )
    parser.add_argument("--base-url", default=os.getenv("VICALL_PRODUCTION_BASE_URL") or PRODUCTION_BASE_URL)
    parser.add_argument("--fly-app", default=os.getenv("VICALL_PRODUCTION_FLY_APP") or "vericall-twilio-voice")
    parser.add_argument("--admin-key", default=os.getenv("VICALL_ADMIN_API_KEY"))
    parser.add_argument("--admin-key-from-fly", action="store_true")
    parser.add_argument("--allow-production-mutations", action="store_true")
    parser.add_argument("--allow-live-billing-run", action="store_true")
    parser.add_argument("--run-id", default=os.getenv("VICALL_PRODUCTION_SMOKE_RUN_ID"))
    parser.add_argument("--real-app-phone", default=os.getenv("VICALL_PRODUCTION_SMOKE_APP_PHONE"))
    parser.add_argument("--real-app-otp", default=os.getenv("VICALL_PRODUCTION_SMOKE_APP_OTP"))
    parser.add_argument(
        "--otp-source",
        choices=["none", "messages", "prompt"],
        default=os.getenv("VICALL_PRODUCTION_SMOKE_OTP_SOURCE") or "none",
    )
    parser.add_argument("--otp-timeout-seconds", type=int, default=90)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    base_url = normalize_base_url(args.base_url)
    run_id = re.sub(r"[^A-Za-z0-9]", "", args.run_id or "")[-10:] or f"{int(time.time()) % 1_000_000:06d}{uuid.uuid4().hex[:4]}"
    opener = build_opener(HTTPCookieProcessor(CookieJar()))
    results: list[dict[str, Any]] = []
    started = time.perf_counter()
    mutation_summary: dict[str, Any] | None = None
    real_app_summary: dict[str, Any] | None = None

    try:
        public_preflight(opener, base_url, results)
        negative_security_preflight(opener, base_url, results)

        admin_key = args.admin_key
        if args.admin_key_from_fly:
            admin_key = admin_key_from_fly(args.fly_app)

        if args.allow_production_mutations:
            expect(bool(admin_key), "Production mutations require --admin-key, VICALL_ADMIN_API_KEY, or --admin-key-from-fly")
            mutation_summary = production_admin_mutation(
                opener,
                base_url,
                str(admin_key),
                results,
                run_id=run_id,
                allow_billing_run=args.allow_live_billing_run,
            )
            if args.real_app_phone:
                real_app_summary = real_app_firm_onboarding(
                    opener,
                    base_url,
                    results,
                    access_code=str(mutation_summary.get("_firm_access_code") or ""),
                    organization_id=mutation_summary["firm_org_id"],
                    phone_number=args.real_app_phone,
                    otp=args.real_app_otp,
                    otp_source=args.otp_source,
                    otp_timeout_seconds=args.otp_timeout_seconds,
                )
        elif args.real_app_phone:
            raise SmokeFailure("--real-app-phone requires --allow-production-mutations so the script has an isolated firm access code")
    except Exception as exc:  # noqa: BLE001
        summary = {
            "ok": False,
            "base_url": base_url,
            "run_id": run_id,
            "elapsed_seconds": round(time.perf_counter() - started, 3),
            "error": str(exc),
            "results": results,
            "mutation_summary": strip_private(mutation_summary),
            "real_app_summary": real_app_summary,
        }
        if args.out:
            Path(args.out).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1

    summary = {
        "ok": True,
        "base_url": base_url,
        "run_id": run_id,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
        "production_mutations": bool(args.allow_production_mutations),
        "live_billing_run": bool(args.allow_live_billing_run),
        "real_app_sms_onboarding": bool(real_app_summary),
        "checks_passed": len(results),
        "results": results,
        "mutation_summary": strip_private(mutation_summary),
        "real_app_summary": real_app_summary,
        "caveat": (
            "This runner tests the live production backend and Stripe/Twilio service configuration. "
            "A real iPhone call still needs a device smoke to prove APNs/CallKit/audio behavior."
        ),
    }
    if args.out:
        Path(args.out).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
