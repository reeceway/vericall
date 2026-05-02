from __future__ import annotations

import hashlib
import hmac
import os
import time
from typing import Any

import httpx


class StripeBillingError(RuntimeError):
    pass


def stripe_enabled() -> bool:
    return bool(os.getenv("STRIPE_SECRET_KEY"))


def require_stripe_secret_key() -> str:
    value = os.getenv("STRIPE_SECRET_KEY")
    if not value:
        raise StripeBillingError("Stripe is not configured")
    return value


async def stripe_request(
    method: str,
    path: str,
    *,
    form: dict[str, Any] | None = None,
    idempotency_key: str | None = None,
) -> dict[str, Any]:
    secret_key = require_stripe_secret_key()
    headers = {
        "Authorization": f"Bearer {secret_key}",
    }
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key

    async with httpx.AsyncClient(base_url="https://api.stripe.com", timeout=20.0) as client:
        response = await client.request(method, path, data=form or {}, headers=headers)

    if response.status_code >= 400:
        try:
            payload = response.json()
        except ValueError:
            payload = {"error": {"message": response.text}}
        message = payload.get("error", {}).get("message") or "Stripe request failed"
        raise StripeBillingError(message)

    return response.json()


async def create_customer(
    *,
    name: str,
    email: str | None,
    metadata: dict[str, str] | None = None,
) -> dict[str, Any]:
    form: dict[str, Any] = {"name": name}
    if email:
        form["email"] = email
    for key, value in (metadata or {}).items():
        form[f"metadata[{key}]"] = value
    return await stripe_request("POST", "/v1/customers", form=form)


async def fetch_customer(customer_id: str) -> dict[str, Any]:
    return await stripe_request("GET", f"/v1/customers/{customer_id}")


async def create_billing_portal_session(*, customer_id: str, return_url: str) -> dict[str, Any]:
    return await stripe_request(
        "POST",
        "/v1/billing_portal/sessions",
        form={
            "customer": customer_id,
            "return_url": return_url,
        },
    )


async def finalize_and_pay_invoice(
    invoice: dict[str, Any],
    *,
    finalize_idempotency_key: str,
    pay_idempotency_key: str,
) -> dict[str, Any]:
    if invoice.get("status") == "draft":
        invoice = await stripe_request(
            "POST",
            f"/v1/invoices/{invoice['id']}/finalize",
            form={"auto_advance": "true"},
            idempotency_key=finalize_idempotency_key,
        )
    if (
        invoice.get("status") == "open"
        and invoice.get("collection_method") == "charge_automatically"
    ):
        try:
            invoice = await stripe_request(
                "POST",
                f"/v1/invoices/{invoice['id']}/pay",
                idempotency_key=pay_idempotency_key,
            )
        except StripeBillingError as exc:
            invoice = await stripe_request("GET", f"/v1/invoices/{invoice['id']}")
            invoice["vicall_payment_error"] = str(exc)
            invoice["vicall_payment_attempt_failed"] = True
    return invoice


async def create_monthly_invoice(
    *,
    customer_id: str,
    msp_id: str,
    period_start: str,
    lines: list[dict[str, Any]],
    idempotency_suffix: str | None = None,
) -> dict[str, Any]:
    line_item_ids_by_org: dict[str, str] = {}
    key_suffix = f"-{idempotency_suffix}" if idempotency_suffix else ""

    invoice = await stripe_request(
        "POST",
        "/v1/invoices",
        form={
            "customer": customer_id,
            "collection_method": "charge_automatically",
            "auto_advance": "true",
            "pending_invoice_items_behavior": "exclude",
            "description": f"Vicall monthly seats for {period_start}",
            "metadata[msp_id]": msp_id,
            "metadata[period_start]": period_start,
        },
        idempotency_key=f"vicall-invoice-{msp_id}-{period_start}{key_suffix}",
    )

    for index, line in enumerate(lines):
        raw = line.get("invoice_amount_cents")
        if raw is None:
            raw = line.get("unbilled_amount_cents")
        if raw is None:
            raw = line["amount_cents"]
        invoice_amount_cents = int(raw)
        invoice_item = await stripe_request(
            "POST",
            "/v1/invoiceitems",
            form={
                "invoice": invoice["id"],
                "customer": customer_id,
                "currency": "usd",
                "amount": str(invoice_amount_cents),
                "description": str(line.get("invoice_description") or line["description"]),
                "metadata[msp_id]": msp_id,
                "metadata[organization_id]": line["organization_id"],
                "metadata[organization_name]": line["organization_name"],
                "metadata[period_start]": period_start,
                "metadata[period_end]": str(line.get("period_end") or ""),
                "metadata[active_seats]": str(int(line["active_seats"])),
                "metadata[billable_seats]": str(int(line.get("billable_seats", line["active_seats"]))),
                "metadata[unbilled_seats]": str(int(line.get("unbilled_seats", line.get("billable_seats", 0)))),
                "metadata[call_count]": str(int(line.get("call_count", 0))),
                "metadata[billable_seconds]": str(int(line.get("billable_seconds", 0))),
                "metadata[billable_minutes]": str(int(line.get("billable_minutes", 0))),
                "metadata[included_minutes]": str(int(line.get("included_minutes", 0))),
                "metadata[overage_minutes]": str(int(line.get("overage_minutes", 0))),
                "metadata[unbilled_overage_minutes]": str(int(line.get("unbilled_overage_minutes", line.get("overage_minutes", 0)))),
                "metadata[overage_amount_decicents]": str(int(line.get("overage_amount_decicents", 0))),
                "metadata[unbilled_overage_amount_decicents]": str(int(line.get("unbilled_overage_amount_decicents", line.get("overage_amount_decicents", 0)))),
                "metadata[overage_amount_cents]": str(int(line.get("overage_amount_cents", 0))),
                "metadata[unbilled_overage_amount_cents]": str(int(line.get("unbilled_overage_amount_cents", line.get("overage_amount_cents", 0)))),
                "metadata[overage_rate_decicents_per_minute]": str(int(line.get("overage_rate_decicents_per_minute", 1))),
                "metadata[included_minutes_per_seat]": str(int(line.get("included_minutes_per_seat", 450))),
            },
            idempotency_key=f"vicall-invoice-item-{msp_id}-{period_start}{key_suffix}-{index}",
        )
        line_item_ids_by_org[line["organization_id"]] = invoice_item["id"]

    invoice = await finalize_and_pay_invoice(
        invoice,
        finalize_idempotency_key=f"vicall-invoice-finalize-{msp_id}-{period_start}{key_suffix}",
        pay_idempotency_key=f"vicall-invoice-pay-{msp_id}-{period_start}{key_suffix}",
    )
    return {
        "invoice": invoice,
        "line_item_ids_by_org": line_item_ids_by_org,
    }


