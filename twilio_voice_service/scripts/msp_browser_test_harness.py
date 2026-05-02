#!/usr/bin/env python3
from __future__ import annotations

import itertools
import os
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from fastapi import HTTPException, Response
from fastapi.responses import HTMLResponse


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

STATE_DIR = Path(
    os.getenv("VICALL_BROWSER_TEST_STATE_DIR")
    or tempfile.mkdtemp(prefix="vicall-msp-browser-e2e-")
)
DEFAULT_BASE_URL = os.getenv("PUBLIC_BASE_URL") or "http://127.0.0.1:8091"

os.environ["VICALL_CONTROL_DB_PATH"] = os.getenv(
    "VICALL_CONTROL_DB_PATH",
    str(STATE_DIR / "control.db"),
)
os.environ["DEVICE_BINDINGS_PATH"] = os.getenv(
    "DEVICE_BINDINGS_PATH",
    str(STATE_DIR / "device_bindings.json"),
)
os.environ["VICALL_ADMIN_API_KEY"] = os.getenv("VICALL_ADMIN_API_KEY", "test-admin-key")
os.environ["PUBLIC_BASE_URL"] = DEFAULT_BASE_URL
os.environ["ACCOUNT_DELETION_FLOW_MODE"] = os.getenv("ACCOUNT_DELETION_FLOW_MODE", "web")
os.environ["STRIPE_SECRET_KEY"] = os.getenv("STRIPE_SECRET_KEY", "sk_test_browser_local")
os.environ["STRIPE_WEBHOOK_SECRET"] = os.getenv("STRIPE_WEBHOOK_SECRET", "whsec_browser_local")
os.environ["VICALL_PORTAL_AUTH_PUBLIC_KEY"] = os.getenv(
    "VICALL_PORTAL_AUTH_PUBLIC_KEY",
    "browser-test-portal-public-key",
)
os.environ["VICALL_STAGING_SMOKE_ENABLED"] = os.getenv("VICALL_STAGING_SMOKE_ENABLED", "true")
os.environ["VICALL_STAGING_SMOKE_SECRET"] = os.getenv(
    "VICALL_STAGING_SMOKE_SECRET",
    "staging-ops-secret",
)
os.environ["MAIN_API_BASE_URL"] = os.getenv(
    "MAIN_API_BASE_URL",
    "https://staging-api.local.example",
)

import app as service_app  # noqa: E402


TEST_OTP = os.getenv("VICALL_BROWSER_TEST_OTP", "111111")
STAGING_OPS_SECRET = os.getenv("VICALL_STAGING_SMOKE_SECRET", "staging-ops-secret")
CUSTOMER_IDS = itertools.count(1)
INVOICE_IDS = itertools.count(1)
INVOICE_ITEM_IDS = itertools.count(1)
ISSUED_OTPS: dict[str, str] = {}


def _normalize_phone(phone_number: Any) -> str:
    normalized = service_app.normalize_phone_number(str(phone_number or ""))
    if not normalized:
        raise HTTPException(status_code=400, detail="phone_number is required")
    return normalized


async def fake_forward_main_api_request(
    path: str,
    *,
    method: str = "POST",
    payload: dict[str, object] | None = None,
    access_token: str | None = None,
) -> dict[str, object]:
    normalized_payload = dict(payload or {})
    if path == "/auth/request-otp":
        phone_number = _normalize_phone(normalized_payload.get("phone_number"))
        ISSUED_OTPS[phone_number] = TEST_OTP
        return {
            "status": "sent",
            "message": "OTP issued for browser harness",
            "phone_number": phone_number,
            "test_otp": TEST_OTP,
        }

    if path in {"/auth/verify-otp", "/auth/check-otp"}:
        phone_number = _normalize_phone(normalized_payload.get("phone_number"))
        otp = str(normalized_payload.get("otp") or "").strip()
        expected_otp = ISSUED_OTPS.get(phone_number, TEST_OTP)
        if otp != expected_otp:
            raise HTTPException(status_code=401, detail="Invalid one-time code")
        if path == "/auth/check-otp":
            return {
                "ok": True,
                "phone_number": phone_number,
            }
        return {
            "status": "verified",
            "user_id": f"user_{phone_number[-4:]}",
            "access_token": f"demo-access-{phone_number[-4:]}",
        }

    if path == "/contacts/sync":
        if not access_token:
            raise HTTPException(status_code=401, detail="Missing bearer token")
        return {"status": "ok", "contacts_synced": 0}

    raise HTTPException(status_code=404, detail=f"Browser harness does not implement {path}")


async def fake_forward_main_api_json(path: str, payload: dict[str, object]) -> dict[str, object]:
    return await fake_forward_main_api_request(path, payload=payload)


async def fake_fetch_staging_main_api_otp(*, phone_number: str, ops_secret: str) -> dict[str, str]:
    if ops_secret != STAGING_OPS_SECRET:
        raise HTTPException(status_code=401, detail="Invalid staging ops secret")
    normalized_phone = _normalize_phone(phone_number)
    return {
        "status": "ready",
        "phone_number": normalized_phone,
        "otp": ISSUED_OTPS.get(normalized_phone, TEST_OTP),
    }


def fake_stripe_enabled() -> bool:
    return True


async def fake_create_customer(
    *,
    name: str,
    email: str | None,
    metadata: dict[str, str] | None = None,
) -> dict[str, Any]:
    customer_id = f"cus_test_{next(CUSTOMER_IDS):04d}"
    return {
        "id": customer_id,
        "name": name,
        "email": email,
        "metadata": dict(metadata or {}),
    }


