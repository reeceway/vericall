from __future__ import annotations

import asyncio
from typing import Any

import stripe_billing


async def main() -> None:
    calls: list[dict[str, Any]] = []
    invoice_statuses: dict[str, dict[str, Any]] = {}

    async def fake_stripe_request(
        method: str,
        path: str,
        *,
        form: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        calls.append(
            {
                "method": method,
                "path": path,
                "form": form or {},
                "idempotency_key": idempotency_key,
            }
        )
        if path == "/v1/invoiceitems":
            assert (form or {}).get("invoice"), form
            return {"id": f"ii_test_{len(calls)}"}
        if path == "/v1/invoices":
            invoice = {
                "id": f"in_test_{len(calls)}",
                "status": "draft",
                "collection_method": "charge_automatically",
            }
            invoice_statuses[invoice["id"]] = dict(invoice)
            return invoice
        if path.startswith("/v1/invoices/") and path.endswith("/finalize"):
            invoice_id = path.split("/")[3]
            invoice_statuses[invoice_id] = {
                "id": invoice_id,
                "status": "open",
                "collection_method": "charge_automatically",
                "hosted_invoice_url": f"https://billing.stripe.com/invoice/{invoice_id}",
            }
            return invoice_statuses[invoice_id]
        if path.startswith("/v1/invoices/") and path.endswith("/pay"):
            invoice_id = path.split("/")[3]
            invoice_statuses[invoice_id] = {
                "id": invoice_id,
                "status": "paid",
                "collection_method": "charge_automatically",
                "hosted_invoice_url": f"https://billing.stripe.com/invoice/{invoice_id}",
            }
            return invoice_statuses[invoice_id]
        if method == "GET" and path.startswith("/v1/invoices/"):
            invoice_id = path.split("/")[3]
            return invoice_statuses[invoice_id]
        raise AssertionError(f"Unexpected Stripe call: {method} {path}")

    original = stripe_billing.stripe_request
    stripe_billing.stripe_request = fake_stripe_request
    try:
        await stripe_billing.create_immediate_seat_invoice(
            customer_id="cus_test",
            msp_id="msp_test",
            period_start="2026-05-01T00:00:00Z",
            membership={
                "membership_id": "mem_test",
                "organization_id": "org_test",
                "phone_number": "+14125550199",
                "user_id": "user_test",
            },
            organization_name="Customer Co",
            amount_cents=2000,
        )
        await stripe_billing.create_monthly_invoice(
            customer_id="cus_test",
            msp_id="msp_test",
            period_start="2026-05-01T00:00:00Z",
            lines=[
                {
                    "organization_id": "org_test",
                    "organization_name": "Customer Co",
                    "description": "Customer Co monthly seats",
                    "active_seats": 1,
                    "billable_seats": 1,
                    "unbilled_seats": 1,
                    "amount_cents": 2000,
                    "unbilled_amount_cents": 2000,
                }
            ],
        )
    finally:
        stripe_billing.stripe_request = original

    invoice_creates = [call for call in calls if call["method"] == "POST" and call["path"] == "/v1/invoices"]
    assert len(invoice_creates) == 2, invoice_creates
    for call in invoice_creates:
        assert call["form"].get("pending_invoice_items_behavior") == "exclude", call

    invoice_items = [
        call for call in calls if call["method"] == "POST" and call["path"] == "/v1/invoiceitems"
    ]
    assert len(invoice_items) == 2, invoice_items
    for call in invoice_items:
        assert str(call["form"].get("invoice") or "").startswith("in_test_"), call

    invoice_pays = [
        call for call in calls if call["method"] == "POST" and call["path"].endswith("/pay")
    ]
    assert len(invoice_pays) == 2, invoice_pays

    async def fake_declined_stripe_request(
        method: str,
        path: str,
        *,
        form: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        if path == "/v1/invoiceitems":
            assert (form or {}).get("invoice"), form
            return {"id": "ii_declined"}
        if path == "/v1/invoices":
            invoice_statuses["in_declined"] = {
                "id": "in_declined",
                "status": "draft",
                "collection_method": "charge_automatically",
            }
            return invoice_statuses["in_declined"]
        if path == "/v1/invoices/in_declined/finalize":
            invoice_statuses["in_declined"] = {
                "id": "in_declined",
                "status": "open",
                "collection_method": "charge_automatically",
            }
            return invoice_statuses["in_declined"]
        if path == "/v1/invoices/in_declined/pay":
            raise stripe_billing.StripeBillingError("Your card was declined.")
        if method == "GET" and path == "/v1/invoices/in_declined":
            return invoice_statuses["in_declined"]
        raise AssertionError(f"Unexpected Stripe call: {method} {path}")

    stripe_billing.stripe_request = fake_declined_stripe_request
    try:
        declined = await stripe_billing.create_immediate_seat_invoice(
            customer_id="cus_test",
            msp_id="msp_test",
            period_start="2026-05-01T00:00:00Z",
            membership={
                "membership_id": "mem_declined",
                "organization_id": "org_test",
                "phone_number": "+14125550201",
                "user_id": "user_test",
            },
            organization_name="Customer Co",
            amount_cents=2000,
        )
    finally:
        stripe_billing.stripe_request = original

    assert declined["invoice"]["id"] == "in_declined", declined
    assert declined["invoice"]["status"] == "open", declined
    assert declined["invoice"]["vicall_payment_attempt_failed"] is True, declined


if __name__ == "__main__":
    asyncio.run(main())