async def create_immediate_seat_invoice(
    *,
    customer_id: str,
    msp_id: str,
    period_start: str,
    membership: dict[str, Any],
    organization_name: str,
    amount_cents: int,
) -> dict[str, Any]:
    membership_id = str(membership["membership_id"])
    organization_id = str(membership["organization_id"])
    phone_number = str(membership["phone_number"])
    invoice = await stripe_request(
        "POST",
        "/v1/invoices",
        form={
            "customer": customer_id,
            "collection_method": "charge_automatically",
            "auto_advance": "true",
            "pending_invoice_items_behavior": "exclude",
            "description": f"Vicall seat activation for {organization_name}",
            "metadata[msp_id]": msp_id,
            "metadata[organization_id]": organization_id,
            "metadata[membership_id]": membership_id,
            "metadata[phone_number]": phone_number,
            "metadata[period_start]": period_start,
            "metadata[billing_reason]": "seat_activation",
        },
        idempotency_key=f"vicall-seat-invoice-{msp_id}-{membership_id}-{period_start}",
    )
    invoice_item = await stripe_request(
        "POST",
        "/v1/invoiceitems",
        form={
            "invoice": invoice["id"],
            "customer": customer_id,
            "currency": "usd",
            "amount": str(int(amount_cents)),
            "description": f"Vicall seat activation — {organization_name} — {phone_number}",
            "metadata[msp_id]": msp_id,
            "metadata[organization_id]": organization_id,
            "metadata[organization_name]": organization_name,
            "metadata[membership_id]": membership_id,
            "metadata[phone_number]": phone_number,
            "metadata[user_id]": str(membership.get("user_id") or ""),
            "metadata[period_start]": period_start,
            "metadata[billing_reason]": "seat_activation",
        },
        idempotency_key=f"vicall-seat-invoice-item-{msp_id}-{membership_id}-{period_start}",
    )
    invoice = await finalize_and_pay_invoice(
        invoice,
        finalize_idempotency_key=f"vicall-seat-invoice-finalize-{msp_id}-{membership_id}-{period_start}",
        pay_idempotency_key=f"vicall-seat-invoice-pay-{msp_id}-{membership_id}-{period_start}",
    )
    return {
        "invoice": invoice,
        "invoice_item": invoice_item,
    }


def verify_webhook_signature(*, payload: bytes, signature_header: str | None) -> bool:
    secret = os.getenv("STRIPE_WEBHOOK_SECRET")
    if not secret or not signature_header:
        return False

    components: dict[str, str] = {}
    for part in signature_header.split(","):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        components[key] = value

    timestamp = components.get("t")
    signature = components.get("v1")
    if not timestamp or not signature:
        return False

    try:
        age = abs(time.time() - int(timestamp))
    except ValueError:
        return False
    if age > 300:
        return False

    try:
        signed_payload = f"{timestamp}.".encode("utf-8") + payload
    except Exception:
        return False
    expected = hmac.new(
        secret.encode("utf-8"),
        signed_payload,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, signature)
