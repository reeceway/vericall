from __future__ import annotations

import asyncio
import logging
import os
import smtplib
from email.message import EmailMessage

import httpx


logger = logging.getLogger("vericall-email")


class EmailDeliveryError(RuntimeError):
    pass


def email_enabled() -> bool:
    from_email = sender_address()
    if os.getenv("RESEND_API_KEY"):
        return bool(from_email)
    if os.getenv("SMTP_HOST"):
        return bool(from_email)
    return False


def sender_address() -> str:
    return (
        os.getenv("MSP_PORTAL_FROM_EMAIL")
        or os.getenv("RESEND_FROM_EMAIL")
        or os.getenv("SMTP_FROM_EMAIL")
        or ""
    ).strip()


def sender_name() -> str:
    return (os.getenv("MSP_PORTAL_FROM_NAME") or "Vicall").strip()


async def send_email(*, to_email: str, subject: str, text_body: str, html_body: str | None = None) -> None:
    if os.getenv("RESEND_API_KEY"):
        await send_via_resend(
            to_email=to_email,
            subject=subject,
            text_body=text_body,
            html_body=html_body,
        )
        return
    if os.getenv("SMTP_HOST"):
        await asyncio.to_thread(
            send_via_smtp,
            to_email=to_email,
            subject=subject,
            text_body=text_body,
            html_body=html_body,
        )
        return
    raise EmailDeliveryError("Email delivery is not configured")


async def send_via_resend(*, to_email: str, subject: str, text_body: str, html_body: str | None = None) -> None:
    api_key = os.getenv("RESEND_API_KEY")
    from_email = sender_address()
    if not api_key or not from_email:
        raise EmailDeliveryError("Resend is not fully configured")

    payload = {
        "from": f"{sender_name()} <{from_email}>",
        "to": [to_email],
        "subject": subject,
        "text": text_body,
    }
    if html_body:
        payload["html"] = html_body

    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.post(
            "https://api.resend.com/emails",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
    if response.status_code >= 400:
        raise EmailDeliveryError(f"Resend error: {response.status_code} {response.text}")


def send_via_smtp(*, to_email: str, subject: str, text_body: str, html_body: str | None = None) -> None:
    host = os.getenv("SMTP_HOST")
    port = int(os.getenv("SMTP_PORT", "587"))
    username = os.getenv("SMTP_USERNAME")
    password = os.getenv("SMTP_PASSWORD")
    use_tls = os.getenv("SMTP_USE_TLS", "true").lower() in {"1", "true", "yes"}
    from_email = sender_address()
    if not host or not from_email:
        raise EmailDeliveryError("SMTP is not fully configured")

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = f"{sender_name()} <{from_email}>"
    message["To"] = to_email
    message.set_content(text_body)
    if html_body:
        message.add_alternative(html_body, subtype="html")

    with smtplib.SMTP(host, port, timeout=20) as server:
        if use_tls:
            server.starttls()
        if username and password:
            server.login(username, password)
        server.send_message(message)

    logger.info("Sent MSP portal email to %s", to_email)