async def fake_fetch_customer(customer_id: str) -> dict[str, Any]:
    return {
        "id": customer_id,
        "invoice_settings": {"default_payment_method": "pm_test_default"},
        "default_source": None,
    }


async def fake_create_billing_portal_session(*, customer_id: str, return_url: str) -> dict[str, Any]:
    query = urlencode({"customer": customer_id, "return_url": return_url})
    return {"url": f"{DEFAULT_BASE_URL}/__test/stripe/billing-portal?{query}"}


async def fake_create_monthly_invoice(
    *,
    customer_id: str,
    msp_id: str,
    period_start: str,
    lines: list[dict[str, Any]],
    idempotency_suffix: str | None = None,
) -> dict[str, Any]:
    invoice_id = f"in_test_{next(INVOICE_IDS):04d}"
    invoice_url = f"{DEFAULT_BASE_URL}/__test/stripe/invoices/{invoice_id}"
    line_item_ids_by_org: dict[str, str] = {}
    for line in lines:
        line_item_ids_by_org[str(line["organization_id"])] = f"ii_test_{next(INVOICE_ITEM_IDS):04d}"
    return {
        "invoice": {
            "id": invoice_id,
            "customer": customer_id,
            "status": "open",
            "hosted_invoice_url": invoice_url,
            "metadata": {
                "msp_id": msp_id,
                "period_start": period_start,
            },
        },
        "line_item_ids_by_org": line_item_ids_by_org,
    }


async def fake_create_immediate_seat_invoice(
    *,
    customer_id: str,
    msp_id: str,
    period_start: str,
    membership: dict[str, Any],
    organization_name: str,
    amount_cents: int,
) -> dict[str, Any]:
    invoice_id = f"in_seat_test_{next(INVOICE_IDS):04d}"
    invoice_url = f"{DEFAULT_BASE_URL}/__test/stripe/invoices/{invoice_id}"
    return {
        "invoice": {
            "id": invoice_id,
            "customer": customer_id,
            "status": "open",
            "hosted_invoice_url": invoice_url,
            "metadata": {
                "msp_id": msp_id,
                "period_start": period_start,
                "membership_id": str(membership["membership_id"]),
            },
        },
        "invoice_item": {
            "id": f"ii_seat_test_{next(INVOICE_ITEM_IDS):04d}",
            "customer": customer_id,
            "amount": amount_cents,
            "description": f"Vicall seat activation for {organization_name}",
        },
    }


service_app.forward_main_api_request = fake_forward_main_api_request
service_app.forward_main_api_json = fake_forward_main_api_json
service_app.fetch_staging_main_api_otp = fake_fetch_staging_main_api_otp
service_app.stripe_enabled = fake_stripe_enabled
service_app.create_customer = fake_create_customer
service_app.fetch_customer = fake_fetch_customer
service_app.create_billing_portal_session = fake_create_billing_portal_session
service_app.create_immediate_seat_invoice = fake_create_immediate_seat_invoice
service_app.create_monthly_invoice = fake_create_monthly_invoice


def apply_insecure_portal_session_cookie(response: Response, session_token: str) -> None:
    response.set_cookie(
        key=service_app.PORTAL_SESSION_COOKIE,
        value=session_token,
        httponly=True,
        secure=False,
        samesite="lax",
        max_age=60 * 60 * 24 * 30,
        path="/",
    )


def apply_insecure_portal_login_challenge_cookie(response: Response, challenge_token: str) -> None:
    response.set_cookie(
        key=service_app.PORTAL_LOGIN_CHALLENGE_COOKIE,
        value=challenge_token,
        httponly=True,
        secure=False,
        samesite="lax",
        max_age=60 * service_app.PORTAL_LOGIN_CHALLENGE_TTL_MINUTES,
        path="/",
    )


service_app.apply_portal_session_cookie = apply_insecure_portal_session_cookie
service_app.apply_portal_login_challenge_cookie = apply_insecure_portal_login_challenge_cookie


@service_app.app.get("/__test/stripe/billing-portal", response_class=HTMLResponse)
async def browser_test_billing_portal(customer: str, return_url: str) -> str:
    return service_app.html_shell(
        "Stripe Test Billing Portal",
        f"""
          <section class="panel" style="max-width:760px; margin:40px auto 0;">
            <h1>Stripe Test Billing Portal</h1>
            <p class="sub">Browser harness billing portal for <strong>{service_app.escape(customer)}</strong>.</p>
            <p class="sub"><a href="{service_app.escape(return_url)}">Return to Vicall MSP Portal</a></p>
          </section>
        """,
    )


@service_app.app.get("/__test/stripe/invoices/{invoice_id}", response_class=HTMLResponse)
async def browser_test_invoice(invoice_id: str) -> str:
    return service_app.html_shell(
        "Stripe Test Invoice",
        f"""
          <section class="panel" style="max-width:760px; margin:40px auto 0;">
            <h1>Stripe Test Invoice</h1>
            <p class="sub">Invoice <code>{service_app.escape(invoice_id)}</code> was generated by the local browser harness.</p>
          </section>
        """,
    )


@service_app.app.get("/__test/otp/{phone_number}")
async def browser_test_otp(phone_number: str) -> dict[str, str]:
    normalized_phone = _normalize_phone(phone_number)
    return {
        "phone_number": normalized_phone,
        "otp": ISSUED_OTPS.get(normalized_phone, TEST_OTP),
    }




app = service_app.app


def main() -> None:
    import uvicorn

    host = os.getenv("HOST", "127.0.0.1")
    port = int(os.getenv("PORT", "8091"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
