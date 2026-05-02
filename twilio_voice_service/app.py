from __future__ import annotations

import logging
import os
import re
import sqlite3
import tempfile
import time
import asyncio
from base64 import b64decode, b64encode
from csv import DictWriter
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from io import StringIO
from secrets import compare_digest, token_urlsafe
import json
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode
from xml.sax.saxutils import escape

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response
from pydantic import BaseModel

try:
    from backup_utils import read_latest_backup_manifest, resolve_backup_dir
    from control_plane import (
        AmbiguousVoiceMembershipError,
        ControlPlaneStore,
        AccessGrantContext,
        MSP_ROLE_BILLING_ADMIN,
        MSP_ROLE_OPERATOR,
        MSP_ROLE_OWNER,
        MSP_ROLE_READ_ONLY,
        MSP_STATUS_ACTIVE,
        MSP_STATUS_PENDING_REVIEW,
        MSP_STATUS_SUSPENDED,
        isoformat,
        month_start,
        normalize_msp_role,
        normalize_msp_status,
        normalize_code,
        normalize_phone_number,
        normalize_seat_limit,
        normalize_twilio_identity,
        parse_iso,
        TWILIO_IDENTITY_SUFFIXES,
        utcnow,
    )
    from email_service import EmailDeliveryError, email_enabled, send_email
    from stripe_billing import (
        StripeBillingError,
        create_billing_portal_session,
        create_customer,
        create_immediate_seat_invoice,
        create_monthly_invoice,
        fetch_customer,
        stripe_enabled,
        verify_webhook_signature,
    )
except ModuleNotFoundError:
    from .backup_utils import read_latest_backup_manifest, resolve_backup_dir
    from .control_plane import (
        AmbiguousVoiceMembershipError,
        ControlPlaneStore,
        AccessGrantContext,
        MSP_ROLE_BILLING_ADMIN,
        MSP_ROLE_OPERATOR,
        MSP_ROLE_OWNER,
        MSP_ROLE_READ_ONLY,
        MSP_STATUS_ACTIVE,
        MSP_STATUS_PENDING_REVIEW,
        MSP_STATUS_SUSPENDED,
        isoformat,
        month_start,
        normalize_msp_role,
        normalize_msp_status,
        normalize_code,
        normalize_phone_number,
        normalize_seat_limit,
        normalize_twilio_identity,
        parse_iso,
        TWILIO_IDENTITY_SUFFIXES,
        utcnow,
    )
    from .email_service import EmailDeliveryError, email_enabled, send_email
    from .stripe_billing import (
        StripeBillingError,
        create_billing_portal_session,
        create_customer,
        create_immediate_seat_invoice,
        create_monthly_invoice,
        fetch_customer,
        stripe_enabled,
        verify_webhook_signature,
    )

load_dotenv(dotenv_path=Path(__file__).with_name(".env"))

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("vericall-twilio-voice")
pending_invites_by_room: dict[str, str] = {}
media_audio_sessions: dict[str, dict[str, Any]] = {}
media_audio_auth_cache: dict[str, float] = {}
media_audio_lock = asyncio.Lock()
bindings_path = Path(os.getenv("DEVICE_BINDINGS_PATH", "/tmp/vericall_device_bindings.json"))
access_attempts_by_key: dict[str, list[float]] = {}
control_plane_db_path = Path(os.getenv("VICALL_CONTROL_DB_PATH", "/data/vericall_control.db"))
control_plane = ControlPlaneStore(control_plane_db_path)
PORTAL_SESSION_COOKIE = "vicall_msp_portal"
PORTAL_LOGIN_CHALLENGE_COOKIE = "vicall_msp_login_challenge"
PORTAL_PAGE_SIZE = 50
DEFAULT_MSP_SEAT_PRICE_CENTS = int(os.getenv("DEFAULT_MSP_SEAT_PRICE_CENTS", "2000"))
PORTAL_LOGIN_CHALLENGE_TTL_MINUTES = max(int(os.getenv("VICALL_MSP_LOGIN_CHALLENGE_TTL_MINUTES", "15")), 5)
PORTAL_LOGIN_MAX_ATTEMPTS = max(int(os.getenv("VICALL_MSP_LOGIN_MAX_ATTEMPTS", "5")), 3)
PORTAL_LOGIN_SMS_RESEND_COOLDOWN_SECONDS = max(
    int(os.getenv("VICALL_MSP_LOGIN_RESEND_COOLDOWN_SECONDS", "30")),
    0,
)
PORTAL_LOGIN_LOCKOUT_MESSAGE = (
    "Too many sign-in attempts. Start again with your email and password or contact Vicall for help."
)
PORTAL_ALL_ROLE_SET = {
    MSP_ROLE_OWNER,
    MSP_ROLE_BILLING_ADMIN,
    MSP_ROLE_OPERATOR,
    MSP_ROLE_READ_ONLY,
}
PORTAL_BILLING_ROLE_SET = {
    MSP_ROLE_OWNER,
    MSP_ROLE_BILLING_ADMIN,
}
PORTAL_REPORTING_ROLE_SET = {
    MSP_ROLE_OWNER,
    MSP_ROLE_BILLING_ADMIN,
    MSP_ROLE_READ_ONLY,
}
PORTAL_OPERATOR_ROLE_SET = {
    MSP_ROLE_OWNER,
    MSP_ROLE_OPERATOR,
}
PORTAL_OWNER_ROLE_SET = {MSP_ROLE_OWNER}
PORTAL_VIEW_STATUS_SET = {
    MSP_STATUS_PENDING_REVIEW,
    MSP_STATUS_ACTIVE,
    MSP_STATUS_SUSPENDED,
}
PORTAL_SETUP_STATUS_SET = {
    MSP_STATUS_PENDING_REVIEW,
    MSP_STATUS_ACTIVE,
}
PORTAL_PRODUCTION_STATUS_SET = {MSP_STATUS_ACTIVE}
PORTAL_BILLING_STATUS_SET = {
    MSP_STATUS_PENDING_REVIEW,
    MSP_STATUS_ACTIVE,
    MSP_STATUS_SUSPENDED,
}
TRUTHY_ENV_VALUES = {"1", "true", "yes", "on"}


def truthy_env(name: str, default: str = "false") -> bool:
    return os.getenv(name, default).strip().lower() in TRUTHY_ENV_VALUES


def generate_ephemeral_public_key() -> str:
    private_key = ec.generate_private_key(ec.SECP256R1())
    public_key = private_key.public_key()
    public_key_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint,
    )
    return b64encode(public_key_bytes).decode("ascii")


PORTAL_AUTH_PUBLIC_KEY = os.getenv("VICALL_PORTAL_AUTH_PUBLIC_KEY") or generate_ephemeral_public_key()


def load_device_bindings() -> dict[str, dict[str, str]]:
    try:
        if bindings_path.exists():
            data = json.loads(bindings_path.read_text())
            if isinstance(data, dict):
                return data
    except Exception:
        logger.exception("[DeviceBinding] Failed to load bindings from %s", bindings_path)
    return {}


def save_device_bindings(bindings: dict[str, dict[str, str]]) -> None:
    try:
        bindings_path.parent.mkdir(parents=True, exist_ok=True)
        bindings_path.write_text(json.dumps(bindings))
    except Exception:
        logger.exception("[DeviceBinding] Failed to save bindings to %s", bindings_path)


device_bindings: dict[str, dict[str, str]] = load_device_bindings()

app = FastAPI(
    title="VeriCall Twilio Voice Service",
    description="Slim Twilio token + TwiML service for mobile client-to-client voice",
    version="1.0.0",
)
auto_billing_task: asyncio.Task | None = None
auto_billing_last_period: str | None = None


class TwilioTokenRequest(BaseModel):
    identity: str
    push_environment: str = "development"
    bundle_identifier: str | None = None
    membership_id: str | None = None
    organization_id: str | None = None
    msp_id: str | None = None


class DeviceEventRequest(BaseModel):
    event: str
    identity: str | None = None
    details: dict[str, str] = {}


class ClientInviteRequest(BaseModel):
    to: str
    from_identity: str
    room: str
    from_membership_id: str | None = None
    from_organization_id: str | None = None
    from_msp_id: str | None = None
    to_membership_id: str | None = None
    to_organization_id: str | None = None
    to_msp_id: str | None = None
    membership_id: str | None = None
    organization_id: str | None = None
    msp_id: str | None = None


class DeviceBindingRequest(BaseModel):
    identity: str
    voip_token: str
    platform: str = "ios"
    context: str = "unknown"
    membership_id: str | None = None
    organization_id: str | None = None
    msp_id: str | None = None


class AccessCodeValidationRequest(BaseModel):
    code: str
    phone_number: str | None = None


class AccessGrantOTPRequest(BaseModel):
    phone_number: str
    access_grant_token: str


class AccessGrantVerifyRequest(BaseModel):
    phone_number: str
    otp: str
    public_key: str | None = None
    access_grant_token: str


class CreateMSPRequest(BaseModel):
    name: str
    billing_email: str | None = None
    seat_price_cents: int = 2000
    status: str = MSP_STATUS_ACTIVE
    owner_email: str | None = None
    owner_phone_number: str | None = None
    owner_full_name: str | None = None
    owner_password: str | None = None


class CreateOrganizationRequest(BaseModel):
    msp_id: str
    name: str
    external_ref: str | None = None


class CreateAccessCodeRequest(BaseModel):
    organization_id: str
    code: str
    label: str | None = None
    max_activations: int | None = None


class CreatePortalSessionRequest(BaseModel):
    return_url: str


class AccountDeletionRequest(BaseModel):
    phone_number: str
    user_id: str | None = None
    identity: str | None = None


class AccountDeletionExecutionRequest(BaseModel):
    deletion_token: str


class ActivateMembershipRequest(BaseModel):
    organization_id: str
    phone_number: str
    user_id: str | None = None
    access_code_id: str | None = None


class DeactivateOrganizationRequest(BaseModel):
    organization_id: str


class UpdateMSPStatusRequest(BaseModel):
    msp_id: str
    status: str


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def twilio_push_credential_sid(push_environment: str, bundle_identifier: str | None = None) -> str:
    normalized = (push_environment or "development").strip().lower()
    bundle_id = (bundle_identifier or "").strip()
    if normalized in {"production", "prod", "appstore", "app_store"}:
        return require_env("TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION")
    if normalized in {"development", "dev", "sandbox", "debug"}:
        if bundle_id == "com.vicall.app":
            return require_env("TWILIO_PUSH_CREDENTIAL_SID_DEVELOPMENT_VICALL")
        return os.getenv("TWILIO_PUSH_CREDENTIAL_SID_DEVELOPMENT") or require_env("TWILIO_PUSH_CREDENTIAL_SID")
    raise RuntimeError(f"Unsupported push environment: {push_environment}")


def custom_apns_fallback_enabled() -> bool:
    return os.getenv("ENABLE_CUSTOM_APNS_FALLBACK", "false").lower() in {"1", "true", "yes"}


def normalize_access_code(code: str | None) -> str:
    return normalize_code(code)


def configured_access_code_hashes() -> set[str]:
    raw_hashes = os.getenv("VICALL_ACCESS_CODE_HASHES", "")
    hashes = {
        part.strip().lower()
        for part in raw_hashes.replace("\n", ",").split(",")
        if part.strip()
    }

    raw_codes = os.getenv("VICALL_ACCESS_CODES", "")
    for code in raw_codes.replace("\n", ",").split(","):
        normalized = normalize_access_code(code)
        if normalized:
            hashes.add(sha256(normalized.encode("utf-8")).hexdigest())
    return hashes


def check_access_rate_limit(key: str) -> None:
    max_attempts = int(os.getenv("ACCESS_CODE_RATE_LIMIT_MAX", "20"))
    window_seconds = int(os.getenv("ACCESS_CODE_RATE_LIMIT_WINDOW_SECONDS", "300"))
    now = time.time()
    attempts = [ts for ts in access_attempts_by_key.get(key, []) if now - ts < window_seconds]
    attempts.append(now)
    access_attempts_by_key[key] = attempts
    if len(attempts) > max_attempts:
        raise HTTPException(status_code=429, detail="Too many access-code attempts")


def require_admin_key(admin_key: str | None) -> None:
    configured = os.getenv("VICALL_ADMIN_API_KEY")
    if not configured:
        raise HTTPException(status_code=503, detail="Admin API key is not configured")
    if not admin_key or not compare_digest(admin_key, configured):
        raise HTTPException(status_code=401, detail="Invalid admin API key")


def env_truthy(name: str) -> bool:
    return (os.getenv(name) or "").strip().lower() in TRUTHY_ENV_VALUES


def staging_smoke_secret() -> str | None:
    return (os.getenv("VICALL_STAGING_SMOKE_SECRET") or "").strip() or None


def staging_smoke_main_api_otp_path() -> str:
    path = (os.getenv("VICALL_STAGING_SMOKE_OTP_PATH") or "/auth/staging/otp/latest").strip()
    if not path.startswith("/"):
        path = f"/{path}"
    return path


def staging_smoke_ops_enabled() -> bool:
    if not env_truthy("VICALL_STAGING_SMOKE_ENABLED"):
        return False
    if any(
        (os.getenv(name) or "").strip().lower() == "production"
        for name in ("APP_ENV", "ENV", "ENVIRONMENT", "VICALL_ENVIRONMENT")
    ):
        return False
    if (
        main_api_base_url() == "https://vericall-api.fly.dev"
        and not env_truthy("VICALL_STAGING_SMOKE_ALLOW_PRODUCTION_MAIN_API")
    ):
        return False
    return bool(staging_smoke_secret())


def require_staging_smoke_ops_secret(ops_secret: str | None) -> str:
    if not staging_smoke_ops_enabled():
        raise HTTPException(status_code=404, detail="Not found")
    configured = staging_smoke_secret()
    if not configured:
        raise HTTPException(status_code=503, detail="Staging smoke secret is not configured")
    if not ops_secret or not compare_digest(ops_secret, configured):
        raise HTTPException(status_code=401, detail="Invalid staging ops secret")
    return configured


def require_portal_key(portal_key: str | None):
    if not portal_key:
        raise HTTPException(status_code=401, detail="Missing MSP portal key")
    msp = control_plane.get_msp_by_portal_key(portal_key)
    if msp is None:
        raise HTTPException(status_code=401, detail="Invalid MSP portal key")
    return msp


def portal_session_from_request(request: Request) -> str | None:
    return request.cookies.get(PORTAL_SESSION_COOKIE)


def portal_login_challenge_from_request(request: Request) -> str | None:
    return request.cookies.get(PORTAL_LOGIN_CHALLENGE_COOKIE)


def require_portal_request(
    request: Request,
    *,
    portal_key: str | None = None,
    header_portal_key: str | None = None,
):
    session_token = portal_session_from_request(request)
    if not session_token:
        raise HTTPException(status_code=401, detail="Sign in to the MSP portal to continue")
    session = control_plane.get_msp_session(session_token)
    if session is None:
        raise HTTPException(status_code=401, detail="Your MSP portal session expired")
    return session.as_msp_row(), session


def apply_portal_session_cookie(response: Response, session_token: str) -> None:
    response.set_cookie(
        key=PORTAL_SESSION_COOKIE,
        value=session_token,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=60 * 60 * 24 * 30,
        path="/",
    )


def apply_portal_login_challenge_cookie(response: Response, challenge_token: str) -> None:
    response.set_cookie(
        key=PORTAL_LOGIN_CHALLENGE_COOKIE,
        value=challenge_token,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=60 * PORTAL_LOGIN_CHALLENGE_TTL_MINUTES,
        path="/",
    )


def clear_portal_login_challenge_cookie(response: Response) -> None:
    response.delete_cookie(PORTAL_LOGIN_CHALLENGE_COOKIE, path="/")


def portal_request_metadata(request: Request) -> tuple[str | None, str | None]:
    client_ip = request.client.host if request.client else None
    user_agent = (request.headers.get("user-agent") or "").strip() or None
    return client_ip, user_agent


def portal_login_challenge_value(challenge: Any, field: str) -> Any:
    if challenge is None:
        return None
    if isinstance(challenge, dict):
        return challenge.get(field)
    try:
        return challenge[field]
    except Exception:
        return None


def portal_login_attempt_count(challenge: Any) -> int:
    return int(portal_login_challenge_value(challenge, "attempt_count") or 0)


def portal_login_challenge_is_locked(challenge: Any) -> bool:
    return portal_login_attempt_count(challenge) >= PORTAL_LOGIN_MAX_ATTEMPTS


def portal_login_sms_cooldown_remaining(challenge: Any) -> int:
    if PORTAL_LOGIN_SMS_RESEND_COOLDOWN_SECONDS <= 0:
        return 0
    last_sent_at = parse_iso(portal_login_challenge_value(challenge, "last_otp_sent_at"))
    if last_sent_at is None:
        return 0
    elapsed = (utcnow() - last_sent_at).total_seconds()
    remaining = PORTAL_LOGIN_SMS_RESEND_COOLDOWN_SECONDS - int(elapsed)
    return max(remaining, 0)


def portal_restart_login_response(
    *,
    message: str,
    email: str | None = None,
    status_code: int = 429,
) -> HTMLResponse:
    response = HTMLResponse(
        render_portal_login(
            error=message,
            login_email=email,
        ),
        status_code=status_code,
    )
    clear_portal_login_challenge_cookie(response)
    return response


def portal_role_label(role: str | None) -> str:
    normalized = normalize_msp_role(role)
    labels = {
        MSP_ROLE_OWNER: "Owner",
        MSP_ROLE_BILLING_ADMIN: "Billing Admin",
        MSP_ROLE_OPERATOR: "Operator",
        MSP_ROLE_READ_ONLY: "Read Only",
    }
    return labels.get(normalized, normalized.replace("_", " ").title())


def portal_status_label(status: str | None) -> str:
    normalized = normalize_msp_status(status)
    labels = {
        MSP_STATUS_PENDING_REVIEW: "Pending Review",
        MSP_STATUS_ACTIVE: "Active",
        MSP_STATUS_SUSPENDED: "Suspended",
    }
    return labels.get(normalized, normalized.replace("_", " ").title())


def portal_status_notice(status: str | None) -> str | None:
    normalized = normalize_msp_status(status)
    if normalized == MSP_STATUS_PENDING_REVIEW:
        return (
            "This MSP is still pending review. You can finish setup and billing, "
            "but live employee onboarding stays disabled until Vicall activates the account."
        )
    if normalized == MSP_STATUS_SUSPENDED:
        return (
            "This MSP is suspended. Billing and history remain visible, "
            "but provisioning and seat changes are disabled."
        )
    return None


def portal_allowed_role_labels(allowed_roles: set[str]) -> str:
    labels = [portal_role_label(role) for role in sorted(allowed_roles)]
    if not labels:
        return "authorized users"
    if len(labels) == 1:
        return labels[0]
    return ", ".join(labels[:-1]) + f", or {labels[-1]}"


def portal_access_restriction(
    *,
    actor_role: str,
    msp_status: str,
    action: str,
    allowed_roles: set[str] | None = None,
    allowed_statuses: set[str] | None = None,
) -> tuple[int, str] | None:
    if allowed_roles and actor_role not in allowed_roles:
        allowed_label = portal_allowed_role_labels(allowed_roles)
        return 403, f"{allowed_label} can {action}. Your current role is {portal_role_label(actor_role)}."
    if allowed_statuses and msp_status not in allowed_statuses:
        if msp_status == MSP_STATUS_PENDING_REVIEW:
            return 423, (
                "This MSP is pending review. Setup and billing are available, "
                f"but you cannot {action} until Vicall activates the account."
            )
        if msp_status == MSP_STATUS_SUSPENDED:
            return 423, (
                "This MSP is suspended. Billing and history remain available, "
                f"but you cannot {action} while the account is suspended."
            )
        return 423, f"This MSP cannot {action} in its current lifecycle state."
    return None


def portal_html_access_response(
    *,
    actor: dict[str, Any],
    msp: dict[str, Any],
    action: str,
    back_href: str,
    back_label: str,
    allowed_roles: set[str] | None = None,
    allowed_statuses: set[str] | None = None,
) -> HTMLResponse | None:
    restriction = portal_access_restriction(
        actor_role=normalize_msp_role(actor.get("role")),
        msp_status=normalize_msp_status(msp.get("status")),
        action=action,
        allowed_roles=allowed_roles,
        allowed_statuses=allowed_statuses,
    )
    if restriction is None:
        return None
    status_code, message = restriction
    return HTMLResponse(
        render_action_result(
            title="MSP Portal Access Restricted",
            body=f"<p>{escape(message)}</p>",
            back_href=back_href,
            back_label=back_label,
        ),
        status_code=status_code,
    )


def portal_api_access_check(
    *,
    actor: dict[str, Any],
    msp: dict[str, Any],
    action: str,
    allowed_roles: set[str] | None = None,
    allowed_statuses: set[str] | None = None,
) -> None:
    restriction = portal_access_restriction(
        actor_role=normalize_msp_role(actor.get("role")),
        msp_status=normalize_msp_status(msp.get("status")),
        action=action,
        allowed_roles=allowed_roles,
        allowed_statuses=allowed_statuses,
    )
    if restriction is None:
        return
    status_code, message = restriction
    raise HTTPException(status_code=status_code, detail=message)


def record_msp_audit_event(
    *,
    msp_id: str,
    action: str,
    actor: dict[str, Any] | None = None,
    request: Request | None = None,
    status: str = "success",
    target_type: str | None = None,
    target_id: str | None = None,
    organization_id: str | None = None,
    organization_name: str | None = None,
    details: dict[str, Any] | None = None,
    actor_type: str = "msp_user",
    actor_label: str | None = None,
) -> None:
    client_ip = None
    user_agent = None
    if request is not None:
        client_ip, user_agent = portal_request_metadata(request)
    actor_row = dict(actor or {})
    control_plane.record_msp_audit_event(
        msp_id=msp_id,
        actor_type=actor_type,
        actor_msp_user_id=(actor_row.get("msp_user_id") or actor_row.get("id")),
        actor_email=actor_row.get("email"),
        actor_role=actor_row.get("role"),
        actor_label=actor_label or actor_row.get("full_name") or actor_row.get("email"),
        action=action,
        target_type=target_type,
        target_id=target_id,
        organization_id=organization_id,
        organization_name=organization_name,
        status=status,
        event_metadata=details,
        ip_address=client_ip,
        user_agent=user_agent,
    )


def record_admin_audit_event(
    *,
    msp_id: str,
    action: str,
    request: Request | None = None,
    status: str = "success",
    target_type: str | None = None,
    target_id: str | None = None,
    organization_id: str | None = None,
    organization_name: str | None = None,
    details: dict[str, Any] | None = None,
) -> None:
    record_msp_audit_event(
        msp_id=msp_id,
        action=action,
        actor=None,
        request=request,
        status=status,
        target_type=target_type,
        target_id=target_id,
        organization_id=organization_id,
        organization_name=organization_name,
        details=details,
        actor_type="vicall_admin",
        actor_label="Vicall admin",
    )


def record_system_audit_event(
    *,
    msp_id: str,
    action: str,
    status: str = "success",
    target_type: str | None = None,
    target_id: str | None = None,
    organization_id: str | None = None,
    organization_name: str | None = None,
    details: dict[str, Any] | None = None,
) -> None:
    record_msp_audit_event(
        msp_id=msp_id,
        action=action,
        actor=None,
        request=None,
        status=status,
        target_type=target_type,
        target_id=target_id,
        organization_id=organization_id,
        organization_name=organization_name,
        details=details,
        actor_type="system",
        actor_label="Vicall system",
    )


def portal_summary_for_dashboard(
    *,
    msp_id: str,
    company_query: str = "",
    company_status: str = "all",
    page: int = 1,
) -> dict[str, object]:
    safe_page = max(page, 1)
    offset = (safe_page - 1) * PORTAL_PAGE_SIZE
    base_summary = control_plane.msp_summary(msp_id)
    organization_page = control_plane.organization_page_for_msp(
        msp_id,
        query=company_query,
        status=company_status,
        limit=PORTAL_PAGE_SIZE,
        offset=offset,
    )
    active_company_count = control_plane.organization_page_for_msp(
        msp_id,
        status="active",
        limit=1,
        offset=0,
    )["total_count"]
    base_summary["organizations"] = organization_page["rows"]
    base_summary["organization_total_count"] = organization_page["total_count"]
    base_summary["organization_page_size"] = organization_page["limit"]
    base_summary["active_organization_count"] = active_company_count
    base_summary["team_users"] = control_plane.list_msp_users(msp_id)
    base_summary["billing_runs"] = control_plane.billing_runs_for_msp(msp_id)
    base_summary["has_active_msp_firm"] = control_plane.billing_exempt_organization_count(msp_id=msp_id) > 0
    base_summary["current_billing_snapshot"] = control_plane.billing_snapshot(
        msp_id=msp_id,
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    return base_summary


async def stripe_billing_readiness(stripe_customer_id: str | None) -> dict[str, object]:
    if not stripe_customer_id:
        return {
            "customer_id": None,
            "auto_charge_ready": False,
            "payment_method_label": "No Stripe customer linked",
        }
    if not stripe_enabled():
        return {
            "customer_id": stripe_customer_id,
            "auto_charge_ready": False,
            "payment_method_label": "Stripe is not configured",
        }
    try:
        customer = await fetch_customer(stripe_customer_id)
    except StripeBillingError as exc:
        return {
            "customer_id": stripe_customer_id,
            "auto_charge_ready": False,
            "payment_method_label": f"Stripe lookup failed: {exc}",
        }

    default_payment_method = customer.get("invoice_settings", {}).get("default_payment_method")
    default_source = customer.get("default_source")
    auto_charge_ready = bool(default_payment_method or default_source)
    payment_method_label = (
        "Payment method on file"
        if auto_charge_ready
        else "No default payment method on file"
    )
    return {
        "customer_id": stripe_customer_id,
        "auto_charge_ready": auto_charge_ready,
        "payment_method_label": payment_method_label,
    }


async def msp_auto_charge_ready(msp: dict[str, Any]) -> dict[str, object]:
    return await stripe_billing_readiness(str(msp.get("stripe_customer_id") or "").strip() or None)


def render_payment_required_result(
    *,
    msp: dict[str, Any],
    billing_readiness: dict[str, object],
    back_href: str = "/portal/dashboard",
    back_label: str = "Back to MSP Portal",
) -> str:
    manage_href = "/portal/billing/manage"
    return render_action_result(
        title="Payment Method Required",
        body=f"""
          <p><strong>{escape(str(msp.get('name') or 'This MSP'))}</strong> needs a default Stripe payment method before creating customer companies, issuing customer access codes, or activating billable seats.</p>
          <p><strong>Current billing status:</strong> {escape(str(billing_readiness.get('payment_method_label') or 'Not checked'))}</p>
          <p>Your MSP firm stays available and non-billable. Customer companies turn on after payment setup.</p>
          <form method="post" action="{manage_href}">
            <button type="submit">Open Stripe Billing Portal</button>
          </form>
        """,
        back_href=back_href,
        back_label=back_label,
    )


async def portal_payment_required_response(
    *,
    msp: dict[str, Any],
    back_href: str = "/portal/dashboard",
    back_label: str = "Back to MSP Portal",
) -> str | None:
    billing_readiness = await msp_auto_charge_ready(msp)
    if bool(billing_readiness.get("auto_charge_ready")):
        return None
    return render_payment_required_result(
        msp=msp,
        billing_readiness=billing_readiness,
        back_href=back_href,
        back_label=back_label,
    )


async def require_customer_billing_ready_for_access(context: AccessGrantContext) -> None:
    if context.organization_billing_exempt:
        return
    billing_readiness = await stripe_billing_readiness(context.stripe_customer_id)
    if not bool(billing_readiness.get("auto_charge_ready")):
        raise HTTPException(
            status_code=402,
            detail=(
                "This MSP must add a default payment method before employees can be activated "
                "for customer companies."
            ),
        )


async def invoice_membership_activation(
    *,
    membership: dict[str, Any],
    organization_name: str,
) -> dict[str, object]:
    period_start = isoformat(month_start(datetime.now(timezone.utc)))
    if bool(membership.get("organization_billing_exempt")):
        record_system_audit_event(
            msp_id=str(membership["msp_id"]),
            action="system.billing.seat_invoice",
            status="skipped_billing_exempt",
            target_type="membership",
            target_id=str(membership["membership_id"]),
            organization_id=str(membership["organization_id"]),
            organization_name=organization_name,
            details={
                "period_start": period_start,
                "phone_number": membership.get("phone_number"),
                "billing_note": "MSP firm seats are non-billable.",
            },
        )
        return {"status": "skipped_billing_exempt", "period_start": period_start}
    existing_event = control_plane.seat_billing_event_for_membership(
        membership_id=str(membership["membership_id"]),
        period_start=period_start,
    )
    if existing_event and existing_event.get("stripe_invoice_id"):
        return {
            "status": "already_invoiced",
            "invoice_id": existing_event.get("stripe_invoice_id"),
            "invoice_status": existing_event.get("status"),
            "hosted_invoice_url": existing_event.get("hosted_invoice_url"),
            "period_start": period_start,
        }

    msp = control_plane.get_msp(str(membership["msp_id"]))
    if msp is None:
        return {"status": "skipped_missing_msp", "period_start": period_start}
    stripe_customer_id = str(msp["stripe_customer_id"] or "").strip()
    if not stripe_customer_id:
        record_system_audit_event(
            msp_id=str(membership["msp_id"]),
            action="system.billing.seat_invoice",
            status="skipped_missing_customer",
            target_type="membership",
            target_id=str(membership["membership_id"]),
            organization_id=str(membership["organization_id"]),
            organization_name=organization_name,
            details={"period_start": period_start},
        )
        return {"status": "skipped_missing_customer", "period_start": period_start}
    if not stripe_enabled():
        record_system_audit_event(
            msp_id=str(membership["msp_id"]),
            action="system.billing.seat_invoice",
            status="skipped_stripe_not_configured",
            target_type="membership",
            target_id=str(membership["membership_id"]),
            organization_id=str(membership["organization_id"]),
            organization_name=organization_name,
            details={"period_start": period_start},
        )
        return {"status": "skipped_stripe_not_configured", "period_start": period_start}

    seat_price_cents = int(msp["seat_price_cents"])
    if seat_price_cents <= 0:
        return {"status": "skipped_zero_amount", "period_start": period_start}

    try:
        result = await create_immediate_seat_invoice(
            customer_id=stripe_customer_id,
            msp_id=str(membership["msp_id"]),
            period_start=period_start,
            membership=membership,
            organization_name=organization_name,
            amount_cents=seat_price_cents,
        )
        invoice = result["invoice"]
        invoice_item = result.get("invoice_item") or {}
        event = control_plane.record_seat_billing_event(
            membership=membership,
            period_start=period_start,
            seat_price_cents=seat_price_cents,
            amount_cents=seat_price_cents,
            stripe_invoice_id=str(invoice.get("id") or ""),
            stripe_invoice_item_id=str(invoice_item.get("id") or ""),
            hosted_invoice_url=invoice.get("hosted_invoice_url"),
            status=str(invoice.get("status") or "open"),
        )
    except StripeBillingError as exc:
        record_system_audit_event(
            msp_id=str(membership["msp_id"]),
            action="system.billing.seat_invoice",
            status="failed",
            target_type="membership",
            target_id=str(membership["membership_id"]),
            organization_id=str(membership["organization_id"]),
            organization_name=organization_name,
            details={"period_start": period_start, "error": str(exc)},
        )
        return {"status": "failed", "error": str(exc), "period_start": period_start}

    record_system_audit_event(
        msp_id=str(membership["msp_id"]),
        action="system.billing.seat_invoice",
        status=str(event.get("status") or "open"),
        target_type="stripe_invoice",
        target_id=str(event.get("stripe_invoice_id") or ""),
        organization_id=str(membership["organization_id"]),
        organization_name=organization_name,
        details={
            "period_start": period_start,
            "membership_id": membership["membership_id"],
            "phone_number": membership["phone_number"],
            "amount_cents": seat_price_cents,
            "hosted_invoice_url": event.get("hosted_invoice_url"),
        },
    )
    return {
        "status": "invoiced",
        "invoice_id": event.get("stripe_invoice_id"),
        "invoice_status": event.get("status"),
        "hosted_invoice_url": event.get("hosted_invoice_url"),
        "period_start": period_start,
        "amount_cents": seat_price_cents,
    }


def main_api_base_url() -> str:
    return os.getenv("MAIN_API_BASE_URL", "https://vericall-api.fly.dev").rstrip("/")


def require_bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="Invalid Authorization header")
    return token.strip()


async def forward_main_api_request(
    path: str,
    *,
    method: str = "POST",
    payload: dict[str, object] | None = None,
    access_token: str | None = None,
) -> dict[str, object]:
    endpoint = f"{main_api_base_url()}{path}"
    headers: dict[str, str] = {}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.request(method, endpoint, json=payload, headers=headers)
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="The authentication service timed out. Request a new code and try again.",
        ) from exc
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=502,
            detail="The authentication service is temporarily unavailable. Try again in a moment.",
        ) from exc
    if response.status_code >= 400:
        detail = response.text
        try:
            body = response.json()
            detail = body.get("detail") or body.get("message") or detail
        except Exception:
            pass
        raise HTTPException(status_code=response.status_code, detail=detail)
    if not response.content:
        return {}
    return response.json()


async def forward_main_api_json(path: str, payload: dict[str, object]) -> dict[str, object]:
    return await forward_main_api_request(path, payload=payload)


async def fetch_staging_main_api_otp(*, phone_number: str, ops_secret: str) -> dict[str, object]:
    endpoint = f"{main_api_base_url()}{staging_smoke_main_api_otp_path()}"
    headers = {"X-Vicall-Staging-Ops-Secret": ops_secret}
    params = {"phone_number": phone_number}
    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.get(endpoint, params=params, headers=headers)
    if response.status_code >= 400:
        detail = response.text
        try:
            body = response.json()
            detail = body.get("detail") or body.get("message") or detail
        except Exception:
            pass
        raise HTTPException(status_code=response.status_code, detail=detail)
    if not response.content:
        return {}
    return response.json()


def build_verify_otp_payload(
    *,
    phone_number: str,
    otp: str,
    public_key: str,
) -> dict[str, object]:
    normalized_public_key = public_key.strip()
    if not normalized_public_key:
        raise ValueError("public_key is required")
    payload: dict[str, object] = {
        "phone_number": phone_number,
        "otp": otp,
        "public_key": normalized_public_key,
    }
    return payload


def csv_response(filename: str, rows: list[dict[str, object]], fieldnames: list[str]) -> Response:
    buffer = StringIO()
    writer = DictWriter(buffer, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow({field: row.get(field, "") for field in fieldnames})
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def html_shell(title: str, body: str) -> str:
    return f"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(title)}</title>
  <style>
    :root {{
      --bg: #050806;
      --panel: rgba(14,22,17,0.72);
      --panel-solid: #0a100c;
      --ink: #f2fff6;
      --muted: #93a39a;
      --line: rgba(125,233,151,0.18);
      --accent: #30d158;
      --accent-strong: #8ff0a6;
      --accent-soft: rgba(48,209,88,0.13);
      --danger: #ff5f57;
      --warning: #ffcf5a;
      --field: rgba(6,12,8,0.78);
      --glass: rgba(15,24,18,0.56);
      --shadow: 0 24px 70px rgba(0,0,0,0.42), inset 0 1px 0 rgba(255,255,255,0.04);
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif; background: var(--bg); color: var(--ink); }}
    main {{ max-width: 1180px; margin: 0 auto; padding: 36px 22px 56px; }}
    h1, h2 {{ line-height: 1.15; margin: 0; }}
    h1 {{ font-size: 2rem; letter-spacing: 0; }}
    h2 {{ font-size: 1.15rem; margin-bottom: 12px; }}
    .sub {{ color: var(--muted); margin-top: 8px; }}
    a {{ color: var(--accent); }}
    .eyebrow {{ color: var(--accent-strong); font-size: 0.8rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0; margin-bottom: 10px; }}
    .portal-hero {{ display: flex; align-items: flex-end; justify-content: space-between; gap: 20px; flex-wrap: wrap; }}
    .top-actions {{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }}
    .top-actions a, .ghost-button {{ display: inline-flex; align-items: center; justify-content: center; min-height: 38px; padding: 0 13px; border: 1px solid rgba(255,255,255,0.1); border-radius: 8px; background: rgba(16,24,18,0.66); color: var(--ink); text-decoration: none; font-weight: 700; font-size: .9rem; box-shadow: 0 10px 30px rgba(0,0,0,0.24); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); }}
    .top-actions a.primary {{ background: var(--accent); color: #031006; border-color: var(--accent); box-shadow: 0 0 24px rgba(48,209,88,0.16); }}
    .grid {{ display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); margin-top: 24px; }}
    .summary-strip {{ display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin-top: 26px; }}
    .summary-card {{ background: var(--glass); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px; padding: 16px; box-shadow: var(--shadow); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); }}
    .summary-card.primary {{ border-color: rgba(48,209,88,0.42); background: rgba(22,48,29,0.68); box-shadow: 0 22px 60px rgba(0,0,0,0.36), 0 0 28px rgba(48,209,88,0.09); }}
    .card, .panel {{ background: var(--panel); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px; padding: 18px; box-shadow: var(--shadow); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); }}
    .metric {{ font-size: 1.8rem; font-weight: 700; margin-top: 8px; }}
    .label {{ color: var(--muted); font-size: 0.95rem; }}
    .panels {{ display: grid; gap: 16px; margin-top: 24px; }}
    .table-wrap {{ width: 100%; overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--line); font-size: 0.95rem; vertical-align: top; }}
    th {{ color: var(--muted); font-weight: 600; }}
    tfoot td {{ font-weight: 700; background: rgba(32,240,120,0.08); }}
    .pill {{ display: inline-block; color: var(--accent); font-size: 0.8rem; font-weight: 700; }}
    .status-pill {{ display: inline-flex; align-items: center; gap: 6px; padding: 0; font-size: 0.78rem; font-weight: 800; border: 0; background: transparent; }}
    .status-ok {{ color: var(--accent-strong); }}
    .status-warn {{ color: var(--warning); }}
    .status-off {{ color: #ffaaa5; }}
    .status-neutral {{ color: var(--muted); }}
    .company-grid {{ display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); margin-top: 18px; }}
    .company-card {{ background: rgba(12,22,16,0.62); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px; box-shadow: var(--shadow); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); overflow: hidden; }}
    .company-card summary {{ cursor: pointer; list-style: none; padding: 16px; }}
    .company-card summary::-webkit-details-marker {{ display: none; }}
    .company-card summary:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 3px; }}
    .company-card[open] {{ background: rgba(13,25,18,0.82); border-color: rgba(48,209,88,0.26); }}
    .company-card[open] summary {{ border-bottom: 1px solid var(--line); }}
    .company-card-header {{ display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }}
    .company-title {{ font-size: 1.05rem; font-weight: 800; margin: 0; }}
    .company-line {{ color: var(--muted); font-size: 0.86rem; margin-top: 5px; }}
    .company-meta {{ display: flex; flex-wrap: wrap; gap: 8px 14px; color: var(--muted); font-size: 0.84rem; margin-top: 8px; }}
    .company-snapshot {{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin-top: 14px; }}
    .snapshot-value {{ display: block; font-size: 1.25rem; font-weight: 800; }}
    .snapshot-label {{ color: var(--muted); font-size: .74rem; }}
    .expand-cue {{ color: var(--muted); font-size: .82rem; font-weight: 700; margin-top: 8px; }}
    .company-card[open] .expand-cue {{ color: var(--accent); }}
    .company-reveal {{ padding: 16px; }}
    .company-metrics {{ display: grid; gap: 10px; grid-template-columns: repeat(3, minmax(0, 1fr)); margin-top: 14px; }}
    .mini-metric {{ border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; padding: 10px; background: rgba(5,12,8,0.52); min-width: 0; }}
    .mini-metric .value {{ display: block; font-size: 1.15rem; font-weight: 800; margin-top: 3px; overflow-wrap: anywhere; }}
    .mini-metric .caption {{ color: var(--muted); font-size: 0.76rem; }}
    .company-ledger {{ display: flex; flex-wrap: wrap; gap: 10px 16px; margin-top: 12px; color: var(--muted); font-size: 0.86rem; }}
    .company-ledger strong {{ color: var(--ink); }}
    .usage-block {{ margin-top: 14px; }}
    .usage-row {{ display: flex; justify-content: space-between; gap: 12px; color: var(--muted); font-size: 0.84rem; }}
    .usage-track {{ width: 100%; height: 10px; border-radius: 999px; background: rgba(255,255,255,0.09); overflow: hidden; margin-top: 7px; }}
    .usage-fill {{ height: 100%; border-radius: 999px; background: var(--accent); }}
    .usage-fill.overage {{ background: var(--warning); }}
    .seat-list {{ display: grid; gap: 8px; margin-top: 12px; }}
    .seat-chip {{ display: flex; justify-content: space-between; gap: 12px; padding: 8px 10px; border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; background: rgba(5,12,8,0.52); color: var(--muted); font-size: .84rem; }}
    .audit-list {{ display: grid; gap: 10px; }}
    .audit-card {{ background: rgba(12,22,16,0.58); border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }}
    .audit-card summary {{ cursor: pointer; list-style: none; padding: 14px 16px; }}
    .audit-card summary::-webkit-details-marker {{ display: none; }}
    .audit-card[open] {{ border-color: rgba(48,209,88,0.22); background: rgba(13,25,18,0.78); }}
    .audit-card[open] summary {{ border-bottom: 1px solid var(--line); }}
    .audit-summary {{ display: grid; grid-template-columns: minmax(140px, 0.9fr) minmax(180px, 1.2fr) minmax(140px, 1fr) minmax(110px, 0.7fr) auto; gap: 12px; align-items: center; }}
    .audit-label {{ display: block; color: var(--muted); font-size: 0.74rem; }}
    .audit-value {{ display: block; color: var(--ink); font-size: 0.9rem; font-weight: 700; overflow-wrap: anywhere; }}
    .audit-status {{ color: var(--accent-strong); font-size: 0.84rem; font-weight: 800; text-align: right; white-space: nowrap; }}
    .audit-preview {{ color: var(--muted); font-size: 0.84rem; margin-top: 8px; overflow-wrap: anywhere; }}
    .audit-details {{ display: grid; gap: 16px; padding: 16px; }}
    .audit-detail-grid {{ display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }}
    .audit-detail {{ border: 1px solid rgba(255,255,255,0.07); border-radius: 8px; padding: 10px; background: rgba(5,12,8,0.48); min-width: 0; }}
    .audit-detail strong {{ display: block; color: var(--muted); font-size: 0.75rem; margin-bottom: 4px; }}
    .audit-detail span, .audit-detail code {{ color: var(--ink); overflow-wrap: anywhere; }}
    .audit-metadata {{ display: grid; gap: 8px; }}
    .admin-drawer {{ margin-top: 22px; border-top: 1px solid var(--line); padding-top: 4px; }}
    .admin-drawer > summary {{ cursor: pointer; list-style: none; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 17px 18px; }}
    .admin-drawer > summary::-webkit-details-marker {{ display: none; }}
    .drawer-title {{ font-weight: 800; }}
    .drawer-body {{ padding: 0 18px 18px; }}
    .section-head {{ display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap; }}
    .links a {{ color: var(--accent); text-decoration: none; margin-right: 16px; }}
	    .links a:hover {{ text-decoration: underline; }}
	    .muted {{ color: var(--muted); }}
	    code {{ color: var(--accent-strong); font-size: 0.9em; }}
        form {{ display: grid; gap: 10px; }}
        label {{ display: grid; gap: 6px; font-size: 0.92rem; color: var(--muted); }}
        input, select {{ width: 100%; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); font: inherit; color: var(--ink); background: var(--field); }}
        input::placeholder {{ color: rgba(143,160,150,0.72); }}
        input:focus, select:focus {{ outline: 2px solid rgba(32,240,120,0.42); outline-offset: 2px; }}
        button {{ border: 0; border-radius: 12px; padding: 12px 16px; font: inherit; font-weight: 700; background: var(--accent); color: #031006; cursor: pointer; }}
        button:hover {{ filter: brightness(1.06); }}
        .top-actions button {{ min-height:38px; padding:0 13px; border:1px solid rgba(255,255,255,0.1); border-radius:8px; background:rgba(16,24,18,0.66); color:var(--ink); box-shadow:0 10px 30px rgba(0,0,0,0.24); }}
        .two-col {{ display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }}
        .result {{ background: rgba(8,18,13,0.78); border: 1px solid var(--line); border-radius: 18px; padding: 20px; }}
        @media (max-width: 720px) {{
          main {{ padding: 24px 14px 40px; }}
          h1 {{ font-size: 1.55rem; }}
          .portal-hero {{ align-items: flex-start; }}
          .company-metrics {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
          .summary-strip {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
          .company-grid {{ grid-template-columns: 1fr; }}
          .audit-summary {{ grid-template-columns: 1fr; }}
          .audit-status {{ text-align: left; }}
        }}
	  </style>
</head>
<body>
  <main>
    {body}
  </main>
</body>
</html>
	"""


def make_access_code(name: str) -> str:
    stem = "".join(ch for ch in (name or "").upper() if ch.isalnum())[:8] or "COMPANY"
    suffix = token_urlsafe(4).replace("-", "").replace("_", "").upper()[:6]
    return normalize_access_code(f"VICALL-{stem}-{suffix}")


def employee_invite_message(access_code: str) -> str:
    return (
        f"Download Vicall, tap Get Started, and enter the company access code: {access_code}. "
        "Then complete the one-time passcode to activate your work line."
    )


def generate_temporary_password() -> str:
    raw = token_urlsafe(12).replace("-", "A").replace("_", "b")
    return f"Vicall-{raw[:14]}"


def portal_setup_password_url(request: Request, token: str) -> str:
    return f"{request.url.scheme}://{request.url.netloc}/portal/setup-password?token={quote(token)}"


def parse_billing_period_start(value: str | None, *, default: datetime | None = None) -> datetime:
    raw = (value or "").strip()
    if not raw:
        return month_start(default or datetime.now(timezone.utc))
    parsed: datetime | None = None
    if re_match := re.match(r"^\d{4}-\d{2}$", raw):
        parsed = datetime.strptime(re_match.group(0), "%Y-%m").replace(tzinfo=timezone.utc)
    elif re.match(r"^\d{4}-\d{2}-\d{2}$", raw):
        parsed = datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    else:
        parsed = parse_iso(raw)
    if parsed is None:
        raise HTTPException(status_code=400, detail="Invalid billing period. Use YYYY-MM, YYYY-MM-DD, or an ISO date.")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return month_start(parsed.astimezone(timezone.utc))


def seat_limit_label(value: int | None) -> str:
    return str(int(value)) if value is not None else "Uncapped"


def count_label(value: object) -> str:
    return f"{int(value or 0):,}"


def money_label(cents: object) -> str:
    return f"${int(cents or 0) / 100:.2f}"


def decicent_rate_label(decicents: object) -> str:
    return f"${int(decicents or 0) / 1000:.3f}"


def billing_period_label(value: object) -> str:
    raw = str(value or "").strip()
    if not raw:
        return "-"
    try:
        return parse_iso(raw).strftime("%b %Y")
    except Exception:
        return raw[:10] if len(raw) >= 10 else raw


def status_pill(label: str, tone: str = "neutral") -> str:
    safe_tone = tone if tone in {"ok", "warn", "off", "neutral"} else "neutral"
    symbol = "●" if safe_tone == "ok" else "▲" if safe_tone == "warn" else "×" if safe_tone == "off" else "•"
    return f'<span class="status-pill status-{safe_tone}"><span>{symbol}</span>{escape(label)}</span>'


def usage_bar_html(*, billable_minutes: int, included_minutes: int, overage_minutes: int) -> str:
    if included_minutes > 0:
        used_pct = min(max((billable_minutes / included_minutes) * 100, 0), 100)
        label = f"{count_label(billable_minutes)} / {count_label(included_minutes)} included minutes"
    else:
        used_pct = 100 if billable_minutes > 0 else 0
        label = f"{count_label(billable_minutes)} billable minutes"
    overage_label = (
        f"{count_label(overage_minutes)} over"
        if overage_minutes > 0
        else "No overage"
    )
    fill_class = "usage-fill overage" if overage_minutes > 0 else "usage-fill"
    return f"""
      <div class="usage-block">
        <div class="usage-row">
          <span>{escape(label)}</span>
          <strong>{escape(overage_label)}</strong>
        </div>
        <div class="usage-track"><div class="{fill_class}" style="width:{used_pct:.1f}%"></div></div>
      </div>
    """


def usage_percent_label(*, billable_minutes: int, included_minutes: int) -> str:
    if included_minutes <= 0:
        return "0%" if billable_minutes <= 0 else "Uncapped"
    return f"{min(round((max(billable_minutes, 0) / included_minutes) * 100), 999):,}%"


def mini_metric_html(label: str, value: object) -> str:
    return f"""
      <div class="mini-metric">
        <span class="caption">{escape(label)}</span>
        <span class="value">{escape(str(value))}</span>
      </div>
    """


def audit_value_label(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, str):
        return value.strip() or "-"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list, tuple)):
        return json.dumps(value, sort_keys=True, separators=(", ", ": "))
    return str(value)


def truncate_label(value: object, limit: int = 96) -> str:
    label = audit_value_label(value)
    if len(label) <= limit:
        return label
    return f"{label[: max(limit - 1, 1)]}…"


def audit_detail_html(label: str, value: object) -> str:
    rendered = truncate_label(value, 280)
    return f"""
      <div class="audit-detail">
        <strong>{escape(label)}</strong>
        <span>{escape(rendered)}</span>
      </div>
    """


def audit_metadata_preview(metadata: dict[str, Any]) -> str:
    if not metadata:
        return "No extra details"
    priority = (
        "invoice_id",
        "stripe_invoice_id",
        "status",
        "phone_number",
        "user_id",
        "organization_id",
        "period_start",
        "amount_cents",
    )
    keys = [key for key in priority if key in metadata]
    keys.extend(key for key in sorted(metadata.keys()) if key not in keys)
    parts = [f"{key}: {truncate_label(metadata.get(key), 48)}" for key in keys[:3]]
    return " · ".join(parts)


def audit_metadata_html(metadata: dict[str, Any]) -> str:
    if not metadata:
        return '<p class="sub">No metadata recorded for this event.</p>'
    rows = []
    for key in sorted(metadata.keys()):
        rows.append(audit_detail_html(str(key), metadata.get(key)))
    return f'<div class="audit-metadata">{"".join(rows)}</div>'


def render_company_portfolio_card(
    *,
    organization: dict[str, Any] | None,
    billing_line: dict[str, Any],
    manage_href: str | None = None,
    recent_memberships: list[dict[str, Any]] | None = None,
    usage_rows: list[dict[str, Any]] | None = None,
) -> str:
    organization = organization or {}
    organization_id = str(
        organization.get("id")
        or billing_line.get("organization_id")
        or "-"
    )
    organization_name = str(
        organization.get("name")
        or billing_line.get("organization_name")
        or organization_id
    )
    is_active = bool(organization.get("active", billing_line.get("organization_active", True)))
    billing_exempt = bool(organization.get("billing_exempt", billing_line.get("organization_billing_exempt", False)))
    status_html = status_pill("Active" if is_active else "Offboarded", "ok" if is_active else "off")
    billing_status_html = status_pill("Firm" if billing_exempt else "Billable", "ok" if billing_exempt else "warn")
    provisioned_seats = organization.get("provisioned_seats")
    active_seats = int(billing_line.get("active_seats") or organization.get("active_seats") or 0)
    billable_seats = int(billing_line.get("billable_seats") or 0)
    included_minutes = int(billing_line.get("included_minutes") or 0)
    billable_minutes = int(billing_line.get("billable_minutes") or 0)
    overage_minutes = int(billing_line.get("overage_minutes") or 0)
    active_access_codes = int(organization.get("active_access_codes") or 0)
    remaining_seats: int | None
    if organization.get("remaining_seats") is not None:
        remaining_seats = int(organization.get("remaining_seats") or 0)
    elif provisioned_seats is not None:
        remaining_seats = max(int(provisioned_seats) - int(organization.get("active_seats") or active_seats), 0)
    else:
        remaining_seats = None
    manage_link = (
        f'<a href="{escape(manage_href)}">Manage</a>'
        if manage_href
        else ""
    )
    meta = [
        f"Org ID: {organization_id}",
        f"Provisioned: {seat_limit_label(int(provisioned_seats)) if provisioned_seats is not None else 'Uncapped'}",
        f"Seats left: {remaining_seats if remaining_seats is not None else 'Uncapped'}",
        "Billing: Non-billable MSP firm" if billing_exempt else "Billing: Customer company",
    ]
    if organization:
        meta.append(f"Access codes: {active_access_codes}")
    recent_memberships = recent_memberships or []
    usage_rows = usage_rows or []
    seat_rows = []
    for membership in recent_memberships[:4]:
        seat_rows.append(
            f"""
            <div class="seat-chip">
              <span>{escape(str(membership.get('phone_number') or '-'))}</span>
              <span>{escape(str(membership.get('last_verified_at') or '-'))}</span>
            </div>
            """
        )
    seat_list_html = (
        f"""
        <div class="seat-list">
          {''.join(seat_rows)}
        </div>
        """
        if seat_rows
        else '<p class="sub">No signed-up numbers yet.</p>'
    )
    usage_items = []
    for usage in usage_rows[:4]:
        usage_items.append(
            f"""
            <div class="seat-chip">
              <span>{escape(str(usage.get('phone_number') or '-'))}</span>
              <span>{count_label(usage.get('billable_minutes'))} min · {count_label(usage.get('call_count'))} calls</span>
            </div>
            """
        )
    usage_list_html = (
        f"""
        <div class="seat-list">
          {''.join(usage_items)}
        </div>
        """
        if usage_items
        else '<p class="sub">No tracked minutes yet.</p>'
    )
    return f"""
      <details class="company-card">
        <summary>
          <div class="company-card-header">
            <div>
              <p class="company-title">{escape(organization_name)}</p>
              <div class="company-line">{count_label(active_seats)} active · {count_label(billable_seats)} billable · {money_label(billing_line.get("amount_cents"))} projected</div>
            </div>
            <div style="text-align:right;">
              {status_html}
              <div style="margin-top:6px;">{billing_status_html}</div>
              <div class="expand-cue">Details</div>
            </div>
          </div>
        </summary>
        <div class="company-reveal">
          <div class="company-meta">{''.join(f'<span>{escape(item)}</span>' for item in meta)}</div>
          <div class="company-metrics">
            {mini_metric_html("Active seats", count_label(active_seats))}
            {mini_metric_html("Billable seats", count_label(billable_seats))}
            {mini_metric_html("Projected", money_label(billing_line.get("amount_cents")))}
            {mini_metric_html("Billable mins", count_label(billable_minutes))}
            {mini_metric_html("Included mins", count_label(included_minutes))}
            {mini_metric_html("Overage", money_label(billing_line.get("overage_amount_cents")))}
          </div>
          {usage_bar_html(billable_minutes=billable_minutes, included_minutes=included_minutes, overage_minutes=overage_minutes)}
          <div class="company-ledger">
            <span>Invoiced seats <strong>{count_label(billing_line.get("invoiced_seats"))}</strong></span>
            <span>Uninvoiced seats <strong>{count_label(billing_line.get("unbilled_seats"))}</strong></span>
            <span>Catch-up <strong>{money_label(billing_line.get("unbilled_amount_cents"))}</strong></span>
          </div>
          <div style="margin-top:14px;">
            <h2 style="font-size:.95rem; margin-bottom:8px;">Top usage this month</h2>
            {usage_list_html}
          </div>
          <div style="margin-top:14px;">
            <h2 style="font-size:.95rem; margin-bottom:8px;">Signed-up numbers</h2>
            {seat_list_html}
          </div>
          <div class="links" style="margin-top:14px;">{manage_link}</div>
        </div>
      </details>
    """


def render_portal_auth_stepper(active_step: int) -> str:
    steps = (
        (1, "Credentials"),
        (2, "Phone"),
        (3, "Code"),
    )
    parts = []
    for index, label in steps:
        style = (
            "background:rgba(32,240,120,0.16); color:var(--accent-strong); border:1px solid rgba(32,240,120,0.42);"
            if index == active_step
            else "background:rgba(255,255,255,0.05); color:var(--muted); border:1px solid var(--line);"
        )
        parts.append(
            f'<span style="display:inline-flex; align-items:center; gap:8px; padding:8px 12px; '
            f'border-radius:999px; font-size:0.85rem; font-weight:600; {style}">{index}. {escape(label)}</span>'
        )
    return f'<div style="display:flex; flex-wrap:wrap; gap:10px; margin:18px 0 4px;">{"".join(parts)}</div>'


def render_portal_login(
    *,
    error: str | None = None,
    notice: str | None = None,
    login_email: str | None = None,
) -> str:
    error_block = f'<p style="color:var(--danger); margin-top:12px;">{escape(error)}</p>' if error else ""
    notice_block = f'<p style="color:var(--accent-strong); margin-top:12px;">{escape(notice)}</p>' if notice else ""
    return html_shell(
        "Vicall MSP Login",
        f"""
          <section class="panel" style="max-width:760px; margin:40px auto 0;">
            <h1>Vicall MSP Portal</h1>
            <p class="sub">Manage client companies, issue access codes, and review one monthly MSP billing rollup across all client seats.</p>
            {render_portal_auth_stepper(1)}
            {error_block}
            {notice_block}
            <div class="two-col" style="margin-top:20px;">
              <div class="card">
                <h2>Email + Password</h2>
                <p class="sub">Start with your MSP work email and portal password. After that, we confirm the mobile number on file and text a one-time code.</p>
                <form method="post" action="/portal/login">
                  <label>Work Email
                    <input name="email" type="email" value="{escape(login_email or '')}" placeholder="you@msp.com" required>
                  </label>
                  <label>Password
                    <input name="password" type="password" placeholder="Your MSP portal password" required>
                  </label>
                  <button type="submit">Continue</button>
                </form>
              </div>
              <div class="card">
                <h2>Account Recovery</h2>
                <p class="sub">MSP portal recovery is handled through Vicall-managed credential reset. Shared portal keys are not accepted for sign-in.</p>
                <p class="sub" style="margin-top:12px;">If your MSP account is missing a phone number or password, contact Vicall to update the login details and restart the normal sign-in flow.</p>
              </div>
            </div>
            <p class="sub" style="margin-top:18px;">Need an MSP account created or reset? Contact Vicall to provision access. MSP sign-in uses email, password, phone confirmation, and an SMS code.</p>
          </section>
        """,
    )


def render_portal_password_setup(
    *,
    token: str,
    email: str,
    msp_name: str,
    error: str | None = None,
) -> str:
    error_block = f'<p style="color:var(--danger); margin-top:12px;">{escape(error)}</p>' if error else ""
    return html_shell(
        "Set MSP Portal Password",
        f"""
          <section class="panel" style="max-width:640px; margin:40px auto 0;">
            <h1>Set your portal password</h1>
            <p class="sub"><strong>{escape(email)}</strong> · {escape(msp_name)}</p>
            {error_block}
            <div class="card" style="margin-top:18px;">
              <form method="post" action="/portal/setup-password">
                <input type="hidden" name="token" value="{escape(token)}">
                <label>New Password
                  <input name="password" type="password" autocomplete="new-password" required>
                </label>
                <label>Confirm Password
                  <input name="password_confirm" type="password" autocomplete="new-password" required>
                </label>
                <button type="submit">Set Password</button>
              </form>
            </div>
            <p class="sub" style="margin-top:18px;">After this, sign in with email, password, phone confirmation, and SMS code.</p>
          </section>
        """,
    )


def render_portal_phone_step(
    *,
    email: str,
    stored_phone_number: str | None,
    entered_phone_number: str | None = None,
    error: str | None = None,
    notice: str | None = None,
) -> str:
    error_block = f'<p style="color:var(--danger); margin-top:12px;">{escape(error)}</p>' if error else ""
    notice_block = f'<p style="color:var(--accent-strong); margin-top:12px;">{escape(notice)}</p>' if notice else ""
    masked_phone = mask_phone_number(stored_phone_number)
    phone_hint = (
        f"We have a mobile number on file ending in <strong>{escape(masked_phone)}</strong>. "
        "Enter the full number to receive your one-time code."
        if stored_phone_number
        else "This MSP account does not have a mobile number on file yet. Vicall can update it for you."
    )
    return html_shell(
        "Confirm Mobile Number",
        f"""
          <section class="panel" style="max-width:640px; margin:40px auto 0;">
            <h1>Confirm your mobile number</h1>
            <p class="sub">Your email and password are verified. We use one SMS code to finish the sign-in.</p>
            {render_portal_auth_stepper(2)}
            {error_block}
            {notice_block}
            <div class="card" style="margin-top:18px;">
              <h2>Phone confirmation</h2>
              <p class="sub"><strong>{escape(email)}</strong></p>
              <p class="sub">{phone_hint}</p>
              <form method="post" action="/portal/login/phone" style="margin-top:14px;">
                <label>Mobile Number
                  <input name="phone_number" type="tel" value="{escape(entered_phone_number or stored_phone_number or '')}" placeholder="+14155550123" required>
                </label>
                <button type="submit">Text Me a Code</button>
              </form>
            </div>
            <p class="sub" style="margin-top:18px;"><a href="/portal/login">Start over</a></p>
          </section>
        """,
    )


def render_portal_code_step(
    *,
    email: str,
    phone_number: str,
    error: str | None = None,
    notice: str | None = None,
) -> str:
    error_block = f'<p style="color:var(--danger); margin-top:12px;">{escape(error)}</p>' if error else ""
    notice_block = f'<p style="color:var(--accent-strong); margin-top:12px;">{escape(notice)}</p>' if notice else ""
    masked_phone = mask_phone_number(phone_number)
    return html_shell(
        "Enter One-Time Code",
        f"""
          <section class="panel" style="max-width:640px; margin:40px auto 0;">
            <h1>Enter your one-time code</h1>
            <p class="sub">We texted a six-digit code to <strong>{escape(masked_phone)}</strong> for <strong>{escape(email)}</strong>.</p>
            {render_portal_auth_stepper(3)}
            {error_block}
            {notice_block}
            <div class="card" style="margin-top:18px;">
              <h2>SMS verification</h2>
              <form method="post" action="/portal/login/code" style="margin-top:14px;">
                <label>One-Time Code
                  <input name="otp" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" required>
                </label>
                <button type="submit">Sign In</button>
              </form>
              <form method="post" action="/portal/login/phone" style="margin-top:12px;">
                <input type="hidden" name="phone_number" value="{escape(phone_number)}">
                <button type="submit" style="background:rgba(255,255,255,0.07); color:var(--ink); border:1px solid var(--line);">Resend Code</button>
              </form>
            </div>
            <p class="sub" style="margin-top:18px;"><a href="/portal/login/phone">Use a different number</a></p>
          </section>
        """,
    )


def render_portal_signup(*, error: str | None = None) -> str:
    return html_shell(
        "Vicall MSP Onboarding",
        f"""
          <section class="panel" style="max-width:760px; margin:40px auto 0;">
            <h1>MSP onboarding is managed by Vicall</h1>
            <p class="sub">Vicall provisions MSP accounts, billing access, and the first company profile directly. Once we set up the MSP owner email, mobile number, and password, the MSP signs in with a quick three-step flow: credentials, phone confirmation, then SMS code.</p>
            <p class="sub" style="margin-top:18px;"><a href="/portal/login">Back to MSP login</a></p>
          </section>
        """,
    )


def render_action_result(*, title: str, body: str, back_href: str, back_label: str) -> str:
    return html_shell(
        title,
        f"""
          <div class="result">
            <h1>{escape(title)}</h1>
            <div class="sub" style="margin-top:14px;">{body}</div>
            <p style="margin-top:24px;"><a href="{escape(back_href)}">{escape(back_label)}</a></p>
          </div>
        """,
    )


def public_absolute_url(request: Request, path: str) -> str:
    normalized_path = path if path.startswith("/") else f"/{path}"
    return f"{public_base_url(request)}{normalized_path}"


def portal_login_url(request: Request, token: str) -> str:
    return public_absolute_url(request, f"/portal/login/verify?token={quote(token)}")


def account_deletion_manage_url(request: Request, token: str) -> str:
    return public_absolute_url(request, f"/account/delete/manage?token={quote(token)}")


def account_deletion_flow_mode() -> str:
    configured = (os.getenv("ACCOUNT_DELETION_FLOW_MODE") or "api").strip().lower()
    return configured if configured in {"api", "web"} else "api"


def mask_phone_number(phone_number: str | None) -> str:
    normalized = (phone_number or "").strip()
    if len(normalized) >= 4:
        return f"••••{normalized[-4:]}"
    return "this account"


def render_account_deletion_manage(
    *,
    token: str,
    phone_number: str | None,
    expires_at: str | None,
    error: str | None = None,
) -> str:
    error_html = f'<p class="sub" style="color:var(--danger);">{escape(error)}</p>' if error else ""
    return html_shell(
        "Delete Vicall Account",
        f"""
          <section class="panel" style="max-width:760px; margin:40px auto 0;">
            <h1>Delete Vicall account</h1>
            <p class="sub">This secure page lets you finish deleting the Vicall account for <strong>{escape(mask_phone_number(phone_number))}</strong>.</p>
            <p class="sub">Deleting your account removes device data and active access immediately. Your MSP manages billing and deployment, so this action does not cancel the company's MSP service. The seat stays billable through the current month.</p>
            <p class="sub">This link expires at {escape(expires_at or "soon")}.</p>
            {error_html}
            <form method="post" action="/account/delete/manage" style="margin-top:18px;">
              <input type="hidden" name="token" value="{escape(token)}">
              <button type="submit">Delete Account</button>
            </form>
            <p class="sub" style="margin-top:18px;">If you reached this page from the Vicall app, you can return to the app after confirming deletion.</p>
          </section>
        """,
    )


async def send_portal_login_email(
    *,
    request: Request,
    to_email: str,
    msp_name: str,
    full_name: str | None,
    token: str,
) -> None:
    link = portal_login_url(request, token)
    subject = f"Sign in to {msp_name} on Vicall"
    recipient_name = full_name or to_email
    text_body = (
        f"Hi {recipient_name},\n\n"
        f"Use this secure link to sign in to the {msp_name} Vicall MSP portal:\n{link}\n\n"
        "This link expires in 20 minutes."
    )
    html_body = f"""
      <p>Hi {escape(recipient_name)},</p>
      <p>Use this secure link to sign in to the <strong>{escape(msp_name)}</strong> Vicall MSP portal:</p>
      <p><a href="{escape(link)}">{escape(link)}</a></p>
      <p>This link expires in 20 minutes.</p>
    """
    await send_email(
        to_email=to_email,
        subject=subject,
        text_body=text_body,
        html_body=html_body,
    )


def render_admin_dashboard(overview: dict[str, object], admin_key: str) -> str:
    current_period = month_start(datetime.now(timezone.utc))
    default_billing_period = month_start(current_period - timedelta(days=1))
    default_billing_month = default_billing_period.strftime("%Y-%m")
    msp_rows = []
    for msp in overview["msps"]:
        msp_rows.append(
            f"""
            <tr>
              <td>{escape(str(msp["name"]))}<div class="muted"><code>{escape(str(msp["id"]))}</code></div></td>
              <td>{escape(portal_status_label(msp.get("status") or MSP_STATUS_ACTIVE))}</td>
              <td>{msp["organization_count"]}</td>
              <td>{msp["active_memberships"]}</td>
              <td>${int(msp["seat_price_cents"]) / 100:.2f}</td>
              <td>{escape(str(msp.get("billing_email") or "-"))}</td>
              <td>{escape(str(msp.get("stripe_customer_id") or "not linked"))}</td>
            </tr>
            """
        )

    body = f"""
      <h1>Vicall Admin Dashboard</h1>
      <p class="sub">Channel control plane overview for MSPs, organizations, codes, and seats.</p>

      <section class="grid">
        <div class="card"><div class="label">MSPs</div><div class="metric">{overview['msp_count']}</div></div>
        <div class="card"><div class="label">Companies</div><div class="metric">{overview['organization_count']}</div></div>
        <div class="card"><div class="label">Access Codes</div><div class="metric">{overview['access_code_count']}</div></div>
        <div class="card"><div class="label">Active Seats</div><div class="metric">{overview['active_membership_count']}</div></div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Monthly Billing</h2>
        <p class="sub">Run a selected billing period for every MSP. Each MSP gets one invoice, with companies grouped underneath as line items. The default is the last completed month.</p>
        <form method="post" action="/admin/billing/run-all?key={quote(admin_key)}">
          <label>Billing Period
            <input name="period_start" type="month" value="{escape(default_billing_month)}" required>
          </label>
          <button type="submit">Run Monthly Billing for All MSPs</button>
        </form>
      </section>

	      <section class="panels">
            <div class="panel">
              <h2>Provision New MSP</h2>
              <p class="sub">Create the MSP, their owner login, the MSP firm profile, and the first firm access code in one pass. Customer companies require Stripe payment setup.</p>
              <form method="post" action="/admin/provision-msp?key={quote(admin_key)}">
                <div class="two-col">
                  <label>MSP Name
                    <input name="msp_name" placeholder="Northshore MSP" required>
                  </label>
                  <label>Billing Email
                    <input name="billing_email" type="email" placeholder="billing@northshoremsp.com">
                  </label>
                  <label>Seat Price (cents)
                    <input name="seat_price_cents" type="number" min="0" value="{DEFAULT_MSP_SEAT_PRICE_CENTS}" required>
                  </label>
                  <label>MSP Status
                    <select name="msp_status" style="width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); font:inherit; color:var(--ink); background:var(--field);">
                      <option value="active" selected>Active</option>
                      <option value="pending_review">Pending Review</option>
                      <option value="suspended">Suspended</option>
                    </select>
                  </label>
                  <label>Portal Owner Name
                    <input name="owner_full_name" placeholder="Alex Morgan">
                  </label>
                  <label>Portal Owner Email
                    <input name="owner_email" type="email" placeholder="alex@northshoremsp.com">
                  </label>
                  <label>Portal Owner Phone
                    <input name="owner_phone_number" type="tel" placeholder="+14155550123">
                  </label>
                  <label>Portal Owner Password
                    <input name="owner_password" type="password" placeholder="Optional initial password, not displayed">
                  </label>
                  <label>MSP Firm Name
                    <input name="company_name" placeholder="Northshore MSP" required>
                  </label>
                  <label>External Reference
                    <input name="external_ref" placeholder="CW-ACME-01">
                  </label>
                  <label>Access Code (optional)
                    <input name="access_code" placeholder="VICALL-ACME-1234">
                  </label>
                </div>
                <button type="submit">Provision MSP</button>
              </form>
            </div>
	        <div class="panel">
	          <h2>MSPs</h2>
          <table>
            <thead>
              <tr>
                <th>MSP</th>
                <th>Status</th>
                <th>Companies</th>
                <th>Active Seats</th>
                <th>Seat Price</th>
                <th>Billing Email</th>
                <th>Stripe</th>
              </tr>
            </thead>
            <tbody>
              {''.join(msp_rows) or '<tr><td colspan="7">No MSPs yet.</td></tr>'}
            </tbody>
          </table>
        </div>
      </section>
    """
    return html_shell("Vicall Admin Dashboard", body)


async def run_monthly_billing_for_msp(
    msp_id: str,
    *,
    period_start_value: datetime | None = None,
) -> dict[str, object]:
    snapshot = control_plane.billing_snapshot(
        msp_id=msp_id,
        period_start_value=period_start_value or month_start(datetime.now(timezone.utc)),
    )
    usage_snapshot = control_plane.record_usage_snapshot(msp_id=msp_id, snapshot=snapshot)
    existing = control_plane.existing_billing_run(
        msp_id=msp_id,
        period_start=str(snapshot["period_start"]),
    )
    if not snapshot["stripe_customer_id"]:
        record_system_audit_event(
            msp_id=msp_id,
            action="system.billing.run",
            status="skipped_missing_customer",
            target_type="billing_run",
            target_id=str(snapshot.get("period_start") or ""),
            details={"period_start": snapshot.get("period_start")},
        )
        return {
            "msp_id": msp_id,
            "status": "skipped_missing_customer",
            "snapshot": snapshot,
            "usage_snapshot": usage_snapshot,
        }

    amount_due_cents = int(snapshot.get("total_unbilled_amount_cents", snapshot["total_amount_cents"]) or 0)
    if amount_due_cents <= 0:
        if existing and existing.get("stripe_invoice_id"):
            record_system_audit_event(
                msp_id=msp_id,
                action="system.billing.run",
                status="already_ran",
                target_type="billing_run",
                target_id=str(existing.get("id") or existing.get("stripe_invoice_id") or snapshot.get("period_start")),
                details={
                    "period_start": snapshot.get("period_start"),
                    "stripe_invoice_id": existing.get("stripe_invoice_id"),
                    "status": existing.get("status"),
                },
            )
            return {
                "msp_id": msp_id,
                "status": "already_ran",
                "invoice_id": existing["stripe_invoice_id"],
                "invoice_status": existing.get("status"),
                "snapshot": snapshot,
                "usage_snapshot": usage_snapshot,
            }
        record_system_audit_event(
            msp_id=msp_id,
            action="system.billing.run",
            status="skipped_zero_amount",
            target_type="billing_run",
            target_id=str(snapshot.get("period_start") or ""),
            details={
                "period_start": snapshot.get("period_start"),
                "total_amount_cents": int(snapshot.get("total_amount_cents") or 0),
                "total_unbilled_amount_cents": amount_due_cents,
            },
        )
        return {
            "msp_id": msp_id,
            "status": "skipped_zero_amount",
            "snapshot": snapshot,
            "usage_snapshot": usage_snapshot,
        }

    if not stripe_enabled():
        raise HTTPException(status_code=503, detail="Stripe is not configured")

    billing_readiness = await stripe_billing_readiness(str(snapshot["stripe_customer_id"]))
    if not bool(billing_readiness.get("auto_charge_ready")):
        current_msp = control_plane.get_msp(msp_id)
        if current_msp is not None and str(current_msp["status"]) == MSP_STATUS_ACTIVE:
            control_plane.set_msp_status(msp_id=msp_id, status=MSP_STATUS_SUSPENDED)
        record_system_audit_event(
            msp_id=msp_id,
            action="system.billing.run",
            status="skipped_missing_payment_method",
            target_type="billing_run",
            target_id=str(snapshot.get("period_start") or ""),
            details={
                "period_start": snapshot.get("period_start"),
                "payment_method_label": billing_readiness.get("payment_method_label"),
                "status_action": "suspended" if current_msp is not None and str(current_msp["status"]) == MSP_STATUS_ACTIVE else "unchanged",
            },
        )
        return {
            "msp_id": msp_id,
            "status": "skipped_missing_payment_method",
            "snapshot": snapshot,
            "usage_snapshot": usage_snapshot,
        }

    try:
        invoice_lines: list[dict[str, Any]] = []
        for line in snapshot["lines"]:
            unbilled_amount_cents = int(line.get("unbilled_amount_cents", line["amount_cents"]) or 0)
            if unbilled_amount_cents <= 0:
                continue
            unbilled_seats = int(line.get("unbilled_seats") or line.get("billable_seats") or 0)
            unbilled_overage_amount_cents = int(line.get("unbilled_overage_amount_cents") or 0)
            overage_minutes = int(line.get("unbilled_overage_minutes") or line.get("overage_minutes") or 0) if unbilled_overage_amount_cents > 0 else 0
            description_parts: list[str] = []
            if unbilled_seats > 0:
                description_parts.append(
                    f'{unbilled_seats} uninvoiced billable seat{"s" if unbilled_seats != 1 else ""}'
                )
            if overage_minutes > 0:
                description_parts.append(
                    f'{overage_minutes} overage minute{"s" if overage_minutes != 1 else ""}'
                )
            invoice_line = dict(line)
            invoice_line["invoice_amount_cents"] = unbilled_amount_cents
            invoice_line["invoice_description"] = (
                f'{line["organization_name"]} — {", ".join(description_parts) if description_parts else "monthly usage"}'
            )
            invoice_lines.append(invoice_line)
        result = await create_monthly_invoice(
            customer_id=str(snapshot["stripe_customer_id"]),
            msp_id=msp_id,
            period_start=str(snapshot["period_start"]),
            lines=invoice_lines,
            idempotency_suffix=(
                f'adjustment-{amount_due_cents}-{int(snapshot.get("total_unbilled_seats") or 0)}-'
                f'{int(snapshot.get("total_billable_minutes") or 0)}'
                if existing and existing.get("stripe_invoice_id")
                else None
            ),
        )
        invoice = result["invoice"]
        billing_run = control_plane.record_billing_run(
            msp_id=msp_id,
            snapshot=snapshot,
            stripe_invoice_id=invoice["id"],
            hosted_invoice_url=invoice.get("hosted_invoice_url"),
            line_item_ids_by_org=result["line_item_ids_by_org"],
            status=invoice.get("status") or "open",
        )
    except StripeBillingError as exc:
        record_system_audit_event(
            msp_id=msp_id,
            action="system.billing.run",
            status="failed",
            target_type="billing_run",
            target_id=str(snapshot.get("period_start") or ""),
            details={
                "period_start": snapshot.get("period_start"),
                "error": str(exc),
            },
        )
        return {
            "msp_id": msp_id,
            "status": "failed",
            "error": str(exc),
            "snapshot": snapshot,
            "usage_snapshot": usage_snapshot,
        }

    record_system_audit_event(
        msp_id=msp_id,
        action="system.billing.run",
        status="created",
        target_type="billing_run",
        target_id=str(billing_run.get("id") or invoice["id"]),
        details={
            "period_start": snapshot.get("period_start"),
            "stripe_invoice_id": invoice.get("id"),
            "hosted_invoice_url": invoice.get("hosted_invoice_url"),
            "total_amount_cents": int(snapshot.get("total_amount_cents") or 0),
            "total_billable_seats": int(snapshot.get("total_billable_seats") or 0),
        },
    )

    return {
        "msp_id": msp_id,
        "status": "created",
        "snapshot": snapshot,
        "billing_run": billing_run,
        "usage_snapshot": usage_snapshot,
        "invoice_id": invoice["id"],
        "invoice_status": invoice.get("status"),
        "invoice_hosted_url": invoice.get("hosted_invoice_url"),
    }


async def run_monthly_billing_for_all_msps(
    *,
    period_start_value: datetime | None = None,
) -> list[dict[str, object]]:
    overview = control_plane.admin_overview()
    results: list[dict[str, object]] = []
    for msp in overview["msps"]:
        results.append(
            await run_monthly_billing_for_msp(
                str(msp["id"]),
                period_start_value=period_start_value,
            )
        )
    return results


def first_day_billing_period(now: datetime | None = None) -> datetime | None:
    current = now or datetime.now(timezone.utc)
    if current.day != 1:
        return None
    return month_start(current - timedelta(days=1))


async def maybe_run_first_day_auto_billing(now: datetime | None = None) -> list[dict[str, object]]:
    global auto_billing_last_period
    period = first_day_billing_period(now)
    if period is None:
        return []
    period_key = isoformat(period)
    if auto_billing_last_period == period_key:
        return []
    logger.info("[Billing] Running first-day automatic monthly billing for period=%s", period_key)
    results = await run_monthly_billing_for_all_msps(period_start_value=period)
    if not any(str(result.get("status") or "") == "failed" for result in results):
        auto_billing_last_period = period_key
    return results


async def first_day_auto_billing_loop() -> None:
    interval_seconds = max(int(os.getenv("VICALL_AUTO_BILLING_INTERVAL_SECONDS", "21600")), 300)
    while True:
        try:
            await maybe_run_first_day_auto_billing()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Billing] First-day automatic billing check failed")
        await asyncio.sleep(interval_seconds)


@app.on_event("startup")
async def start_first_day_auto_billing() -> None:
    global auto_billing_task
    if not truthy_env("VICALL_AUTO_BILLING_ENABLED", "true"):
        return
    if auto_billing_task is None or auto_billing_task.done():
        auto_billing_task = asyncio.create_task(first_day_auto_billing_loop())


@app.on_event("shutdown")
async def stop_first_day_auto_billing() -> None:
    global auto_billing_task
    if auto_billing_task is None:
        return
    auto_billing_task.cancel()
    try:
        await auto_billing_task
    except asyncio.CancelledError:
        pass
    auto_billing_task = None


def portal_session_for_existing_user(msp_id: str) -> tuple[dict[str, Any], Any] | None:
    users = [user for user in control_plane.list_msp_users(msp_id) if bool(user.get("active", 1))]
    if len(users) != 1:
        return None
    session = control_plane.create_msp_session(msp_user_id=str(users[0]["id"]))
    return session.as_msp_row(), session


def render_portal_dashboard(
    summary: dict[str, object],
    *,
    actor: dict[str, Any] | None = None,
    company_query: str = "",
    company_status: str = "all",
    page: int = 1,
) -> str:
    organizations = summary["organizations"]
    memberships = summary["recent_memberships"]
    billing = summary["current_billing_snapshot"]
    msp = summary["msp"]
    active_organization_count = int(summary.get("active_organization_count") or sum(1 for org in organizations if bool(org.get("active"))))
    total_company_count = int(summary.get("organization_total_count") or len(organizations))
    team_users = summary.get("team_users", [])
    billing_runs = summary.get("billing_runs", [])
    billing_readiness = summary.get("billing_readiness", {})
    auto_charge_ready = bool(billing_readiness.get("auto_charge_ready"))
    has_msp_firm = bool(summary.get("has_active_msp_firm")) or any(
        bool(org.get("billing_exempt")) and bool(org.get("active"))
        for org in organizations
    )
    billing_lines = list(billing.get("lines", []))
    active_customer_company_count = sum(
        1
        for line in billing_lines
        if not bool(line.get("organization_billing_exempt")) and bool(line.get("organization_active", True))
    )
    active_firm_count = sum(
        1
        for line in billing_lines
        if bool(line.get("organization_billing_exempt")) and bool(line.get("organization_active", True))
    )
    billable_minutes_total = int(billing.get("total_billable_minutes") or 0)
    included_minutes_total = int(billing.get("total_included_minutes") or 0)
    active_seat_total = int(billing.get("total_active_seats") or 0)
    active_seat_noun = "seat" if active_seat_total == 1 else "seats"
    minute_utilization = usage_percent_label(
        billable_minutes=billable_minutes_total,
        included_minutes=included_minutes_total,
    )
    payment_status_label = "Ready" if auto_charge_ready else "Needs setup"
    payment_status_tone = "ok" if auto_charge_ready else "warn"
    billing_lines_by_org = {
        str(line["organization_id"]): line
        for line in billing_lines
    }
    org_names_by_id = {str(org["id"]): str(org.get("name") or org["id"]) for org in organizations}
    memberships_by_org: dict[str, list[dict[str, Any]]] = {}
    for membership in memberships:
        memberships_by_org.setdefault(str(membership["organization_id"]), []).append(membership)
    user_usage_by_org: dict[str, list[dict[str, Any]]] = {}
    user_usage_rows = sorted(
        list(billing.get("user_usage", [])),
        key=lambda row: (
            int(row.get("billable_minutes") or 0),
            int(row.get("call_count") or 0),
        ),
        reverse=True,
    )
    for usage in user_usage_rows:
        organization_id = str(usage.get("organization_id") or "")
        if not organization_id:
            continue
        org_usage = user_usage_by_org.setdefault(organization_id, [])
        if len(org_usage) < 4:
            org_usage.append(usage)

    org_rows = []
    org_cards = []
    for org in organizations:
        billing_line = billing_lines_by_org.get(str(org["id"]), {})
        is_active = bool(org.get("active"))
        billable_seats = int(billing_line.get("billable_seats") or 0)
        invoiced_seats = int(billing_line.get("invoiced_seats") or 0)
        unbilled_seats = int(billing_line.get("unbilled_seats") or 0)
        call_count = int(billing_line.get("call_count") or 0)
        billable_minutes = int(billing_line.get("billable_minutes") or 0)
        included_minutes = int(billing_line.get("included_minutes") or 0)
        overage_minutes = int(billing_line.get("overage_minutes") or 0)
        overage_amount_cents = int(billing_line.get("overage_amount_cents") or 0)
        if not is_active and billable_seats == 0:
            continue
        status_label = "Active" if is_active else "Offboarded"
        status_html = status_pill(status_label, "ok" if is_active else "off")
        provisioned_seats = org.get("provisioned_seats")
        remaining_seats = (
            max(int(provisioned_seats) - int(org["active_seats"]), 0)
            if provisioned_seats is not None
            else None
        )
        org_cards.append(
            render_company_portfolio_card(
                organization=org,
                billing_line=billing_line,
                manage_href=f"/portal/companies/{quote(str(org['id']))}",
                recent_memberships=memberships_by_org.get(str(org["id"]), []),
                usage_rows=user_usage_by_org.get(str(org["id"]), []),
            )
        )
        org_rows.append(
            f"""
            <tr>
              <td>{escape(str(org["name"]))}<div class="muted"><code>{escape(str(org["id"]))}</code></div></td>
              <td>{status_html}</td>
              <td>{seat_limit_label(int(provisioned_seats)) if provisioned_seats is not None else 'Uncapped'}</td>
              <td>{org["active_seats"]}</td>
              <td>{remaining_seats if remaining_seats is not None else 'Uncapped'}</td>
              <td>{billable_seats}</td>
              <td>{count_label(billable_minutes)} / {count_label(included_minutes)}</td>
              <td>{count_label(overage_minutes)} min<br><span class="muted">{money_label(overage_amount_cents)}</span></td>
              <td>{invoiced_seats} invoiced<br><span class="muted">{unbilled_seats} uninvoiced</span></td>
              <td>{escape(str(org.get("last_verified_at") or "-"))}</td>
              <td>{money_label(billing_line.get("amount_cents"))}</td>
              <td><a href="/portal/companies/{quote(str(org['id']))}">Manage</a></td>
            </tr>
            """
        )

    membership_rows = []
    for membership in memberships[:12]:
        membership_org_id = str(membership["organization_id"])
        membership_org_name = org_names_by_id.get(membership_org_id, membership_org_id)
        membership_rows.append(
            f"""
            <tr>
              <td>{escape(membership_org_name)}<div class="muted"><code>{escape(membership_org_id)}</code></div></td>
              <td>{escape(str(membership["phone_number"]))}</td>
              <td>{escape(str(membership.get("user_id") or "-"))}</td>
              <td>{escape(str(membership["last_verified_at"]))}</td>
            </tr>
            """
        )

    team_rows = []
    for user in team_users[:12]:
        team_rows.append(
            f"""
            <tr>
              <td>{escape(str(user.get("full_name") or "-"))}</td>
              <td>{escape(str(user["email"]))}</td>
              <td>{escape(str(user.get("phone_number") or "-"))}</td>
              <td>{escape(portal_role_label(user.get("role")))}</td>
              <td>{escape(str(user.get("last_login_at") or "-"))}</td>
            </tr>
            """
        )

    billing_rows = []
    for run in billing_runs[:12]:
        billing_rows.append(
            f"""
            <tr>
              <td>{escape(str(run.get('period_start') or '-'))}</td>
              <td>{escape(str(run.get('status') or '-'))}</td>
              <td><code>{escape(str(run.get('stripe_invoice_id') or '-'))}</code></td>
              <td>{escape(str(run.get('finalized_at') or run.get('created_at') or '-'))}</td>
            </tr>
            """
        )

    page_size = int(summary.get("organization_page_size") or 50)
    has_prev = page > 1
    has_next = page * page_size < total_company_count
    query_bits = []
    if company_query:
        query_bits.append(f"q={quote(company_query)}")
    if company_status and company_status != "all":
        query_bits.append(f"status={quote(company_status)}")
    prev_href = f"/portal/dashboard?{'&'.join(query_bits + [f'page={page - 1}'])}" if has_prev else "#"
    next_href = f"/portal/dashboard?{'&'.join(query_bits + [f'page={page + 1}'])}" if has_next else "#"
    actor_name = (actor or {}).get("full_name") or (actor or {}).get("email") or "MSP user"
    actor_role = normalize_msp_role((actor or {}).get("role")) if actor else MSP_ROLE_OWNER
    actor_role_label = portal_role_label(actor_role)
    msp_status = normalize_msp_status(msp.get("status"))
    msp_status_label = portal_status_label(msp_status)
    status_notice = portal_status_notice(msp_status)
    status_notice_html = (
        f"""
      <section class="panel" style="margin-top:24px;">
        <h2>{escape(msp_status_label)}</h2>
        <p class="sub">{escape(status_notice)}</p>
      </section>
        """
        if status_notice
        else ""
    )
    payment_notice_html = (
        f"""
      <section class="panel" style="margin-top:24px;">
        <h2>Payment Method Required</h2>
        <p class="sub">Your MSP firm is available and non-billable. Add a default Stripe payment method before creating customer companies, issuing customer access codes, or activating billable seats.</p>
        <form method="post" action="/portal/billing/manage" style="margin-top:14px;">
          <button type="submit">Open Stripe Billing Portal</button>
        </form>
      </section>
        """
        if has_msp_firm and not auto_charge_ready
        else ""
    )
    add_company_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="create client companies",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    issue_access_code_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="issue live access codes",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_PRODUCTION_STATUS_SET,
    )
    offboard_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="change company or seat access",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    billing_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="manage Stripe billing",
        allowed_roles=PORTAL_BILLING_ROLE_SET,
        allowed_statuses=PORTAL_BILLING_STATUS_SET,
    )
    team_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="manage MSP users",
        allowed_roles=PORTAL_OWNER_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    add_company_html = (
        """
                <p class="sub">Add a default Stripe payment method before creating customer companies. Your MSP firm remains available and non-billable.</p>
        """
        if has_msp_firm and not auto_charge_ready
        else (
        """
                <form method="post" action="/portal/companies/create">
                  <label>Company Name
                    <input name="company_name" placeholder="Acme Dental" required>
                  </label>
                  <label>External Reference
                    <input name="external_ref" placeholder="PSA / CRM reference">
                  </label>
                  <label>Provisioned Seats (optional)
                    <input name="provisioned_seats" type="number" min="1" placeholder="Leave blank for uncapped">
                  </label>
                  <label>Access Code (optional)
                    <input name="access_code" placeholder="Leave blank to auto-generate">
                  </label>
                  <button type="submit">Create Company</button>
                </form>
        """
        if add_company_restriction is None
        else f"<p class=\"sub\">{escape(add_company_restriction[1])}</p>"
        )
    )
    issue_access_code_html = (
        """
                <form method="post" action="/portal/access-codes/create">
                  <label>Organization ID
                    <input name="organization_id" placeholder="org_123" required>
                  </label>
                  <label>Label
                    <input name="label" placeholder="Summer hires or New office">
                  </label>
                  <label>Seats On This Code (optional)
                    <input name="max_activations" type="number" min="1" placeholder="Leave blank for uncapped">
                  </label>
                  <label>Access Code (optional)
                    <input name="access_code" placeholder="Leave blank to auto-generate">
                  </label>
                  <button type="submit">Create Access Code</button>
                </form>
        """
        if issue_access_code_restriction is None
        else f"<p class=\"sub\">{escape(issue_access_code_restriction[1])}</p>"
    )
    offboard_company_html = (
        """
                <form method="post" action="/portal/organizations/deactivate">
                  <label>Organization ID
                    <input name="organization_id" placeholder="org_123" required>
                  </label>
                  <button type="submit">Disable Company</button>
                </form>
        """
        if offboard_restriction is None
        else f"<p class=\"sub\">{escape(offboard_restriction[1])}</p>"
    )
    offboard_employee_html = (
        """
                <form method="post" action="/portal/memberships/deactivate">
                  <label>Employee Phone Number
                    <input name="phone_number" placeholder="+14155550123" required>
                  </label>
                  <label>User ID (optional)
                    <input name="user_id" placeholder="user_123">
                  </label>
                  <button type="submit">Remove Access</button>
                </form>
        """
        if offboard_restriction is None
        else f"<p class=\"sub\">{escape(offboard_restriction[1])}</p>"
    )
    billing_manage_html = (
        f"""
                <form method="post" action="/portal/billing/manage" style="margin-top:18px;">
                  <button type="submit">{'Open Stripe Billing Portal' if billing_readiness.get('customer_id') else 'Stripe Not Linked Yet'}</button>
                </form>
        """
        if billing_restriction is None
        else f"<p class=\"sub\">{escape(billing_restriction[1])}</p>"
    )
    team_invite_html = (
        """
          <form method="post" action="/portal/team/invite" style="margin:0 0 14px 0;">
            <div class="two-col">
              <label>Name
                <input name="full_name" placeholder="Jordan Lee">
              </label>
              <label>Email
                <input name="email" type="email" placeholder="jordan@msp.com" required>
              </label>
              <label>Phone Number
                <input name="phone_number" type="tel" placeholder="+14155550123" required>
              </label>
              <label>Role
                <select name="role" style="width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); font:inherit; color:var(--ink); background:var(--field);">
                  <option value="operator" selected>Operator</option>
                  <option value="billing_admin">Billing Admin</option>
                  <option value="read_only">Read Only</option>
                </select>
              </label>
              <label>Initial Password
                <input name="password" type="password" placeholder="Optional, not displayed">
              </label>
            </div>
            <button type="submit">Create MSP User</button>
          </form>
        """
        if team_restriction is None
        else f"<p class=\"sub\">{escape(team_restriction[1])}</p>"
    )

    body = f"""
      <section class="portal-hero">
        <div>
          <div class="eyebrow">Vicall MSP Portal</div>
          <h1>{escape(str(msp['name']))}</h1>
          <p class="sub">Signed in as <strong>{escape(str(actor_name))}</strong>{' · ' + escape(actor_role_label) if actor else ''} · {escape(msp_status_label)}</p>
        </div>
        <div class="top-actions">
          <a class="primary" href="/portal/billing">Open Billing Center</a>
          <a href="/portal/audit">View Audit Log</a>
          <form method="post" action="/portal/logout" style="display:inline;">
            <button class="ghost-button" type="submit">Sign Out</button>
          </form>
        </div>
      </section>

      <section class="summary-strip">
        <div class="card summary-card"><div class="label">Customer Companies</div><div class="metric">{count_label(active_customer_company_count)}</div><div class="muted">{count_label(active_firm_count)} firm · {count_label(active_organization_count)} active total</div></div>
        <div class="card summary-card"><div class="label">Billable Seats</div><div class="metric">{count_label(billing.get('total_billable_seats', active_seat_total))}</div><div class="muted">{count_label(active_seat_total)} active {escape(active_seat_noun)}</div></div>
        <div class="card summary-card"><div class="label">Used / Included Minutes</div><div class="metric">{count_label(billable_minutes_total)} / {count_label(included_minutes_total)}</div><div class="muted">{escape(minute_utilization)} used</div></div>
        <div class="card summary-card"><div class="label">Overage</div><div class="metric">{count_label(billing.get('total_overage_minutes', 0))} min</div><div class="muted">{money_label(billing.get('total_overage_amount_cents'))}</div></div>
        <div class="card summary-card"><div class="label">Uninvoiced Catch-Up</div><div class="metric">{money_label(billing.get('total_unbilled_amount_cents', billing['total_amount_cents']))}</div></div>
        <div class="card summary-card"><div class="label">Payment</div><div class="metric">{status_pill(payment_status_label, payment_status_tone)}</div><div class="muted">{escape(str(billing_readiness.get('payment_method_label') or 'Not checked'))}</div></div>
        <div class="card summary-card primary"><div class="label">Projected Monthly Bill</div><div class="metric">{money_label(billing['total_amount_cents'])}</div></div>
      </section>

      {status_notice_html}
      {payment_notice_html}

      <section style="margin-top:30px;">
        <div class="section-head">
          <div>
            <h2>Client Companies</h2>
            <p class="sub">Each company opens into its seats, billing, included minutes, and access controls.</p>
          </div>
        </div>
        <div class="company-grid">
          {''.join(org_cards) or '<p class="sub">No companies yet.</p>'}
        </div>
      </section>

      <details id="partner-tools" class="admin-drawer">
        <summary>
          <span class="drawer-title">Partner tools and reports</span>
          <span class="muted">Provisioning, exports, team, and detailed tables</span>
        </summary>
        <div class="drawer-body">
          <section class="panel" style="margin-top:8px;">
            <h2>Billing Rollup</h2>
            <p class="sub">Customer-company signups create an immediate Stripe invoice for the MSP. The MSP firm is non-billable. Each customer company includes {count_label(billing.get('included_minutes_per_seat', 450))} minutes per billable seat, then usage bills at {decicent_rate_label(billing.get('overage_rate_decicents_per_minute', 1))} per overage minute, rounded at the company line.</p>
            <p class="sub"><strong>Stripe billing status:</strong> {escape(str(billing_readiness.get('payment_method_label') or 'Not checked'))}</p>
            <div class="links" style="margin-top:14px;">
              <a href="/portal/export/companies.csv">Download Company CSV</a>
              <a href="/portal/export/users.csv">Download User CSV</a>
              <a href="/portal/export/usage.csv">Download Usage CSV</a>
            </div>
          </section>

	      <section class="panels">
            <div class="two-col">
              <div class="panel">
                <h2>Add Company</h2>
                <p class="sub">Create a new client company and issue a ready-to-send access code.</p>
                {add_company_html}
              </div>
              <div class="panel">
                <h2>Issue Access Code</h2>
                <p class="sub">Create another onboarding code for an existing company without changing billing or seat counts.</p>
                {issue_access_code_html}
              </div>
            </div>
            <div class="two-col">
              <div class="panel">
                <h2>Offboard Company</h2>
                <p class="sub">Disable a client company, expire its active access codes, and end employee access immediately.</p>
                {offboard_company_html}
              </div>
              <div class="panel">
                <h2>Offboard Employee</h2>
                <p class="sub">Remove a user's access immediately. Their seat remains billable through the current month.</p>
                {offboard_employee_html}
              </div>
              <div class="panel">
                <h2>Employee Onboarding</h2>
                <p class="sub">Send the company access code to the employee. They enter it in the app, then complete OTP to join the company.</p>
                <p class="sub">If someone was offboarded earlier, onboarding with a valid company code reactivates their access.</p>
                {billing_manage_html}
              </div>
            </div>
	        <div class="panel">
	          <h2>Company Detail Table</h2>
          <form method="get" action="/portal/dashboard" style="margin:0 0 14px 0;">
            <div class="two-col">
              <label>Search Companies
                <input name="q" value="{escape(company_query)}" placeholder="Search by company name, ID, or external reference">
              </label>
              <label>Status
                <select name="status" style="width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); font:inherit; color:var(--ink); background:var(--field);">
                  <option value="all" {"selected" if company_status == "all" else ""}>All companies</option>
                  <option value="active" {"selected" if company_status == "active" else ""}>Active only</option>
                  <option value="offboarded" {"selected" if company_status == "offboarded" else ""}>Offboarded only</option>
                </select>
              </label>
            </div>
            <button type="submit">Filter Companies</button>
          </form>
          <p class="sub">Showing page {page}. Total companies: {total_company_count}.</p>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Company</th>
                  <th>Status</th>
                  <th>Provisioned</th>
                  <th>Active</th>
                  <th>Left</th>
                  <th>Billable</th>
                  <th>Usage</th>
                  <th>Overage</th>
                  <th>Invoicing</th>
                  <th>Last Verified</th>
                  <th>Projected</th>
                  <th>Manage</th>
                </tr>
              </thead>
              <tbody>
                {''.join(org_rows) or '<tr><td colspan="12">No companies yet.</td></tr>'}
              </tbody>
            </table>
          </div>
          <div class="links" style="margin-top:16px;">
            {'<a href="' + prev_href + '">Previous Page</a>' if has_prev else '<span class="muted">Previous Page</span>'}
            {'<a href="' + next_href + '">Next Page</a>' if has_next else '<span class="muted">Next Page</span>'}
          </div>
        </div>

        <div class="panel">
          <h2>Recent Seats by Company</h2>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Company</th>
                  <th>Phone</th>
                  <th>User ID</th>
                  <th>Last Verified</th>
                </tr>
              </thead>
              <tbody>
                {''.join(membership_rows) or '<tr><td colspan="4">No recent members yet.</td></tr>'}
              </tbody>
            </table>
          </div>
        </div>

        <div class="panel">
          <h2>MSP Team</h2>
          {team_invite_html}
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
                <th>Phone</th>
                <th>Role</th>
                <th>Last Login</th>
              </tr>
            </thead>
            <tbody>
              {''.join(team_rows) or '<tr><td colspan="5">No team members yet.</td></tr>'}
            </tbody>
          </table>
        </div>

        <div class="panel">
          <h2>Billing History</h2>
          <table>
            <thead>
              <tr>
                <th>Period Start</th>
                <th>Status</th>
                <th>Invoice</th>
                <th>Recorded</th>
              </tr>
            </thead>
            <tbody>
              {''.join(billing_rows) or '<tr><td colspan="4">No billing runs yet.</td></tr>'}
            </tbody>
          </table>
        </div>
	      </section>
        </div>
      </details>
    """
    return html_shell("Vicall MSP Portal", body)


def render_company_manage_page(
    *,
    msp: dict[str, Any],
    organization: dict[str, Any],
    billing_line: dict[str, Any],
    access_codes: list[dict[str, Any]],
    memberships: list[dict[str, Any]],
) -> str:
    actor = dict(msp.get("actor") or {})
    actor_role = normalize_msp_role(actor.get("role")) if actor else MSP_ROLE_OWNER
    msp_status = normalize_msp_status(msp.get("status"))
    company_settings_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="update company settings",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    create_access_code_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="issue live access codes",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_PRODUCTION_STATUS_SET,
    )
    membership_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="change employee access",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    access_code_action_restriction = portal_access_restriction(
        actor_role=actor_role,
        msp_status=msp_status,
        action="disable access codes",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    status_notice = portal_status_notice(msp_status)
    billing_exempt = bool(organization.get("billing_exempt", billing_line.get("organization_billing_exempt", False)))
    status_notice_html = (
        f"<p class=\"sub\"><strong>{escape(portal_status_label(msp_status))}:</strong> {escape(status_notice)}</p>"
        if status_notice
        else ""
    )
    access_code_rows = []
    for code in access_codes:
        max_activations = code.get("max_activations")
        active_memberships = int(code.get("active_memberships") or 0)
        remaining = (
            max(int(max_activations) - active_memberships, 0)
            if max_activations is not None
            else None
        )
        access_code_rows.append(
            f"""
            <tr>
              <td>{escape(str(code.get("label") or '-'))}<div class="muted"><code>{escape(str(code['id']))}</code></div></td>
              <td><code>••••{escape(str(code.get('code_hint') or '----'))}</code></td>
              <td>{"Active" if bool(code.get("active")) else "Disabled"}</td>
              <td>{seat_limit_label(int(max_activations)) if max_activations is not None else 'Uncapped'}</td>
              <td>{active_memberships}</td>
              <td>{remaining if remaining is not None else '—'}</td>
              <td>{escape(str(code.get('created_at') or '-'))}</td>
              <td>
                {"<form method='post' action='/portal/access-codes/deactivate'><input type='hidden' name='organization_id' value='" + escape(str(organization['id'])) + "'><input type='hidden' name='access_code_id' value='" + escape(str(code['id'])) + "'><button type='submit' style='background:var(--danger); color:#130403;'>Disable</button></form>" if bool(code.get("active")) and access_code_action_restriction is None else ("<span class='muted'>Disabled</span>" if not bool(code.get("active")) else "<span class='muted'>Restricted</span>")}
              </td>
            </tr>
            """
        )

    membership_rows = []
    for membership in memberships:
        membership_rows.append(
            f"""
            <tr>
              <td>{escape(str(membership['phone_number']))}</td>
              <td>{escape(str(membership.get('user_id') or '-'))}</td>
              <td>{escape(str(membership['status']))}</td>
              <td>{escape(str(membership.get('access_code_label') or '-'))}<div class="muted"><code>••••{escape(str(membership.get('access_code_hint') or '----'))}</code></div></td>
              <td>{escape(str(membership.get('first_verified_at') or '-'))}</td>
              <td>{escape(str(membership.get('last_verified_at') or '-'))}</td>
              <td>{escape(str(membership.get('deactivated_at') or '-'))}</td>
              <td>
                {"<form method='post' action='/portal/memberships/deactivate'><input type='hidden' name='organization_id' value='" + escape(str(organization['id'])) + "'><input type='hidden' name='phone_number' value='" + escape(str(membership['phone_number'])) + "'><input type='hidden' name='user_id' value='" + escape(str(membership.get('user_id') or '')) + "'><button type='submit' style='background:var(--danger); color:#130403;'>Remove</button></form>" if str(membership['status']) == 'active' and membership_restriction is None else ("<span class='muted'>Inactive</span>" if str(membership['status']) != 'active' else "<span class='muted'>Restricted</span>")}
              </td>
            </tr>
            """
        )

    company_settings_html = (
        f"""
          <form method="post" action="/portal/companies/update">
            <input type="hidden" name="organization_id" value="{escape(str(organization['id']))}">
            <label>External Reference
              <input name="external_ref" value="{escape(str(organization.get('external_ref') or ''))}" placeholder="PSA / CRM reference">
            </label>
            <label>Provisioned Seats
              <input name="provisioned_seats" type="number" min="1" value="{escape(str(organization.get('provisioned_seats') or ''))}" placeholder="Leave blank for uncapped">
            </label>
            <button type="submit">Save Company Settings</button>
          </form>
        """
        if company_settings_restriction is None
        else f"<p class=\"sub\">{escape(company_settings_restriction[1])}</p>"
    )
    create_access_code_html = (
        f"""
          <form method="post" action="/portal/access-codes/create">
            <input type="hidden" name="organization_id" value="{escape(str(organization['id']))}">
            <label>Label
              <input name="label" placeholder="Primary team or New hires">
            </label>
            <label>Seats On This Code
              <input name="max_activations" type="number" min="1" placeholder="Leave blank for uncapped">
            </label>
            <label>Access Code (optional)
              <input name="access_code" placeholder="Leave blank to auto-generate">
            </label>
            <button type="submit">Create Access Code</button>
          </form>
        """
        if create_access_code_restriction is None
        else f"<p class=\"sub\">{escape(create_access_code_restriction[1])}</p>"
    )

    body = f"""
      <h1>{escape(str(organization['name']))}</h1>
      <p class="sub">Manage seat allocation, onboarding codes, and signed-up phone numbers for this company under <strong>{escape(str(msp['name']))}</strong>.</p>
      {status_notice_html}

      <section class="grid">
        <div class="card"><div class="label">Provisioned Seats</div><div class="metric">{seat_limit_label(organization.get('provisioned_seats'))}</div></div>
        <div class="card"><div class="label">Billing</div><div class="metric">{'Firm' if billing_exempt else 'Billable'}</div></div>
        <div class="card"><div class="label">Active Seats</div><div class="metric">{int(organization.get('active_seats') or 0)}</div></div>
        <div class="card"><div class="label">Seats Left</div><div class="metric">{organization.get('remaining_seats') if organization.get('remaining_seats') is not None else '—'}</div></div>
        <div class="card"><div class="label">Billable Seats This Month</div><div class="metric">{int(billing_line.get('billable_seats') or 0)}</div></div>
        <div class="card"><div class="label">Billable Minutes</div><div class="metric">{int(billing_line.get('billable_minutes') or 0)}</div></div>
        <div class="card"><div class="label">Included Minutes</div><div class="metric">{int(billing_line.get('included_minutes') or 0)}</div></div>
        <div class="card"><div class="label">Overage Minutes</div><div class="metric">{int(billing_line.get('overage_minutes') or 0)}</div></div>
        <div class="card"><div class="label">Overage Amount</div><div class="metric">${int(billing_line.get('overage_amount_cents') or 0) / 100:.2f}</div></div>
        <div class="card"><div class="label">Projected Amount</div><div class="metric">${int(billing_line.get('amount_cents') or 0) / 100:.2f}</div></div>
      </section>

      <section class="two-col" style="margin-top:24px;">
        <div class="panel">
          <h2>Company Settings</h2>
          <p class="sub">Set how many seats this company is allowed to onboard. Leave blank to remove the cap.</p>
          {company_settings_html}
        </div>
        <div class="panel">
          <h2>Create Access Code</h2>
          <p class="sub">Issue a new company code and optionally reserve a specific number of seats on that code.</p>
          {create_access_code_html}
        </div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Access Codes</h2>
        <table>
          <thead>
            <tr>
              <th>Code</th>
              <th>Hint</th>
              <th>Status</th>
              <th>Seat Cap</th>
              <th>Active Seats</th>
              <th>Seats Left</th>
              <th>Created</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            {''.join(access_code_rows) or '<tr><td colspan="8">No access codes yet.</td></tr>'}
          </tbody>
        </table>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Signed-Up Numbers</h2>
        <table>
          <thead>
            <tr>
              <th>Phone</th>
              <th>User ID</th>
              <th>Status</th>
              <th>Access Code</th>
              <th>First Verified</th>
              <th>Last Verified</th>
              <th>Deactivated</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            {''.join(membership_rows) or '<tr><td colspan="8">No signed-up numbers yet.</td></tr>'}
          </tbody>
        </table>
      </section>

      <section class="links" style="margin-top:24px;">
        <a href="/portal/dashboard">Back to MSP Portal</a>
      </section>
    """
    return html_shell(f"{organization['name']} Company", body)


def render_billing_center_page(
    *,
    msp: dict[str, Any],
    actor: dict[str, Any],
    billing_readiness: dict[str, Any],
    current_snapshot: dict[str, Any],
    selected_report: dict[str, Any],
    billing_period_rows: list[dict[str, Any]],
    selected_period: str,
    can_manage_billing: bool,
) -> str:
    actor_name = actor.get("full_name") or actor.get("email") or "MSP user"
    actor_role_label = portal_role_label(actor.get("role"))
    msp_status = normalize_msp_status(msp.get("status"))
    msp_status_label = portal_status_label(msp_status)
    status_notice = portal_status_notice(msp_status)
    status_notice_html = (
        f"<p class=\"sub\"><strong>{escape(msp_status_label)}:</strong> {escape(status_notice)}</p>"
        if status_notice
        else ""
    )
    billing_run = selected_report.get("billing_run") or None
    selected_status = str((billing_run or {}).get("status") or "preview")
    selected_invoice_id = str((billing_run or {}).get("stripe_invoice_id") or "-")
    selected_invoice_url = str((billing_run or {}).get("hosted_invoice_url") or "").strip()
    selected_period_display = billing_period_label(selected_period)
    selected_period_options = []
    seen_periods: set[str] = set()
    current_period = str(current_snapshot.get("period_start") or "")
    timeline_rows: list[dict[str, Any]] = []
    if current_period:
        current_existing = control_plane.existing_billing_run(msp_id=str(msp["id"]), period_start=current_period)
        timeline_rows.append(
            {
                "period_start": current_period,
                "status": str((current_existing or {}).get("status") or "preview"),
                "stripe_invoice_id": (current_existing or {}).get("stripe_invoice_id"),
                "hosted_invoice_url": (current_existing or {}).get("hosted_invoice_url"),
                "total_billable_seats": current_snapshot.get("total_billable_seats", 0),
                "total_active_seats": current_snapshot.get("total_active_seats", 0),
                "total_call_count": current_snapshot.get("total_call_count", 0),
                "total_billable_minutes": current_snapshot.get("total_billable_minutes", 0),
                "total_overage_minutes": current_snapshot.get("total_overage_minutes", 0),
                "total_overage_amount_cents": current_snapshot.get("total_overage_amount_cents", 0),
                "total_amount_cents": current_snapshot.get("total_amount_cents", 0),
                "company_count": len(current_snapshot.get("lines", [])),
                "created_at": (current_existing or {}).get("created_at") or "-",
                "finalized_at": (current_existing or {}).get("finalized_at") or "-",
            }
        )
        seen_periods.add(current_period)
    for row in billing_period_rows:
        period = str(row.get("period_start") or "")
        if period in seen_periods:
            continue
        timeline_rows.append(dict(row))
        seen_periods.add(period)
    for row in timeline_rows:
        period = str(row.get("period_start") or "")
        selected_period_options.append(
            f'<option value="{escape(period)}" {"selected" if period == selected_period else ""}>{escape(billing_period_label(period))}</option>'
        )

    timeline_html_rows = []
    for row in timeline_rows[:18]:
        invoice_url = str(row.get("hosted_invoice_url") or "").strip()
        invoice_id = str(row.get("stripe_invoice_id") or "-")
        invoice_cell = (
            f'<a href="{escape(invoice_url)}" target="_blank" rel="noreferrer"><code>{escape(invoice_id)}</code></a>'
            if invoice_url and invoice_id != "-"
            else f"<code>{escape(invoice_id)}</code>"
        )
        timeline_html_rows.append(
            f"""
            <tr>
              <td><a href="/portal/billing?period={quote(str(row.get('period_start') or ''))}">{escape(billing_period_label(row.get('period_start')))}</a><div class="muted">{escape(str(row.get('period_start') or '-'))}</div></td>
              <td>{escape(str(row.get('status') or '-'))}</td>
              <td>{int(row.get('company_count') or 0)}</td>
              <td>{int(row.get('total_billable_seats') or 0)}</td>
              <td>{int(row.get('total_billable_minutes') or 0)}</td>
              <td>{int(row.get('total_overage_minutes') or 0)}</td>
              <td>${int(row.get('total_overage_amount_cents') or 0) / 100:.2f}</td>
              <td>${int(row.get('total_amount_cents') or 0) / 100:.2f}</td>
              <td>{invoice_cell}</td>
            </tr>
            """
        )

    company_rows = []
    company_cards = []
    usage_rows_for_period = sorted(
        list(selected_report.get("user_usage", [])),
        key=lambda row: (
            int(row.get("billable_minutes") or 0),
            int(row.get("call_count") or 0),
        ),
        reverse=True,
    )
    usage_by_company: dict[str, list[dict[str, Any]]] = {}
    for usage in usage_rows_for_period:
        organization_id = str(usage.get("organization_id") or "")
        if not organization_id:
            continue
        company_usage = usage_by_company.setdefault(organization_id, [])
        if len(company_usage) < 4:
            company_usage.append(usage)
    for line in selected_report.get("lines", [])[:50]:
        company_cards.append(
            render_company_portfolio_card(
                organization=None,
                billing_line=line,
                usage_rows=usage_by_company.get(str(line.get("organization_id") or ""), []),
            )
        )
        company_rows.append(
            f"""
            <tr>
              <td>{escape(str(line.get('organization_name') or line.get('organization_id') or '-'))}<div class="muted"><code>{escape(str(line.get('organization_id') or '-'))}</code></div></td>
              <td>{status_pill("Active" if bool(line.get("organization_active", True)) else "Offboarded", "ok" if bool(line.get("organization_active", True)) else "off")}</td>
              <td>{int(line.get('active_seats') or 0)}</td>
              <td>{int(line.get('billable_seats') or 0)}</td>
              <td>{int(line.get('invoiced_seats') or 0)}</td>
              <td>{int(line.get('unbilled_seats') or 0)}</td>
              <td>{int(line.get('call_count') or 0)}</td>
              <td>{int(line.get('billable_minutes') or 0)}</td>
              <td>{int(line.get('included_minutes') or 0)}</td>
              <td>{int(line.get('overage_minutes') or 0)}</td>
              <td>{money_label(line.get('overage_amount_cents'))}</td>
              <td>{money_label(line.get('amount_cents'))}</td>
            </tr>
            """
        )

    seat_invoice_rows = []
    for event in selected_report.get("seat_billing_events", [])[:80]:
        invoice_url = str(event.get("hosted_invoice_url") or "").strip()
        invoice_id = str(event.get("stripe_invoice_id") or "-")
        invoice_cell = (
            f'<a href="{escape(invoice_url)}" target="_blank" rel="noreferrer"><code>{escape(invoice_id)}</code></a>'
            if invoice_url and invoice_id != "-"
            else f"<code>{escape(invoice_id)}</code>"
        )
        seat_invoice_rows.append(
            f"""
            <tr>
              <td>{escape(str(event.get('organization_name') or event.get('organization_id') or '-'))}</td>
              <td>{escape(str(event.get('phone_number') or '-'))}</td>
              <td>{escape(str(event.get('status') or '-'))}</td>
              <td>${int(event.get('amount_cents') or 0) / 100:.2f}</td>
              <td>{invoice_cell}</td>
            </tr>
            """
        )

    user_rows = []
    for usage in usage_rows_for_period[:100]:
        user_rows.append(
            f"""
            <tr>
              <td>{escape(str(usage.get('organization_name') or usage.get('organization_id') or '-'))}</td>
              <td>{escape(str(usage.get('phone_number') or '-'))}</td>
              <td>{escape(str(usage.get('user_id') or '-'))}</td>
              <td>{int(usage.get('call_count') or 0)}</td>
              <td>{int(usage.get('billable_minutes') or 0)}</td>
            </tr>
            """
        )

    manage_billing_html = (
        """
          <form method="post" action="/portal/billing/manage" style="margin:0;">
            <button type="submit">Open Stripe Billing Portal</button>
          </form>
        """
        if can_manage_billing
        else '<p class="sub">Owners and billing admins can open the Stripe billing portal from here.</p>'
    )
    selected_invoice_html = (
        f'<a href="{escape(selected_invoice_url)}" target="_blank" rel="noreferrer"><code>{escape(selected_invoice_id)}</code></a>'
        if selected_invoice_url and selected_invoice_id != "-"
        else f"<code>{escape(selected_invoice_id)}</code>"
    )

    body = f"""
      <h1>{escape(str(msp['name']))} Billing Center</h1>
      <p class="sub">Signed in as <strong>{escape(str(actor_name))}</strong> · {escape(actor_role_label)}</p>
      <p class="sub"><strong>MSP status:</strong> {escape(msp_status_label)}</p>
      {status_notice_html}

      <section class="summary-strip">
        <div class="summary-card"><div class="label">Selected Period</div><div class="metric">{escape(selected_period_display)}</div><div class="muted">{escape(selected_period)}</div></div>
        <div class="summary-card"><div class="label">Companies</div><div class="metric">{count_label(len(selected_report.get('lines', [])))}</div></div>
        <div class="summary-card"><div class="label">Billable / Invoiced Seats</div><div class="metric">{count_label(selected_report.get('total_billable_seats'))} / {count_label(selected_report.get('total_invoiced_seats'))}</div></div>
        <div class="summary-card"><div class="label">Uninvoiced Seats</div><div class="metric">{count_label(selected_report.get('total_unbilled_seats'))}</div></div>
        <div class="summary-card"><div class="label">Used / Included Minutes</div><div class="metric">{count_label(selected_report.get('total_billable_minutes'))} / {count_label(selected_report.get('total_included_minutes'))}</div></div>
        <div class="summary-card"><div class="label">Overage</div><div class="metric">{count_label(selected_report.get('total_overage_minutes'))} min</div><div class="muted">{money_label(selected_report.get('total_overage_amount_cents'))}</div></div>
        <div class="summary-card primary"><div class="label">Projected / Billed</div><div class="metric">{money_label(selected_report.get('total_amount_cents'))}</div></div>
        <div class="summary-card"><div class="label">Invoice Status</div><div class="metric">{escape(selected_status)}</div></div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Billing Status</h2>
        <p class="sub"><strong>Stripe billing readiness:</strong> {escape(str(billing_readiness.get('payment_method_label') or 'Not checked'))}</p>
        <p class="sub"><strong>Invoice:</strong> {selected_invoice_html}</p>
        {manage_billing_html}
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Period Selector</h2>
        <form method="get" action="/portal/billing" style="margin:0;">
          <label>Billing Period
            <select name="period" style="width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); font:inherit; color:var(--ink); background:var(--field);">
              {''.join(selected_period_options) or '<option value="">No periods yet</option>'}
            </select>
          </label>
          <button type="submit">View Period</button>
        </form>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Invoice Timeline</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Period</th>
                <th>Status</th>
                <th>Companies</th>
                <th>Billable Seats</th>
                <th>Billable Minutes</th>
                <th>Overage Minutes</th>
                <th>Overage Amount</th>
                <th>Amount</th>
                <th>Invoice</th>
              </tr>
            </thead>
            <tbody>
              {''.join(timeline_html_rows) or '<tr><td colspan="9">No billing activity yet.</td></tr>'}
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <div class="section-head">
          <div>
            <h2>Company Billing Summary</h2>
            <p class="sub">Each company card shows seat revenue, included minutes, overage, and current catch-up amount for the selected period.</p>
          </div>
        </div>
        <div class="company-grid">
          {''.join(company_cards) or '<p class="sub">No company usage for this period yet.</p>'}
        </div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Company Rollup</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Company</th>
                <th>Status</th>
                <th>Active Seats</th>
                <th>Billable Seats</th>
                <th>Invoiced Seats</th>
                <th>Uninvoiced Seats</th>
                <th>Calls</th>
                <th>Billable Minutes</th>
                <th>Included Minutes</th>
                <th>Overage Minutes</th>
                <th>Overage Amount</th>
                <th>Amount</th>
              </tr>
            </thead>
            <tbody>
              {''.join(company_rows) or '<tr><td colspan="12">No company usage for this period yet.</td></tr>'}
            </tbody>
            <tfoot>
              <tr>
                <td colspan="2">Totals</td>
                <td>{count_label(selected_report.get('total_active_seats'))}</td>
                <td>{count_label(selected_report.get('total_billable_seats'))}</td>
                <td>{count_label(selected_report.get('total_invoiced_seats'))}</td>
                <td>{count_label(selected_report.get('total_unbilled_seats'))}</td>
                <td>{count_label(selected_report.get('total_call_count'))}</td>
                <td>{count_label(selected_report.get('total_billable_minutes'))}</td>
                <td>{count_label(selected_report.get('total_included_minutes'))}</td>
                <td>{count_label(selected_report.get('total_overage_minutes'))}</td>
                <td>{money_label(selected_report.get('total_overage_amount_cents'))}</td>
                <td>{money_label(selected_report.get('total_amount_cents'))}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Seat Invoices</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Company</th>
                <th>Phone</th>
                <th>Status</th>
                <th>Amount</th>
                <th>Invoice</th>
              </tr>
            </thead>
            <tbody>
              {''.join(seat_invoice_rows) or '<tr><td colspan="5">No immediate seat invoices for this period yet.</td></tr>'}
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>User Usage</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Company</th>
                <th>Phone</th>
                <th>User ID</th>
                <th>Calls</th>
                <th>Billable Minutes</th>
              </tr>
            </thead>
            <tbody>
              {''.join(user_rows) or '<tr><td colspan="5">No user usage for this period yet.</td></tr>'}
            </tbody>
          </table>
        </div>
      </section>

      <section class="links" style="margin-top:24px;">
        <a href="/portal/dashboard">Back to MSP Portal</a>
        <a href="/portal/audit">View Audit Log</a>
        <a href="/portal/export/usage.csv">Download Usage CSV</a>
      </section>
    """
    return html_shell("Vicall MSP Billing Center", body)


def render_audit_log_page(
    *,
    msp: dict[str, Any],
    actor: dict[str, Any],
    events: list[dict[str, Any]],
    available_actions: list[str],
    actor_query: str = "",
    organization_query: str = "",
    action_filter: str = "",
) -> str:
    actor_name = actor.get("full_name") or actor.get("email") or "MSP user"
    actor_role_label = portal_role_label(actor.get("role"))
    action_options = ['<option value="">All actions</option>']
    for action in available_actions:
        action_options.append(
            f'<option value="{escape(action)}" {"selected" if action == action_filter else ""}>{escape(action)}</option>'
        )

    event_cards = []
    for event in events:
        actor_display = (
            event.get("actor_label")
            or event.get("actor_email")
            or event.get("actor_type")
            or "unknown"
        )
        metadata = dict(event.get("event_metadata") or {})
        status = str(event.get("status") or "-")
        status_tone = (
            "ok"
            if status.lower() in {"success", "paid", "active", "completed", "ok"}
            else "off"
            if status.lower() in {"failed", "error", "denied", "inactive", "disabled"}
            else "warn"
            if status.lower() in {"warning", "pending", "skipped", "restricted"}
            else "neutral"
        )
        company_display = event.get("organization_name") or event.get("organization_id") or "-"
        target_display = event.get("target_type") or event.get("target_id") or "-"
        event_cards.append(
            f"""
            <details class="audit-card">
              <summary>
                <div class="audit-summary">
                  <div>
                    <span class="audit-label">Time</span>
                    <span class="audit-value">{escape(str(event.get('created_at') or '-'))}</span>
                  </div>
                  <div>
                    <span class="audit-label">Action</span>
                    <span class="audit-value">{escape(str(event.get('action') or '-'))}</span>
                  </div>
                  <div>
                    <span class="audit-label">Actor</span>
                    <span class="audit-value">{escape(str(actor_display))}</span>
                  </div>
                  <div>
                    <span class="audit-label">Company</span>
                    <span class="audit-value">{escape(str(company_display))}</span>
                  </div>
                  <div class="audit-status">{status_pill(status, status_tone)}</div>
                </div>
                <div class="audit-preview">{escape(audit_metadata_preview(metadata))}</div>
              </summary>
              <div class="audit-details">
                <div class="audit-detail-grid">
                  {audit_detail_html("Event ID", event.get("id"))}
                  {audit_detail_html("Target Type", event.get("target_type"))}
                  {audit_detail_html("Target ID", event.get("target_id"))}
                  {audit_detail_html("Organization ID", event.get("organization_id"))}
                  {audit_detail_html("Actor Role", event.get("actor_role") or event.get("actor_type"))}
                  {audit_detail_html("Actor Email", event.get("actor_email"))}
                  {audit_detail_html("IP Address", event.get("ip_address"))}
                  {audit_detail_html("User Agent", event.get("user_agent"))}
                </div>
                <div>
                  <h2 style="font-size:.95rem; margin-bottom:10px;">Details</h2>
                  {audit_metadata_html(metadata)}
                </div>
              </div>
            </details>
            """
        )

    body = f"""
      <h1>{escape(str(msp['name']))} Audit Log</h1>
      <p class="sub">Signed in as <strong>{escape(str(actor_name))}</strong> · {escape(actor_role_label)}</p>
      <p class="sub">Append-only event trail for sign-in, provisioning, exports, billing actions, and destructive changes.</p>

      <section class="panel" style="margin-top:24px;">
        <h2>Filters</h2>
        <form method="get" action="/portal/audit" style="margin:0;">
          <div class="two-col">
            <label>Actor
              <input name="actor" value="{escape(actor_query)}" placeholder="name, email, or role">
            </label>
            <label>Company
              <input name="company" value="{escape(organization_query)}" placeholder="company name or organization id">
            </label>
            <label>Action
              <select name="action" style="width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); font:inherit; color:var(--ink); background:var(--field);">
                {''.join(action_options)}
              </select>
            </label>
          </div>
          <button type="submit">Filter Audit Log</button>
        </form>
      </section>

      <section class="panel" style="margin-top:24px;">
        <h2>Recent Events</h2>
        <div class="audit-list">
          {''.join(event_cards) or '<p class="sub">No audit events yet.</p>'}
        </div>
      </section>

      <section class="links" style="margin-top:24px;">
        <a href="/portal/dashboard">Back to MSP Portal</a>
        <a href="/portal/billing">Open Billing Center</a>
      </section>
    """
    return html_shell("Vicall MSP Audit Log", body)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "healthy", "service": "vericall-twilio-voice"}


@app.get("/admin/storage/health")
async def admin_storage_health(
    key: str | None = None,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key or key)
    return {
        "db": control_plane.sqlite_durability_status(),
        "backup_dir": str(resolve_backup_dir()),
        "latest_successful_backup": read_latest_backup_manifest(),
    }


@app.get("/privacy", response_class=HTMLResponse)
async def privacy_policy() -> str:
    return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Vicall Privacy Policy</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.55; margin: 0; color: #17201b; background: #f7f4ec; }
    main { max-width: 760px; margin: 0 auto; padding: 48px 24px 64px; }
    h1, h2 { line-height: 1.15; }
    h1 { font-size: 2rem; margin-bottom: 0.25rem; }
    h2 { margin-top: 2rem; }
    .updated { color: #5b675f; margin-top: 0; }
  </style>
</head>
<body>
<main>
  <h1>Vicall Privacy Policy</h1>
  <p class="updated">Last updated: April 7, 2026</p>

  <p>Vicall helps users place and receive voice calls and provides on-device voice authenticity indicators during calls.</p>

  <h2>Information we collect</h2>
  <p>Vicall may collect your phone number, access-code status, device identifiers needed for calling and push notifications, call routing metadata, crash and diagnostic logs, and contacts access if you grant permission for caller identification.</p>

  <h2>Voice calls and audio</h2>
  <p>Voice calls are routed using Twilio. Vicall may process call audio on the device to produce voice authenticity indicators. We do not use call audio to train models and do not sell call audio.</p>

  <h2>How we use information</h2>
  <p>We use information to authenticate users, route calls, deliver incoming-call notifications, show caller identity, protect access to Vicall, diagnose reliability issues, and improve app safety and performance.</p>

  <h2>Sharing</h2>
  <p>We share information with service providers that are necessary to operate the app, including Twilio for voice calling and push-call delivery. We do not sell personal information.</p>

  <h2>Contacts</h2>
  <p>If you grant Contacts permission, Vicall uses contact data locally to show caller names. Contacts are not sold.</p>

  <h2>Security and retention</h2>
  <p>We use reasonable technical safeguards and retain information only as needed to operate, secure, and debug the service, unless a longer period is required by law.</p>

  <h2>Contact</h2>
  <p>For privacy questions, contact the Vicall team at the support address listed in App Store Connect.</p>
</main>
</body>
</html>
"""


@app.post("/access/validate")
async def validate_access_code(request: AccessCodeValidationRequest, raw_request: Request) -> dict[str, object]:
    code = normalize_access_code(request.code)
    if not code:
        raise HTTPException(status_code=400, detail="Missing access code")

    client_ip = raw_request.client.host if raw_request.client else "unknown"
    rate_key = f"{client_ip}:{normalize_access_code(request.phone_number)}"
    check_access_rate_limit(rate_key)

    try:
        control_plane.assert_access_code_capacity(code=code, phone_number=request.phone_number)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    context_row = control_plane.validate_access_code(code)
    valid = context_row is not None
    if context_row is not None and not bool(context_row["organization_billing_exempt"]):
        billing_readiness = await stripe_billing_readiness(context_row["stripe_customer_id"])
        if not bool(billing_readiness.get("auto_charge_ready")):
            raise HTTPException(
                status_code=402,
                detail="This MSP must add a default payment method before customer-company access can be activated.",
            )
    grant_context = control_plane.issue_access_grant(
        context_row=context_row,
        phone_number=request.phone_number,
    ) if context_row is not None else None

    if not valid:
        allowed_hashes = configured_access_code_hashes()
        if allowed_hashes:
            code_hash = sha256(code.encode("utf-8")).hexdigest()
            valid = any(compare_digest(code_hash, allowed_hash) for allowed_hash in allowed_hashes)
    logger.info(
        "[AccessCode] phone_suffix=%s valid=%s ip=%s org=%s",
        (request.phone_number or "")[-4:],
        valid,
        client_ip,
        context_row["organization_id"] if context_row is not None else "legacy",
    )
    if not valid:
        raise HTTPException(status_code=403, detail="Invalid access code")

    response: dict[str, object] = {"valid": True, "message": "Access code accepted"}
    if grant_context is not None:
        response.update(grant_context.as_response())
    return response


@app.post("/access/request-otp")
async def access_request_otp(request: AccessGrantOTPRequest) -> dict[str, object]:
    context = control_plane.grant_context(
        request.access_grant_token,
        phone_number=request.phone_number,
        consume=False,
    )
    if context is None:
        raise HTTPException(status_code=403, detail="Invalid or expired access grant")
    await require_customer_billing_ready_for_access(context)

    logger.info(
        "[AccessOTP] org=%s msp=%s phone_suffix=%s",
        context.organization_id,
        context.msp_id,
        request.phone_number[-4:],
    )
    response = await forward_main_api_json(
        "/auth/request-otp",
        {"phone_number": request.phone_number},
    )
    return response


@app.post("/access/verify-otp")
async def access_verify_otp(request: AccessGrantVerifyRequest) -> dict[str, object]:
    context = control_plane.grant_context(
        request.access_grant_token,
        phone_number=request.phone_number,
        consume=False,
    )
    if context is None:
        raise HTTPException(status_code=403, detail="Invalid or expired access grant")
    await require_customer_billing_ready_for_access(context)
    if not request.public_key or not request.public_key.strip():
        raise HTTPException(status_code=400, detail="public_key is required")

    response = await forward_main_api_json(
        "/auth/verify-otp",
        build_verify_otp_payload(
            phone_number=request.phone_number,
            otp=request.otp,
            public_key=request.public_key,
        ),
    )

    try:
        membership = control_plane.activate_membership(
            context=context,
            phone_number=request.phone_number,
            user_id=str(response.get("user_id") or "") or None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    billing_result = await invoice_membership_activation(
        membership=membership,
        organization_name=context.organization_name,
    )
    control_plane.grant_context(
        request.access_grant_token,
        phone_number=request.phone_number,
        consume=True,
    )
    response["organization_id"] = context.organization_id
    response["organization_name"] = context.organization_name
    response["msp_id"] = context.msp_id
    response["msp_name"] = context.msp_name
    response["access_code_id"] = context.access_code_id
    response["membership_id"] = membership["membership_id"]
    response["billing"] = billing_result
    return response


@app.get("/_ops/staging/otp/latest")
async def staging_smoke_latest_otp(
    phone_number: str,
    x_vicall_staging_ops_secret: str | None = Header(default=None, alias="X-Vicall-Staging-Ops-Secret"),
) -> dict[str, object]:
    ops_secret = require_staging_smoke_ops_secret(x_vicall_staging_ops_secret)
    normalized_phone_number = normalize_phone_number(phone_number)
    if not normalized_phone_number:
        raise HTTPException(status_code=400, detail="phone_number is required")
    return await fetch_staging_main_api_otp(
        phone_number=normalized_phone_number,
        ops_secret=ops_secret,
    )


async def validate_authenticated_account_deletion(access_token: str) -> None:
    # Validate the caller still has a live authenticated Vicall session.
    await forward_main_api_request(
        "/contacts/sync",
        payload={"contacts": []},
        access_token=access_token,
    )


async def execute_account_deletion_action(
    *,
    phone_number: str | None,
    user_id: str | None = None,
    identity: str | None = None,
) -> dict[str, object]:
    normalized_phone = (phone_number or "").strip()
    normalized_user_id = (user_id or "").strip() or None
    normalized_identity = (identity or "").strip()

    removed_bindings = 0
    for binding_identity in twilio_binding_identities(normalized_phone, normalized_identity):
        if device_bindings.pop(binding_identity, None) is not None:
            removed_bindings += 1
    if removed_bindings:
        save_device_bindings(device_bindings)

    deactivated = control_plane.deactivate_account_memberships(
        phone_number=normalized_phone,
        user_id=normalized_user_id,
    )
    for membership in deactivated.get("memberships", []):
        msp_id = str(membership.get("msp_id") or "")
        if not msp_id:
            continue
        record_system_audit_event(
            msp_id=msp_id,
            action="system.account.deleted_access_removed",
            target_type="membership",
            target_id=str(membership.get("id") or ""),
            organization_id=str(membership.get("organization_id") or "") or None,
            organization_name=str(membership.get("organization_name") or "") or None,
            details={
                "phone_number": membership.get("phone_number"),
                "user_id": membership.get("user_id"),
                "identity": normalized_identity or None,
                "device_bindings_removed": removed_bindings,
                "billing_note": "Seat remains billable through the current period when applicable.",
            },
        )

    logger.info(
        "[AccountDelete] phone_suffix=%s user_id=%s identity=%s memberships=%s bindings_removed=%s",
        normalized_phone[-4:] if normalized_phone else "unknown",
        normalized_user_id or "unknown",
        normalized_identity or "unknown",
        deactivated["deactivated_memberships"],
        removed_bindings,
    )
    return {
        "status": "deleted",
        "deactivated_memberships": deactivated["deactivated_memberships"],
        "organizations": deactivated["organizations"],
        "device_binding_removed": removed_bindings > 0,
        "device_bindings_removed": removed_bindings,
    }


@app.post("/account/delete/prepare")
async def prepare_account_deletion(
    request: AccountDeletionRequest,
    http_request: Request,
    authorization: str | None = Header(default=None),
) -> dict[str, object]:
    access_token = require_bearer_token(authorization)
    await validate_authenticated_account_deletion(access_token)

    issued = control_plane.issue_account_deletion_token(
        phone_number=request.phone_number,
        user_id=request.user_id,
        identity=request.identity,
    )
    return {
        "mode": account_deletion_flow_mode(),
        "deletion_token": issued["deletion_token"],
        "manage_url": account_deletion_manage_url(http_request, issued["deletion_token"]),
        "expires_at": issued["expires_at"],
        "message": (
            "Deleting your Vicall account removes your device data and active access immediately. "
            "Your MSP manages billing and can reprovision you later if needed."
        ),
    }


@app.post("/account/delete/execute")
async def execute_account_deletion(
    request: AccountDeletionExecutionRequest,
) -> dict[str, object]:
    token_row = control_plane.consume_account_deletion_token(request.deletion_token)
    if token_row is None:
        raise HTTPException(status_code=410, detail="Deletion link expired or already used")
    return await execute_account_deletion_action(
        phone_number=token_row.get("phone_number"),
        user_id=token_row.get("user_id"),
        identity=token_row.get("identity"),
    )


@app.get("/account/delete/manage", response_class=HTMLResponse)
async def account_delete_manage(
    token: str,
) -> HTMLResponse:
    token_row = control_plane.peek_account_deletion_token(token)
    if token_row is None:
        return HTMLResponse(
            render_action_result(
                title="Deletion Link Expired",
                body="This deletion link is no longer valid. Return to the Vicall app and start the delete-account flow again.",
                back_href="/privacy",
                back_label="Back to Vicall Privacy",
            ),
            status_code=410,
        )
    return HTMLResponse(
        render_account_deletion_manage(
            token=token,
            phone_number=token_row.get("phone_number"),
            expires_at=token_row.get("expires_at"),
        )
    )


@app.post("/account/delete/manage", response_class=HTMLResponse)
async def account_delete_manage_submit(
    request: Request,
) -> HTMLResponse:
    form = await request.form()
    token = str(form.get("token") or "").strip()
    if not token:
        return HTMLResponse(
            render_action_result(
                title="Delete Vicall Account",
                body="Missing deletion token. Return to the Vicall app and start the delete-account flow again.",
                back_href="/privacy",
                back_label="Back to Vicall Privacy",
            ),
            status_code=400,
        )

    token_row = control_plane.consume_account_deletion_token(token)
    if token_row is None:
        return HTMLResponse(
            render_action_result(
                title="Deletion Link Expired",
                body="This deletion link is no longer valid. Return to the Vicall app and start the delete-account flow again.",
                back_href="/privacy",
                back_label="Back to Vicall Privacy",
            ),
            status_code=410,
        )

    result = await execute_account_deletion_action(
        phone_number=token_row.get("phone_number"),
        user_id=token_row.get("user_id"),
        identity=token_row.get("identity"),
    )
    body = (
        "Your Vicall account was deleted. Device data and active access were removed immediately. "
        "Your MSP can reprovision you later if needed."
        f"<br><br><strong>Deactivated memberships:</strong> {int(result.get('deactivated_memberships') or 0)}"
    )
    return HTMLResponse(
        render_action_result(
            title="Vicall Account Deleted",
            body=body,
            back_href="/privacy",
            back_label="Back to Vicall Privacy",
        )
    )


@app.post("/account/delete")
async def delete_account(
    request: AccountDeletionRequest,
    authorization: str | None = Header(default=None),
) -> dict[str, object]:
    access_token = require_bearer_token(authorization)
    await validate_authenticated_account_deletion(access_token)
    return await execute_account_deletion_action(
        phone_number=request.phone_number,
        user_id=request.user_id,
        identity=request.identity,
    )


@app.post("/admin/msps")
async def create_msp(
    request: CreateMSPRequest,
    raw_request: Request,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        msp = control_plane.create_msp(
            name=request.name,
            billing_email=request.billing_email,
            seat_price_cents=request.seat_price_cents,
            status=request.status,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="MSP already exists or portal key conflict") from exc
    if stripe_enabled():
        try:
            customer = await create_customer(
                name=request.name,
                email=request.billing_email,
                metadata={"msp_id": msp["id"]},
            )
            control_plane.set_msp_stripe_customer(msp["id"], customer["id"])
            msp["stripe_customer_id"] = customer["id"]
        except StripeBillingError as exc:
            logger.warning("[Billing] Could not auto-create Stripe customer for MSP %s: %s", msp["id"], exc)
    if request.owner_email:
        if not request.owner_phone_number:
            raise HTTPException(status_code=400, detail="MSP owner phone number is required")
        try:
            owner_user = control_plane.create_msp_user(
                msp_id=msp["id"],
                email=request.owner_email,
                phone_number=request.owner_phone_number,
                full_name=request.owner_full_name,
                role=MSP_ROLE_OWNER,
                password=request.owner_password,
            )
            msp["owner_user_id"] = owner_user["id"]
            msp["owner_email"] = owner_user["email"]
            msp["owner_phone_number"] = owner_user.get("phone_number")
            setup_token = control_plane.issue_msp_login_token(
                msp_user_id=str(owner_user["id"]),
                purpose="password_setup",
                ttl_minutes=24 * 60,
            )
            msp["owner_setup_url"] = portal_setup_password_url(raw_request, setup_token)
            msp["owner_password_set"] = bool(request.owner_password)
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="That MSP owner email or phone is already assigned") from exc
    record_admin_audit_event(
        msp_id=str(msp["id"]),
        action="admin.msp.create",
        request=raw_request,
        target_type="msp",
        target_id=str(msp["id"]),
        details={
            "status": msp.get("status"),
            "billing_email": msp.get("billing_email"),
            "owner_email": msp.get("owner_email"),
        },
    )
    return msp


@app.post("/admin/organizations")
async def create_organization(
    request: CreateOrganizationRequest,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        return control_plane.create_organization(
            msp_id=request.msp_id,
            name=request.name,
            external_ref=request.external_ref,
        )
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Organization could not be created") from exc


@app.post("/admin/organizations/deactivate")
async def deactivate_organization(
    request: DeactivateOrganizationRequest,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        context = control_plane.organization_context(organization_id=request.organization_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    try:
        return control_plane.deactivate_organization_for_msp(
            msp_id=context.msp_id,
            organization_id=request.organization_id,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/admin/access-codes")
async def create_access_code(
    request: CreateAccessCodeRequest,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        return control_plane.create_access_code(
            organization_id=request.organization_id,
            code=request.code,
            label=request.label,
            max_activations=request.max_activations,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="That access code is already assigned") from exc


@app.post("/admin/msps/status")
async def update_msp_status(
    request: UpdateMSPStatusRequest,
    raw_request: Request,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        result = control_plane.set_msp_status(msp_id=request.msp_id, status=request.status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    record_admin_audit_event(
        msp_id=str(result["id"]),
        action="admin.msp.status_updated",
        request=raw_request,
        target_type="msp",
        target_id=str(result["id"]),
        details={"status": result.get("status")},
    )
    return result


@app.post("/admin/provision-msp", response_class=HTMLResponse)
async def admin_provision_msp(request: Request, key: str | None = None) -> str:
    require_admin_key(key)
    form = await request.form()
    msp_name = (form.get("msp_name") or "").strip()
    billing_email = (form.get("billing_email") or "").strip() or None
    owner_full_name = (form.get("owner_full_name") or "").strip() or None
    owner_email = (form.get("owner_email") or "").strip().lower() or None
    owner_phone_number = (form.get("owner_phone_number") or "").strip() or None
    owner_password = (form.get("owner_password") or "").strip() or None
    company_name = (form.get("company_name") or "").strip()
    external_ref = (form.get("external_ref") or "").strip() or None
    requested_code = normalize_access_code(form.get("access_code"))
    seat_price_cents = int(str(form.get("seat_price_cents") or str(DEFAULT_MSP_SEAT_PRICE_CENTS)))
    msp_status = (form.get("msp_status") or MSP_STATUS_ACTIVE).strip() or MSP_STATUS_ACTIVE

    if not msp_name or not company_name:
        raise HTTPException(status_code=400, detail="MSP name and company name are required")

    try:
        msp = control_plane.create_msp(
            name=msp_name,
            billing_email=billing_email,
            seat_price_cents=seat_price_cents,
            status=msp_status,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="MSP already exists or portal key conflict") from exc

    if stripe_enabled():
        try:
            customer = await create_customer(
                name=msp_name,
                email=billing_email,
                metadata={"msp_id": msp["id"]},
            )
            control_plane.set_msp_stripe_customer(msp["id"], customer["id"])
            msp["stripe_customer_id"] = customer["id"]
        except StripeBillingError as exc:
            logger.warning("[Billing] Could not auto-create Stripe customer for MSP %s: %s", msp["id"], exc)

    organization = control_plane.create_organization(
        msp_id=msp["id"],
        name=company_name,
        external_ref=external_ref,
        billing_exempt=True,
    )
    access_code = requested_code or make_access_code(company_name)
    access_code_row = control_plane.create_access_code(
        organization_id=organization["id"],
        code=access_code,
        label=f"{company_name} primary code",
    )

    owner_setup_html = ""
    if owner_email:
        if not owner_phone_number:
            raise HTTPException(status_code=400, detail="Portal owner phone number is required")
        try:
            owner_user = control_plane.create_msp_user(
                msp_id=msp["id"],
                email=owner_email,
                phone_number=owner_phone_number,
                full_name=owner_full_name,
                role=MSP_ROLE_OWNER,
                password=owner_password,
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="That portal owner email or phone is already assigned to another MSP") from exc
        setup_token = control_plane.issue_msp_login_token(
            msp_user_id=str(owner_user["id"]),
            purpose="password_setup",
            ttl_minutes=24 * 60,
        )
        setup_url = portal_setup_password_url(request, setup_token)
        password_note = (
            "An initial password was set from the submitted form and is not displayed here."
            if owner_password
            else "No password was displayed or generated; use the one-time setup link to set it."
        )

        owner_setup_html = f"""
          <p><strong>Portal Owner Setup:</strong><br>
          Email: <code>{escape(owner_email)}</code><br>
          Phone: <code>{escape(owner_phone_number or '-')}</code><br>
          Setup Link: <a href="{escape(setup_url)}">{escape(setup_url)}</a></p>
          <p>{escape(password_note)} The setup link is one-time use and expires in 24 hours.</p>
          <p>The MSP signs in at <a href="/portal/login">/portal/login</a> after setting a password, then confirms their phone number and SMS passcode.</p>
        """

    record_admin_audit_event(
        msp_id=str(msp["id"]),
        action="admin.msp.provisioned",
        request=request,
        target_type="msp",
        target_id=str(msp["id"]),
        organization_id=str(organization["id"]),
        organization_name=str(organization["name"]),
        details={
            "status": msp.get("status"),
            "owner_email": owner_email,
            "stripe_customer_id": msp.get("stripe_customer_id"),
            "billing_exempt": organization.get("billing_exempt"),
            "access_code_id": access_code_row["id"],
        },
    )

    return render_action_result(
        title="MSP Provisioned",
        body=f"""
          <p><strong>MSP:</strong> {escape(msp_name)}<br>
          <strong>MSP ID:</strong> <code>{escape(msp['id'])}</code><br>
          <strong>MSP Status:</strong> {escape(portal_status_label(msp.get('status')))}<br>
          <strong>Portal Access:</strong> Vicall-managed recovery only</p>
          <p><strong>Company:</strong> {escape(company_name)}<br>
          <strong>Organization ID:</strong> <code>{escape(organization['id'])}</code><br>
          <strong>Billing:</strong> Non-billable MSP firm<br>
          <strong>Access Code:</strong> <code>{escape(access_code)}</code><br>
          <strong>Access Code ID:</strong> <code>{escape(access_code_row['id'])}</code></p>
          <p><strong>Stripe Customer:</strong> {escape(str(msp.get('stripe_customer_id') or 'not attached'))}</p>
          {owner_setup_html}
        """,
        back_href=f"/admin/dashboard?key={quote(key or '')}",
        back_label="Back to Admin Dashboard",
    )


@app.get("/admin/overview")
async def admin_overview(x_admin_key: str | None = Header(default=None)) -> dict[str, object]:
    require_admin_key(x_admin_key)
    return control_plane.admin_overview()


@app.post("/admin/memberships/activate")
async def admin_activate_membership(
    request: ActivateMembershipRequest,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        context = control_plane.organization_context(
            organization_id=request.organization_id,
            access_code_id=request.access_code_id,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    try:
        membership = control_plane.activate_membership(
            context=context,
            phone_number=request.phone_number,
            user_id=request.user_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {
        "membership": membership,
        "organization_name": context.organization_name,
        "msp_id": context.msp_id,
        "msp_name": context.msp_name,
    }


@app.get("/admin/dashboard", response_class=HTMLResponse)
async def admin_dashboard(key: str | None = None) -> str:
    require_admin_key(key)
    return render_admin_dashboard(control_plane.admin_overview(), key or "")


@app.get("/admin/msps/{msp_id}")
async def admin_msp_summary(
    msp_id: str,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        summary = control_plane.msp_summary(msp_id)
        summary["current_billing_snapshot"] = control_plane.billing_snapshot(
            msp_id=msp_id,
            period_start_value=month_start(datetime.now(timezone.utc)),
        )
        return summary
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/admin/msps/{msp_id}/export/companies.csv")
async def admin_export_companies_csv(
    msp_id: str,
    x_admin_key: str | None = Header(default=None),
) -> Response:
    require_admin_key(x_admin_key)
    rows = control_plane.organization_rows_for_msp(msp_id)
    return csv_response(
        filename=f"{msp_id}-companies.csv",
        rows=rows,
        fieldnames=["id", "name", "external_ref", "active", "active_seats", "inactive_seats", "last_verified_at"],
    )


@app.get("/admin/msps/{msp_id}/export/users.csv")
async def admin_export_users_csv(
    msp_id: str,
    x_admin_key: str | None = Header(default=None),
) -> Response:
    require_admin_key(x_admin_key)
    rows = control_plane.membership_rows_for_msp(msp_id)
    return csv_response(
        filename=f"{msp_id}-users.csv",
        rows=rows,
        fieldnames=[
            "id",
            "organization_id",
            "organization_name",
            "phone_number",
            "user_id",
            "status",
            "first_verified_at",
            "last_verified_at",
            "deactivated_at",
        ],
    )


@app.get("/admin/msps/{msp_id}/export/usage.csv")
async def admin_export_usage_csv(
    msp_id: str,
    x_admin_key: str | None = Header(default=None),
) -> Response:
    require_admin_key(x_admin_key)
    rollup = control_plane.refresh_monthly_usage_snapshots(
        msp_id=msp_id,
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    return csv_response(
        filename=f"{msp_id}-usage.csv",
        rows=rollup["users"],
        fieldnames=[
            "period_start",
            "organization_id",
            "organization_name",
            "membership_id",
            "phone_number",
            "user_id",
            "call_count",
            "billable_seconds",
            "billable_minutes",
        ],
    )


@app.get("/admin/msps/{msp_id}/billing/preview")
async def admin_billing_preview(
    msp_id: str,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    try:
        return control_plane.billing_snapshot(
            msp_id=msp_id,
            period_start_value=month_start(datetime.now(timezone.utc)),
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/admin/msps/{msp_id}/stripe/customer")
async def admin_sync_stripe_customer(
    msp_id: str,
    request: Request,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    msp = control_plane.get_msp(msp_id)
    if msp is None:
        raise HTTPException(status_code=404, detail="MSP not found")
    if msp["stripe_customer_id"]:
        return {
            "msp_id": msp_id,
            "stripe_customer_id": msp["stripe_customer_id"],
            "message": "Stripe customer already attached",
        }
    if not stripe_enabled():
        raise HTTPException(status_code=503, detail="Stripe is not configured")
    try:
        customer = await create_customer(
            name=msp["name"],
            email=msp["billing_email"],
            metadata={"msp_id": msp_id},
        )
    except StripeBillingError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    control_plane.set_msp_stripe_customer(msp_id, customer["id"])
    record_admin_audit_event(
        msp_id=msp_id,
        action="admin.msp.stripe_customer_attached",
        request=request,
        target_type="stripe_customer",
        target_id=str(customer["id"]),
        details={"msp_id": msp_id},
    )
    return {
        "msp_id": msp_id,
        "stripe_customer_id": customer["id"],
    }


@app.post("/admin/msps/{msp_id}/billing/run")
async def admin_run_billing(
    msp_id: str,
    request: Request,
    period_start: str | None = None,
    x_admin_key: str | None = Header(default=None),
) -> dict[str, object]:
    require_admin_key(x_admin_key)
    billing_period = parse_billing_period_start(period_start)
    try:
        result = await run_monthly_billing_for_msp(msp_id, period_start_value=billing_period)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    if result["status"] == "skipped_missing_customer":
        raise HTTPException(status_code=400, detail="MSP does not have a Stripe customer")
    if result["status"] == "skipped_missing_payment_method":
        raise HTTPException(status_code=402, detail="MSP does not have a default Stripe payment method")
    if result["status"] == "failed":
        raise HTTPException(status_code=502, detail=str(result["error"])) from None
    record_admin_audit_event(
        msp_id=msp_id,
        action="admin.billing.run",
        request=request,
        target_type="billing_run",
        target_id=str(result.get("billing_run", {}).get("id") or result.get("invoice_id") or result.get("status")),
        details={
            "status": result.get("status"),
            "invoice_id": result.get("invoice_id"),
            "period_start": result.get("snapshot", {}).get("period_start"),
        },
    )
    return result


@app.post("/admin/billing/run-all", response_class=HTMLResponse)
async def admin_run_all_billing(request: Request, key: str | None = None) -> str:
    require_admin_key(key)
    period_start_raw = (request.query_params.get("period_start") or "").strip()
    content_type = request.headers.get("content-type") or ""
    if request.method == "POST" and "application/x-www-form-urlencoded" in content_type:
        form = await request.form()
        period_start_raw = period_start_raw or (form.get("period_start") or "").strip()
    billing_period = parse_billing_period_start(period_start_raw)
    period_label = isoformat(billing_period)
    results = await run_monthly_billing_for_all_msps(period_start_value=billing_period)

    rows = []
    for result in results:
        snapshot = result.get("snapshot", {})
        if str(result.get("msp_id") or ""):
            record_admin_audit_event(
                msp_id=str(result["msp_id"]),
                action="admin.billing.run_all",
                request=request,
                target_type="billing_run",
                target_id=str(result.get("billing_run", {}).get("id") or result.get("invoice_id") or result.get("status")),
                details={
                    "status": result.get("status"),
                    "invoice_id": result.get("invoice_id"),
                    "period_start": snapshot.get("period_start"),
                },
            )
        rows.append(
            f"""
            <tr>
              <td><code>{escape(str(result['msp_id']))}</code></td>
              <td>{escape(str(snapshot.get('msp_name') or '-'))}</td>
              <td>{escape(str(snapshot.get('period_start') or period_label))}</td>
              <td>{escape(str(result['status']))}</td>
              <td>{int(snapshot.get('total_billable_seats') or 0)}</td>
              <td>${int(snapshot.get('total_amount_cents') or 0) / 100:.2f}</td>
            </tr>
            """
        )

    return render_action_result(
        title="Monthly Billing Run Complete",
        body=f"""
          <p>Processed <strong>{len(results)}</strong> MSPs for billing period <code>{escape(period_label)}</code>.</p>
          <table>
            <thead>
              <tr>
                <th>MSP ID</th>
                <th>MSP</th>
                <th>Period</th>
                <th>Status</th>
                <th>Billable Seats</th>
                <th>Amount</th>
              </tr>
            </thead>
            <tbody>
              {''.join(rows) or '<tr><td colspan="6">No MSPs found.</td></tr>'}
            </tbody>
          </table>
        """,
        back_href=f"/admin/dashboard?key={quote(key or '')}",
        back_label="Back to Admin Dashboard",
    )


@app.get("/portal/summary")
async def portal_summary(request: Request, x_msp_key: str | None = Header(default=None)) -> dict[str, object]:
    msp, _ = require_portal_request(request, header_portal_key=x_msp_key)
    summary = portal_summary_for_dashboard(msp_id=msp["id"])
    summary["billing_readiness"] = await stripe_billing_readiness(summary["msp"].get("stripe_customer_id"))
    return summary


@app.get("/portal", response_class=HTMLResponse)
async def portal_root(request: Request) -> Response:
    if portal_session_from_request(request):
        session = control_plane.get_msp_session(portal_session_from_request(request) or "")
        if session is not None:
            return RedirectResponse("/portal/dashboard", status_code=303)
    return RedirectResponse("/portal/login", status_code=303)


@app.get("/portal/signup", response_class=HTMLResponse)
async def portal_signup_page(request: Request) -> Response:
    session_token = portal_session_from_request(request)
    if session_token and control_plane.get_msp_session(session_token):
        return RedirectResponse("/portal/dashboard", status_code=303)
    return HTMLResponse(render_portal_signup())


@app.post("/portal/signup", response_class=HTMLResponse)
async def portal_signup(request: Request) -> Response:
    return HTMLResponse(render_portal_signup(), status_code=403)


@app.get("/portal/setup-password", response_class=HTMLResponse)
async def portal_setup_password_page(token: str | None = None) -> Response:
    raw_token = (token or "").strip()
    context = control_plane.get_msp_login_token(raw_token, purpose="password_setup") if raw_token else None
    if context is None:
        return HTMLResponse(
            render_action_result(
                title="Setup Link Expired",
                body="This password setup link is no longer valid. Ask Vicall or your MSP owner to issue a new setup link.",
                back_href="/portal/login",
                back_label="Back to MSP Login",
            ),
            status_code=410,
        )
    return HTMLResponse(
        render_portal_password_setup(
            token=raw_token,
            email=str(context["email"]),
            msp_name=str(context["msp_name"]),
        )
    )


@app.post("/portal/setup-password", response_class=HTMLResponse)
async def portal_setup_password_submit(request: Request) -> Response:
    form = await request.form()
    raw_token = (form.get("token") or "").strip()
    password = (form.get("password") or "").strip()
    password_confirm = (form.get("password_confirm") or "").strip()
    context = control_plane.get_msp_login_token(raw_token, purpose="password_setup") if raw_token else None
    if context is None:
        return HTMLResponse(
            render_action_result(
                title="Setup Link Expired",
                body="This password setup link is no longer valid. Ask Vicall or your MSP owner to issue a new setup link.",
                back_href="/portal/login",
                back_label="Back to MSP Login",
            ),
            status_code=410,
        )
    if password != password_confirm:
        return HTMLResponse(
            render_portal_password_setup(
                token=raw_token,
                email=str(context["email"]),
                msp_name=str(context["msp_name"]),
                error="Those passwords did not match.",
            ),
            status_code=400,
        )
    min_length = max(int(os.getenv("MSP_PASSWORD_MIN_LENGTH", "10")), 1)
    if len(password) < min_length:
        return HTMLResponse(
            render_portal_password_setup(
                token=raw_token,
                email=str(context["email"]),
                msp_name=str(context["msp_name"]),
                error=f"Password must be at least {min_length} characters.",
            ),
            status_code=400,
        )
    consumed = control_plane.consume_msp_login_token(raw_token, purpose="password_setup")
    if consumed is None:
        return HTMLResponse(
            render_action_result(
                title="Setup Link Expired",
                body="This password setup link was already used or expired. Ask Vicall or your MSP owner to issue a new setup link.",
                back_href="/portal/login",
                back_label="Back to MSP Login",
            ),
            status_code=410,
        )
    try:
        control_plane.set_msp_user_password(msp_user_id=str(consumed["msp_user_id"]), password=password)
    except ValueError as exc:
        return HTMLResponse(
            render_portal_password_setup(
                token=raw_token,
                email=str(context["email"]),
                msp_name=str(context["msp_name"]),
                error=str(exc),
            ),
            status_code=400,
        )
    record_msp_audit_event(
        msp_id=str(consumed["msp_id"]),
        action="portal.password_setup.completed",
        actor=dict(consumed),
        request=request,
        target_type="msp_user",
        target_id=str(consumed["msp_user_id"]),
    )
    return HTMLResponse(
        render_action_result(
            title="Portal Password Ready",
            body=f"""
              <p><strong>{escape(str(consumed['email']))}</strong> can now sign in with email, password, phone confirmation, and SMS code.</p>
            """,
            back_href="/portal/login",
            back_label="Back to MSP Login",
        )
    )


def portal_password_user(email: str, password: str):
    normalized_email = (email or "").strip().lower()
    normalized_password = password or ""
    if not normalized_email or not normalized_password:
        return None
    return control_plane.authenticate_msp_user(email=normalized_email, password=normalized_password)


def portal_password_and_phone_user(email: str, phone_number: str, password: str):
    user = portal_password_user(email, password)
    if user is None:
        return None
    if normalize_phone_number(phone_number) != normalize_phone_number(user["phone_number"]):
        return None
    return user


def portal_login_challenge_context(request: Request):
    challenge_token = portal_login_challenge_from_request(request)
    if not challenge_token:
        return None, None
    return challenge_token, control_plane.get_msp_login_challenge(challenge_token)


@app.get("/portal/login", response_class=HTMLResponse)
async def portal_login_page(request: Request) -> Response:
    session_token = portal_session_from_request(request)
    if session_token and control_plane.get_msp_session(session_token):
        return RedirectResponse("/portal/dashboard", status_code=303)
    response = HTMLResponse(
        render_portal_login(
            error=(request.query_params.get("error") or "").strip() or None,
            notice=(request.query_params.get("notice") or "").strip() or None,
            login_email=(request.query_params.get("email") or "").strip() or None,
        )
    )
    if portal_login_challenge_from_request(request):
        clear_portal_login_challenge_cookie(response)
    return response


@app.post("/portal/login")
async def portal_login(request: Request) -> Response:
    form = await request.form()
    email = (form.get("email") or "").strip().lower()
    password = (form.get("password") or "")
    if not email or not password:
        return HTMLResponse(
            render_portal_login(error="Enter your MSP email and password."),
            status_code=400,
        )
    user = portal_password_user(email, password)
    if user is None:
        return HTMLResponse(
            render_portal_login(
                error="That email or password was not recognized.",
                login_email=email,
            ),
            status_code=401,
        )
    if not normalize_phone_number(user["phone_number"]):
        return HTMLResponse(
            render_portal_login(
                error="This MSP account does not have a mobile number on file yet. Vicall can add one and re-enable sign-in.",
                login_email=email,
            ),
            status_code=409,
        )
    client_ip, user_agent = portal_request_metadata(request)
    challenge_token = control_plane.create_msp_login_challenge(
        msp_user_id=str(user["id"]),
        ip_address=client_ip,
        user_agent=user_agent,
        ttl_minutes=PORTAL_LOGIN_CHALLENGE_TTL_MINUTES,
    )
    response = RedirectResponse("/portal/login/phone", status_code=303)
    apply_portal_login_challenge_cookie(response, challenge_token)
    return response


@app.get("/portal/login/phone", response_class=HTMLResponse)
async def portal_login_phone_page(request: Request) -> Response:
    session_token = portal_session_from_request(request)
    if session_token and control_plane.get_msp_session(session_token):
        return RedirectResponse("/portal/dashboard", status_code=303)
    challenge_token, challenge = portal_login_challenge_context(request)
    if not challenge_token or challenge is None:
        return RedirectResponse(
            "/portal/login?error=Your+sign-in+session+expired.+Enter+your+email+and+password+again.",
            status_code=303,
        )
    if not normalize_phone_number(challenge["user_phone_number"]):
        response = HTMLResponse(
            render_portal_login(
                error="This MSP account does not have a mobile number on file yet. Vicall can add one and re-enable sign-in.",
                login_email=str(challenge["email"]),
            ),
            status_code=409,
        )
        clear_portal_login_challenge_cookie(response)
        return response
    return HTMLResponse(
        render_portal_phone_step(
            email=str(challenge["email"]),
            stored_phone_number=str(challenge["user_phone_number"] or "") or None,
            entered_phone_number=(request.query_params.get("phone") or "").strip() or None,
            error=(request.query_params.get("error") or "").strip() or None,
            notice=(request.query_params.get("notice") or "").strip() or None,
        )
    )


@app.post("/portal/login/phone")
async def portal_login_phone_submit(request: Request) -> Response:
    challenge_token, challenge = portal_login_challenge_context(request)
    if not challenge_token or challenge is None:
        return RedirectResponse(
            "/portal/login?error=Your+sign-in+session+expired.+Enter+your+email+and+password+again.",
            status_code=303,
        )
    if portal_login_challenge_is_locked(challenge):
        control_plane.consume_msp_login_challenge(challenge_token)
        return portal_restart_login_response(
            message=PORTAL_LOGIN_LOCKOUT_MESSAGE,
            email=str(challenge["email"]),
        )

    phone_number = normalize_phone_number((await request.form()).get("phone_number"))
    if not phone_number:
        return HTMLResponse(
            render_portal_phone_step(
                email=str(challenge["email"]),
                stored_phone_number=str(challenge["user_phone_number"] or "") or None,
                error="Enter the mobile number on file for this MSP account.",
            ),
            status_code=400,
        )

    if phone_number != normalize_phone_number(challenge["user_phone_number"]):
        control_plane.increment_msp_login_challenge_attempts(challenge_token)
        updated_challenge = control_plane.get_msp_login_challenge(challenge_token)
        if portal_login_challenge_is_locked(updated_challenge):
            control_plane.consume_msp_login_challenge(challenge_token)
            return portal_restart_login_response(
                message=PORTAL_LOGIN_LOCKOUT_MESSAGE,
                email=str(challenge["email"]),
            )
        return HTMLResponse(
            render_portal_phone_step(
                email=str(challenge["email"]),
                stored_phone_number=str(challenge["user_phone_number"] or "") or None,
                entered_phone_number=phone_number,
                error="That mobile number does not match the one on file for this MSP account.",
            ),
            status_code=401,
        )

    cooldown_remaining = portal_login_sms_cooldown_remaining(challenge)
    if cooldown_remaining:
        return HTMLResponse(
            render_portal_phone_step(
                email=str(challenge["email"]),
                stored_phone_number=str(challenge["user_phone_number"] or "") or None,
                entered_phone_number=phone_number,
                error=f"Please wait {cooldown_remaining} seconds before requesting another SMS code.",
            ),
            status_code=429,
        )

    try:
        await forward_main_api_json("/auth/request-otp", {"phone_number": phone_number})
    except HTTPException as exc:
        return HTMLResponse(
            render_portal_phone_step(
                email=str(challenge["email"]),
                stored_phone_number=str(challenge["user_phone_number"] or "") or None,
                entered_phone_number=phone_number,
                error=str(exc.detail),
            ),
            status_code=exc.status_code,
        )

    control_plane.set_msp_login_challenge_phone(raw_token=challenge_token, phone_number=phone_number)
    response = RedirectResponse("/portal/login/code?notice=We+sent+your+one-time+code.", status_code=303)
    apply_portal_login_challenge_cookie(response, challenge_token)
    return response


@app.get("/portal/login/code", response_class=HTMLResponse)
async def portal_login_code_page(request: Request) -> Response:
    session_token = portal_session_from_request(request)
    if session_token and control_plane.get_msp_session(session_token):
        return RedirectResponse("/portal/dashboard", status_code=303)
    challenge_token, challenge = portal_login_challenge_context(request)
    if not challenge_token or challenge is None:
        return RedirectResponse(
            "/portal/login?error=Your+sign-in+session+expired.+Enter+your+email+and+password+again.",
            status_code=303,
        )
    if portal_login_challenge_is_locked(challenge):
        control_plane.consume_msp_login_challenge(challenge_token)
        return portal_restart_login_response(
            message=PORTAL_LOGIN_LOCKOUT_MESSAGE,
            email=str(challenge["email"]),
        )
    phone_number = normalize_phone_number(challenge["challenge_phone_number"])
    if not phone_number:
        return RedirectResponse(
            "/portal/login/phone?notice=Confirm+your+mobile+number+to+receive+an+SMS+code.",
            status_code=303,
        )
    return HTMLResponse(
        render_portal_code_step(
            email=str(challenge["email"]),
            phone_number=phone_number,
            error=(request.query_params.get("error") or "").strip() or None,
            notice=(request.query_params.get("notice") or "").strip() or None,
        )
    )


@app.post("/portal/login/code")
async def portal_login_code_submit(request: Request) -> Response:
    challenge_token, challenge = portal_login_challenge_context(request)
    if not challenge_token or challenge is None:
        return RedirectResponse(
            "/portal/login?error=Your+sign-in+session+expired.+Enter+your+email+and+password+again.",
            status_code=303,
        )
    if portal_login_challenge_is_locked(challenge):
        control_plane.consume_msp_login_challenge(challenge_token)
        return portal_restart_login_response(
            message=PORTAL_LOGIN_LOCKOUT_MESSAGE,
            email=str(challenge["email"]),
        )
    phone_number = normalize_phone_number(challenge["challenge_phone_number"])
    if not phone_number:
        return RedirectResponse(
            "/portal/login/phone?notice=Confirm+your+mobile+number+to+receive+an+SMS+code.",
            status_code=303,
        )
    form = await request.form()
    otp = (form.get("otp") or "").strip()
    if not otp:
        return HTMLResponse(
            render_portal_code_step(
                email=str(challenge["email"]),
                phone_number=phone_number,
                error="Enter the six-digit code we texted to your phone.",
            ),
            status_code=400,
        )
    try:
        await forward_main_api_json(
            "/auth/check-otp",
            {
                "phone_number": phone_number,
                "otp": otp,
            },
        )
    except HTTPException as exc:
        control_plane.increment_msp_login_challenge_attempts(challenge_token)
        updated_challenge = control_plane.get_msp_login_challenge(challenge_token)
        if portal_login_challenge_is_locked(updated_challenge):
            control_plane.consume_msp_login_challenge(challenge_token)
            return portal_restart_login_response(
                message=PORTAL_LOGIN_LOCKOUT_MESSAGE,
                email=str(challenge["email"]),
            )
        return HTMLResponse(
            render_portal_code_step(
                email=str(challenge["email"]),
                phone_number=phone_number,
                error=str(exc.detail),
            ),
            status_code=exc.status_code,
        )

    control_plane.consume_msp_login_challenge(challenge_token)
    session = control_plane.create_msp_session(msp_user_id=str(challenge["msp_user_id"]))
    record_msp_audit_event(
        msp_id=session.msp_id,
        action="portal.login.success.sms",
        actor=session.as_msp_row(),
        request=request,
        target_type="portal_session",
        target_id=session.session_id,
        details={"email": session.email},
    )
    response = RedirectResponse("/portal/dashboard", status_code=303)
    apply_portal_session_cookie(response, session.session_token)
    clear_portal_login_challenge_cookie(response)
    return response


@app.post("/portal/login/sms/request")
async def portal_login_sms_request(request: Request) -> Response:
    return RedirectResponse(
        "/portal/login?notice=Use+the+standard+MSP+sign-in+flow+to+continue.",
        status_code=303,
    )


@app.post("/portal/login/sms/verify")
async def portal_login_sms_verify(request: Request) -> Response:
    return RedirectResponse(
        "/portal/login?notice=Use+the+standard+MSP+sign-in+flow+to+continue.",
        status_code=303,
    )


@app.post("/portal/login/key")
async def portal_login_with_key(request: Request) -> Response:
    return HTMLResponse(
        render_portal_login(
            error="Shared portal-key sign-in has been retired. Contact Vicall to reset access and continue with the normal MSP login flow.",
        ),
        status_code=403,
    )


@app.post("/portal/bootstrap")
async def portal_bootstrap(request: Request) -> Response:
    form = await request.form()
    email = (form.get("email") or "").strip().lower() or None
    return HTMLResponse(
        render_portal_login(
            error="Direct MSP self-claim is disabled. Contact Vicall to provision or recover portal access.",
            login_email=email,
        ),
        status_code=403,
    )


@app.post("/portal/login/request", response_class=HTMLResponse)
async def portal_login_request(request: Request) -> str:
    form = await request.form()
    email = (form.get("email") or "").strip().lower()
    if not email:
        return render_portal_login(error="Enter your MSP work email to continue.")
    user = control_plane.get_msp_user_by_email(email)
    if user is None:
        return render_portal_login(
            error="That email is not attached to an MSP portal account yet.",
            login_email=email,
        )

    token = control_plane.issue_msp_login_token(msp_user_id=str(user["id"]))
    record_msp_audit_event(
        msp_id=str(user["msp_id"]),
        action="portal.login.link_requested",
        actor={
            "msp_user_id": user["id"],
            "email": user["email"],
            "role": user["role"],
            "full_name": user["full_name"],
        },
        request=request,
        target_type="msp_login_token",
        target_id=str(user["id"]),
        details={"delivery_method": "email" if email_enabled() else "disabled"},
    )
    if email_enabled():
        try:
            await send_portal_login_email(
                request=request,
                to_email=email,
                msp_name=str(user["msp_name"]),
                full_name=user["full_name"],
                token=token,
            )
            return render_action_result(
                title="Check Your Email",
                body=f"""
                  <p>We sent a secure sign-in link to <strong>{escape(email)}</strong>.</p>
                  <p>The link expires in 20 minutes and signs the MSP user into <strong>{escape(str(user['msp_name']))}</strong>.</p>
                """,
                back_href="/portal/login",
                back_label="Back to MSP Login",
            )
        except EmailDeliveryError as exc:
            return render_action_result(
                title="Sign-In Link Unavailable",
                body=f"""
                  <p>We could not send the sign-in link to <strong>{escape(email)}</strong>.</p>
                  <p>{escape(str(exc))}</p>
                  <p>Use the standard MSP email, password, phone confirmation, and SMS sign-in flow while Vicall restores mail delivery.</p>
                """,
                back_href="/portal/login",
                back_label="Back to MSP Login",
            )

    return render_action_result(
        title="Sign-In Link Unavailable",
        body=f"""
          <p>Email delivery is not configured on this deployment yet.</p>
          <p>Use the standard MSP email, password, phone confirmation, and SMS sign-in flow instead of emailed sign-in links.</p>
        """,
        back_href="/portal/login",
        back_label="Back to MSP Login",
    )


@app.get("/portal/login/verify")
async def portal_login_verify(token: str) -> Response:
    login_context = control_plane.consume_msp_login_token(token)
    if login_context is None:
        return RedirectResponse("/portal/login?error=That+sign-in+link+is+invalid+or+expired.", status_code=303)
    session = control_plane.create_msp_session(msp_user_id=str(login_context["msp_user_id"]))
    record_msp_audit_event(
        msp_id=session.msp_id,
        action="portal.login.success.magic_link",
        actor=session.as_msp_row(),
        target_type="portal_session",
        target_id=session.session_id,
        details={"email": session.email},
    )
    response = RedirectResponse("/portal/dashboard", status_code=303)
    apply_portal_session_cookie(response, session.session_token)
    clear_portal_login_challenge_cookie(response)
    return response


@app.post("/portal/logout")
async def portal_logout(request: Request) -> Response:
    session_token = portal_session_from_request(request)
    if session_token:
        session = control_plane.get_msp_session(session_token)
        if session is not None:
            record_msp_audit_event(
                msp_id=session.msp_id,
                action="portal.logout",
                actor=session.as_msp_row(),
                request=request,
                target_type="portal_session",
                target_id=session.session_id,
            )
        control_plane.revoke_msp_session(session_token)
    response = RedirectResponse("/portal/login", status_code=303)
    response.delete_cookie(PORTAL_SESSION_COOKIE, path="/")
    clear_portal_login_challenge_cookie(response)
    return response


@app.get("/portal/dashboard", response_class=HTMLResponse)
async def portal_dashboard(
    request: Request,
    key: str | None = None,
    q: str | None = None,
    status: str = "all",
    page: int = 1,
) -> Response:
    try:
        msp, session = require_portal_request(request, portal_key=key)
    except HTTPException:
        return RedirectResponse("/portal/login", status_code=303)

    summary = portal_summary_for_dashboard(
        msp_id=str(msp["id"]),
        company_query=(q or "").strip(),
        company_status=status,
        page=page,
    )
    summary["billing_readiness"] = await stripe_billing_readiness(summary["msp"].get("stripe_customer_id"))
    response = HTMLResponse(
        render_portal_dashboard(
            summary,
            actor=session.as_msp_row(),
            company_query=(q or "").strip(),
            company_status=status,
            page=max(page, 1),
        )
    )
    return response


@app.get("/portal/billing", response_class=HTMLResponse)
async def portal_billing_center(
    request: Request,
    key: str | None = None,
    period: str | None = None,
) -> Response:
    try:
        msp, session = require_portal_request(request, portal_key=key)
    except HTTPException:
        return RedirectResponse("/portal/login", status_code=303)

    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="view billing and reporting",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_REPORTING_ROLE_SET,
        allowed_statuses=PORTAL_VIEW_STATUS_SET,
    )
    if blocked is not None:
        return blocked

    current_snapshot = control_plane.billing_snapshot(
        msp_id=str(msp["id"]),
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    billing_period_rows = control_plane.billing_period_summaries_for_msp(str(msp["id"]))
    current_period = str(current_snapshot["period_start"])
    selected_period = (period or "").strip() or current_period
    if selected_period == current_period:
        selected_report = dict(current_snapshot)
        selected_report["billing_run"] = control_plane.existing_billing_run(
            msp_id=str(msp["id"]),
            period_start=current_period,
        )
    else:
        try:
            selected_report = control_plane.billing_period_detail_for_msp(
                msp_id=str(msp["id"]),
                period_start=selected_period,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    billing_readiness = await stripe_billing_readiness(msp.get("stripe_customer_id"))
    can_manage_billing = portal_access_restriction(
        actor_role=normalize_msp_role(session.role),
        msp_status=normalize_msp_status(msp.get("status")),
        action="manage Stripe billing",
        allowed_roles=PORTAL_BILLING_ROLE_SET,
        allowed_statuses=PORTAL_BILLING_STATUS_SET,
    ) is None

    return HTMLResponse(
        render_billing_center_page(
            msp=msp,
            actor=session.as_msp_row(),
            billing_readiness=billing_readiness,
            current_snapshot=current_snapshot,
            selected_report=selected_report,
            billing_period_rows=billing_period_rows,
            selected_period=selected_period,
            can_manage_billing=can_manage_billing,
        )
    )


@app.get("/portal/audit", response_class=HTMLResponse)
async def portal_audit_log(
    request: Request,
    key: str | None = None,
    actor: str | None = None,
    company: str | None = None,
    action: str | None = None,
) -> Response:
    try:
        msp, session = require_portal_request(request, portal_key=key)
    except HTTPException:
        return RedirectResponse("/portal/login", status_code=303)

    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="view audit history",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_REPORTING_ROLE_SET,
        allowed_statuses=PORTAL_VIEW_STATUS_SET,
    )
    if blocked is not None:
        return blocked

    events = control_plane.list_msp_audit_events(
        str(msp["id"]),
        actor_query=(actor or "").strip(),
        organization_query=(company or "").strip(),
        action=(action or "").strip(),
        limit=150,
    )
    available_actions = control_plane.list_msp_audit_actions(str(msp["id"]))
    return HTMLResponse(
        render_audit_log_page(
            msp=msp,
            actor=session.as_msp_row(),
            events=events,
            available_actions=available_actions,
            actor_query=(actor or "").strip(),
            organization_query=(company or "").strip(),
            action_filter=(action or "").strip(),
        )
    )


@app.get("/portal/companies/{organization_id}", response_class=HTMLResponse)
async def portal_company_manage(request: Request, organization_id: str, key: str | None = None) -> Response:
    try:
        msp, session = require_portal_request(request, portal_key=key)
    except HTTPException:
        return RedirectResponse("/portal/login", status_code=303)

    try:
        detail = control_plane.organization_detail_for_msp(
            msp_id=str(msp["id"]),
            organization_id=organization_id,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    billing_snapshot = control_plane.billing_snapshot(msp_id=str(msp["id"]))
    billing_line = next(
        (line for line in billing_snapshot["lines"] if str(line["organization_id"]) == organization_id),
        {},
    )
    response = HTMLResponse(
        render_company_manage_page(
            msp={"id": msp["id"], "name": msp["name"], "status": msp.get("status"), "actor": session.as_msp_row()},
            organization=detail["organization"],
            billing_line=billing_line,
            access_codes=detail["access_codes"],
            memberships=detail["memberships"],
        )
    )
    return response


@app.post("/portal/companies/create", response_class=HTMLResponse)
async def portal_create_company(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    blocked = portal_html_access_response(
        actor=actor,
        msp=msp,
        action="create client companies",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    form = await request.form()
    company_name = (form.get("company_name") or "").strip()
    external_ref = (form.get("external_ref") or "").strip() or None
    provisioned_seats = normalize_seat_limit(form.get("provisioned_seats"))
    requested_code = normalize_access_code(form.get("access_code"))

    if not company_name:
        raise HTTPException(status_code=400, detail="Company name is required")

    create_as_firm = control_plane.billing_exempt_organization_count(msp_id=str(msp["id"])) == 0
    if not create_as_firm:
        payment_blocked = await portal_payment_required_response(
            msp=msp,
            back_href="/portal/dashboard",
            back_label="Back to MSP Portal",
        )
        if payment_blocked is not None:
            return payment_blocked

    organization = control_plane.create_organization(
        msp_id=msp["id"],
        name=company_name,
        external_ref=external_ref,
        provisioned_seats=provisioned_seats,
        billing_exempt=create_as_firm,
    )
    access_code = requested_code or make_access_code(company_name)
    access_code_row = control_plane.create_access_code(
        organization_id=organization["id"],
        code=access_code,
        label=f"{company_name} primary code",
        max_activations=provisioned_seats,
    )
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.company.create",
        actor=actor,
        request=request,
        target_type="organization",
        target_id=str(organization["id"]),
        organization_id=str(organization["id"]),
        organization_name=str(organization["name"]),
        details={
            "external_ref": external_ref,
            "provisioned_seats": organization.get("provisioned_seats"),
            "billing_exempt": organization.get("billing_exempt"),
            "access_code_id": access_code_row["id"],
        },
    )
    billing_note = (
        "<p>This is the MSP firm profile. It is available before Stripe payment setup and is not billed.</p>"
        if create_as_firm
        else "<p>This is a billable customer company. Seats and usage will roll into Stripe billing.</p>"
    )
    invite_message = employee_invite_message(access_code)

    return render_action_result(
        title="Company Created",
        body=f"""
          <p><strong>Company:</strong> {escape(company_name)}<br>
          <strong>Organization ID:</strong> <code>{escape(organization['id'])}</code><br>
          <strong>Provisioned Seats:</strong> {escape(seat_limit_label(organization.get('provisioned_seats')))}<br>
          <strong>Billing:</strong> {escape('Non-billable MSP firm' if organization.get('billing_exempt') else 'Billable customer company')}<br>
          <strong>Access Code:</strong> <code>{escape(access_code)}</code><br>
          <strong>Access Code ID:</strong> <code>{escape(access_code_row['id'])}</code></p>
          {billing_note}
          <p>Send that code to the employee. When they onboard in the app, the code will attach them to this company. If they leave later, you can remove access and they can still rejoin later with a valid company code.</p>
          <p><strong>Ready-to-send employee invite:</strong></p>
          <textarea readonly style="width:100%; min-height:120px;">{escape(invite_message)}</textarea>
        """,
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
    )


@app.post("/portal/companies/update", response_class=HTMLResponse)
async def portal_update_company(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    form = await request.form()
    organization_id = (form.get("organization_id") or "").strip()
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="update company settings",
        back_href=f"/portal/companies/{quote(organization_id)}" if organization_id else "/portal/dashboard",
        back_label="Back to Company Management" if organization_id else "Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    external_ref = (form.get("external_ref") or "").strip() or None
    provisioned_seats = normalize_seat_limit(form.get("provisioned_seats"))

    try:
        organization = control_plane.update_organization_for_msp(
            msp_id=str(msp["id"]),
            organization_id=organization_id,
            external_ref=external_ref,
            provisioned_seats=provisioned_seats,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.company.update",
        actor=actor,
        request=request,
        target_type="organization",
        target_id=str(organization["id"]),
        organization_id=str(organization["id"]),
        organization_name=str(organization["name"]),
        details={
            "external_ref": organization.get("external_ref"),
            "provisioned_seats": organization.get("provisioned_seats"),
        },
    )

    return render_action_result(
        title="Company Updated",
        body=f"""
          <p><strong>Company:</strong> {escape(str(organization['name']))}<br>
          <strong>Organization ID:</strong> <code>{escape(str(organization['id']))}</code><br>
          <strong>External Reference:</strong> {escape(str(organization.get('external_ref') or '-'))}<br>
          <strong>Provisioned Seats:</strong> {escape(seat_limit_label(organization.get('provisioned_seats')))}</p>
          <p>New sign-ups now use this company seat allocation immediately.</p>
        """,
        back_href=f"/portal/companies/{quote(str(organization['id']))}",
        back_label="Back to Company Management",
    )


@app.post("/portal/access-codes/create", response_class=HTMLResponse)
async def portal_create_access_code(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    form = await request.form()
    organization_id = (form.get("organization_id") or "").strip()
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="issue live access codes",
        back_href=f"/portal/companies/{quote(organization_id)}" if organization_id else "/portal/dashboard",
        back_label="Back to Company Management" if organization_id else "Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_PRODUCTION_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    label = (form.get("label") or "").strip() or None
    max_activations = normalize_seat_limit(form.get("max_activations"))
    requested_code = normalize_access_code(form.get("access_code"))

    organization = control_plane.get_organization_for_msp(
        msp_id=msp["id"],
        organization_id=organization_id,
    )
    if organization is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    if not bool(organization["active"]):
        raise HTTPException(status_code=400, detail="Organization is not active")
    if not bool(organization["billing_exempt"]):
        payment_blocked = await portal_payment_required_response(
            msp=msp,
            back_href=f"/portal/companies/{quote(organization_id)}",
            back_label="Back to Company Management",
        )
        if payment_blocked is not None:
            return payment_blocked

    access_code = requested_code or make_access_code(str(organization["name"]))
    try:
        access_code_row = control_plane.create_access_code(
            organization_id=organization_id,
            code=access_code,
            label=label or f"{organization['name']} additional code",
            max_activations=max_activations,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="That access code is already assigned") from exc

    invite_message = employee_invite_message(access_code)
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.access_code.create",
        actor=actor,
        request=request,
        target_type="access_code",
        target_id=str(access_code_row["id"]),
        organization_id=str(organization["id"]),
        organization_name=str(organization["name"]),
        details={
            "label": access_code_row.get("label"),
            "max_activations": access_code_row.get("max_activations"),
        },
    )
    return render_action_result(
        title="Access Code Created",
        body=f"""
          <p><strong>Company:</strong> {escape(str(organization['name']))}<br>
          <strong>Organization ID:</strong> <code>{escape(organization_id)}</code><br>
          <strong>Access Code:</strong> <code>{escape(access_code)}</code><br>
          <strong>Access Code ID:</strong> <code>{escape(access_code_row['id'])}</code><br>
          <strong>Label:</strong> {escape(str(access_code_row.get('label') or '-'))}<br>
          <strong>Seat Cap On This Code:</strong> {escape(seat_limit_label(access_code_row.get('max_activations')))}</p>
          <p>This code can be shared with another employee or workgroup for the same company. Billing still rolls up at the MSP level by active and billable seats, not by number of access codes.</p>
          <p><strong>Ready-to-send employee invite:</strong></p>
          <textarea readonly style="width:100%; min-height:120px;">{escape(invite_message)}</textarea>
        """,
        back_href=f"/portal/companies/{quote(organization_id)}",
        back_label="Back to Company Management",
    )


@app.post("/portal/access-codes/deactivate", response_class=HTMLResponse)
async def portal_deactivate_access_code(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    form = await request.form()
    organization_id = (form.get("organization_id") or "").strip()
    access_code_id = (form.get("access_code_id") or "").strip()
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="disable access codes",
        back_href=f"/portal/companies/{quote(organization_id)}" if organization_id else "/portal/dashboard",
        back_label="Back to Company Management" if organization_id else "Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    try:
        access_code = control_plane.deactivate_access_code_for_msp(
            msp_id=str(msp["id"]),
            organization_id=organization_id,
            access_code_id=access_code_id,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.access_code.deactivate",
        actor=actor,
        request=request,
        target_type="access_code",
        target_id=str(access_code.get("id") or access_code_id),
        organization_id=str(access_code.get("organization_id") or organization_id),
        organization_name=str(access_code.get("organization_name") or ""),
        details={"label": access_code.get("label")},
    )

    return render_action_result(
        title="Access Code Disabled",
        body=f"""
          <p><strong>Company:</strong> {escape(str(access_code.get('organization_name') or '-'))}<br>
          <strong>Code:</strong> {escape(str(access_code.get('label') or '-'))}<br>
          <strong>Hint:</strong> <code>••••{escape(str(access_code.get('code_hint') or '----'))}</code></p>
          <p>This code is disabled for new onboarding. Existing users keep their current company status until removed separately.</p>
        """,
        back_href=f"/portal/companies/{quote(organization_id)}",
        back_label="Back to Company Management",
    )


@app.post("/portal/memberships/deactivate", response_class=HTMLResponse)
async def portal_deactivate_membership(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    form = await request.form()
    organization_id = (form.get("organization_id") or "").strip() or None
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="change employee access",
        back_href=f"/portal/companies/{quote(organization_id)}" if organization_id else "/portal/dashboard",
        back_label="Back to Company Management" if organization_id else "Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    phone_number = (form.get("phone_number") or "").strip()
    user_id = (form.get("user_id") or "").strip() or None
    result = control_plane.deactivate_memberships_for_msp(
        msp_id=msp["id"],
        organization_id=organization_id,
        phone_number=phone_number,
        user_id=user_id,
    )
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.membership.deactivate",
        actor=actor,
        request=request,
        target_type="membership",
        target_id=user_id or phone_number,
        organization_id=organization_id,
        details={
            "phone_number": phone_number,
            "user_id": user_id,
            "deactivated_memberships": int(result["deactivated_memberships"]),
            "organizations": list(result["organizations"]),
        },
    )
    return render_action_result(
        title="Access Removed",
        body=f"""
          <p><strong>Phone:</strong> {escape(phone_number or '-')}<br>
          <strong>User ID:</strong> {escape(user_id or '-')}<br>
          <strong>Removed memberships:</strong> {int(result['deactivated_memberships'])}<br>
          <strong>Companies touched:</strong> {escape(', '.join(result['organizations']) or '-')}</p>
          <p>The user lost active access immediately. Their seat remains billable through the current month and can be reactivated later by onboarding again with a valid company access code.</p>
        """,
        back_href=f"/portal/companies/{quote(organization_id)}" if organization_id else "/portal/dashboard",
        back_label="Back to Company Management" if organization_id else "Back to MSP Portal",
    )


@app.post("/portal/organizations/deactivate", response_class=HTMLResponse)
async def portal_deactivate_organization(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    form = await request.form()
    organization_id = (form.get("organization_id") or "").strip()
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="disable client companies",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_OPERATOR_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    try:
        result = control_plane.deactivate_organization_for_msp(
            msp_id=msp["id"],
            organization_id=organization_id,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.organization.deactivate",
        actor=actor,
        request=request,
        target_type="organization",
        target_id=str(result["organization_id"]),
        organization_id=str(result["organization_id"]),
        organization_name=str(result["organization_name"]),
        details={
            "deactivated_memberships": int(result["deactivated_memberships"]),
            "deactivated_access_codes": int(result["deactivated_access_codes"]),
            "expired_grants": int(result.get("expired_grants") or 0),
        },
    )

    return render_action_result(
        title="Company Disabled",
        body=f"""
          <p><strong>Company:</strong> {escape(str(result['organization_name']))}<br>
          <strong>Organization ID:</strong> <code>{escape(str(result['organization_id']))}</code><br>
          <strong>Removed memberships:</strong> {int(result['deactivated_memberships'])}<br>
          <strong>Disabled access codes:</strong> {int(result['deactivated_access_codes'])}</p>
          <p>The company is no longer active in Vicall. Existing access codes and pending onboarding grants were expired, and current employee access ended immediately. Any seats used this month remain billable through the current month only.</p>
        """,
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
    )


@app.post("/portal/team/invite", response_class=HTMLResponse)
async def portal_team_invite(request: Request, key: str | None = None) -> str:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    blocked = portal_html_access_response(
        actor=session.as_msp_row(),
        msp=msp,
        action="manage MSP users",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_OWNER_ROLE_SET,
        allowed_statuses=PORTAL_SETUP_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    form = await request.form()
    full_name = (form.get("full_name") or "").strip() or None
    email = (form.get("email") or "").strip().lower()
    phone_number = (form.get("phone_number") or "").strip() or None
    role = (form.get("role") or MSP_ROLE_OPERATOR).strip() or MSP_ROLE_OPERATOR
    password = (form.get("password") or "").strip() or None
    if not email:
        raise HTTPException(status_code=400, detail="Team member email is required")
    if not phone_number:
        raise HTTPException(status_code=400, detail="Team member phone number is required")

    existing_user = control_plane.get_msp_user_for_msp(msp_id=str(msp["id"]), email=email)
    if existing_user is None:
        try:
            created_user = control_plane.create_msp_user(
                msp_id=str(msp["id"]),
                email=email,
                phone_number=phone_number,
                full_name=full_name,
                role=role,
                password=password,
            )
            user_id = str(created_user["id"])
            resolved_phone = str(created_user.get("phone_number") or "") or None
            resolved_role = str(created_user.get("role") or role)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="That email or phone is already assigned to another MSP") from exc
    else:
        user_id = str(existing_user["id"])
        try:
            if password:
                control_plane.set_msp_user_password(msp_user_id=user_id, password=password)
            control_plane.update_msp_user_profile(
                msp_user_id=user_id,
                phone_number=phone_number,
                full_name=full_name,
                role=role,
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="That email or phone is already assigned to another MSP") from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        refreshed_user = control_plane.get_msp_user_by_email(email)
        resolved_phone = str((refreshed_user or existing_user)["phone_number"] or "") or None
        resolved_role = str((refreshed_user or existing_user)["role"] or role)
    setup_token = control_plane.issue_msp_login_token(
        msp_user_id=user_id,
        purpose="password_setup",
        ttl_minutes=24 * 60,
    )
    setup_url = portal_setup_password_url(request, setup_token)
    password_note = (
        "An initial password was set from the submitted form and is not displayed here."
        if password
        else "No password was displayed or generated; send the one-time setup link to let this user set it."
    )

    body = f"""
      <p><strong>MSP User:</strong> {escape(email)}<br>
      <strong>Phone:</strong> {escape(resolved_phone or '-')}<br>
      <strong>Role:</strong> {escape(portal_role_label(resolved_role))}<br>
      <strong>Setup Link:</strong> <a href="{escape(setup_url)}">{escape(setup_url)}</a></p>
      <p>{escape(password_note)} The setup link is one-time use and expires in 24 hours.</p>
      <p>They can sign in at <a href="/portal/login">/portal/login</a> after setting a password, confirming their phone number, and entering the texted passcode to manage the parts of <strong>{escape(str(msp['name']))}</strong> their role allows.</p>
    """
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.msp_user.upsert",
        actor=actor,
        request=request,
        target_type="msp_user",
        target_id=user_id,
        details={
            "email": email,
            "phone_number": resolved_phone,
            "role": resolved_role,
            "created": existing_user is None,
        },
    )

    return render_action_result(
        title="MSP User Ready",
        body=body,
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
    )


@app.get("/portal/export/companies.csv")
async def portal_export_companies_csv(request: Request, key: str | None = None) -> Response:
    msp, session = require_portal_request(request, portal_key=key)
    portal_api_access_check(
        actor=session.as_msp_row(),
        msp=msp,
        action="export company data",
        allowed_roles=PORTAL_ALL_ROLE_SET,
        allowed_statuses=PORTAL_VIEW_STATUS_SET,
    )
    rows = control_plane.organization_rows_for_msp(msp["id"])
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.export.companies",
        actor=session.as_msp_row(),
        request=request,
        target_type="export",
        target_id="companies.csv",
        details={"row_count": len(rows)},
    )
    return csv_response(
        filename=f"{msp['id']}-companies.csv",
        rows=rows,
        fieldnames=["id", "name", "external_ref", "provisioned_seats", "active", "active_seats", "inactive_seats", "last_verified_at"],
    )


@app.get("/portal/export/users.csv")
async def portal_export_users_csv(request: Request, key: str | None = None) -> Response:
    msp, session = require_portal_request(request, portal_key=key)
    portal_api_access_check(
        actor=session.as_msp_row(),
        msp=msp,
        action="export user data",
        allowed_roles=PORTAL_ALL_ROLE_SET,
        allowed_statuses=PORTAL_VIEW_STATUS_SET,
    )
    rows = control_plane.membership_rows_for_msp(msp["id"])
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.export.users",
        actor=session.as_msp_row(),
        request=request,
        target_type="export",
        target_id="users.csv",
        details={"row_count": len(rows)},
    )
    return csv_response(
        filename=f"{msp['id']}-users.csv",
        rows=rows,
        fieldnames=[
            "id",
            "organization_id",
            "organization_name",
            "phone_number",
            "user_id",
            "status",
            "first_verified_at",
            "last_verified_at",
            "deactivated_at",
        ],
    )


@app.get("/portal/export/usage.csv")
async def portal_export_usage_csv(request: Request, key: str | None = None) -> Response:
    msp, session = require_portal_request(request, portal_key=key)
    portal_api_access_check(
        actor=session.as_msp_row(),
        msp=msp,
        action="export usage data",
        allowed_roles=PORTAL_ALL_ROLE_SET,
        allowed_statuses=PORTAL_VIEW_STATUS_SET,
    )
    rollup = control_plane.refresh_monthly_usage_snapshots(
        msp_id=msp["id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.export.usage",
        actor=session.as_msp_row(),
        request=request,
        target_type="export",
        target_id="usage.csv",
        details={"row_count": len(rollup["users"])},
    )
    return csv_response(
        filename=f"{msp['id']}-usage.csv",
        rows=rollup["users"],
        fieldnames=[
            "period_start",
            "organization_id",
            "organization_name",
            "membership_id",
            "phone_number",
            "user_id",
            "call_count",
            "billable_seconds",
            "billable_minutes",
        ],
    )


@app.post("/portal/customer-portal-session")
async def portal_customer_portal_session(
    request: CreatePortalSessionRequest,
    raw_request: Request,
    x_msp_key: str | None = Header(default=None),
) -> dict[str, object]:
    msp, session = require_portal_request(raw_request, header_portal_key=x_msp_key)
    portal_api_access_check(
        actor=session.as_msp_row(),
        msp=msp,
        action="manage Stripe billing",
        allowed_roles=PORTAL_BILLING_ROLE_SET,
        allowed_statuses=PORTAL_BILLING_STATUS_SET,
    )
    stripe_customer_id = msp["stripe_customer_id"]
    if not stripe_customer_id:
        raise HTTPException(status_code=400, detail="MSP does not have a Stripe customer yet")
    if not stripe_enabled():
        raise HTTPException(status_code=503, detail="Stripe is not configured")
    try:
        billing_session = await create_billing_portal_session(
            customer_id=stripe_customer_id,
            return_url=request.return_url,
        )
    except StripeBillingError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.billing.portal_session",
        actor=session.as_msp_row(),
        request=raw_request,
        target_type="stripe_customer",
        target_id=str(stripe_customer_id),
        details={"return_url": request.return_url},
    )
    return {"url": billing_session["url"]}


async def portal_manage_billing_impl(request: Request, key: str | None = None) -> Response:
    msp, session = require_portal_request(request, portal_key=key)
    actor = session.as_msp_row()
    blocked = portal_html_access_response(
        actor=actor,
        msp=msp,
        action="manage Stripe billing",
        back_href="/portal/dashboard",
        back_label="Back to MSP Portal",
        allowed_roles=PORTAL_BILLING_ROLE_SET,
        allowed_statuses=PORTAL_BILLING_STATUS_SET,
    )
    if blocked is not None:
        return blocked
    stripe_customer_id = msp["stripe_customer_id"]
    if not stripe_customer_id:
        raise HTTPException(status_code=400, detail="MSP does not have a Stripe customer yet")
    if not stripe_enabled():
        raise HTTPException(status_code=503, detail="Stripe is not configured")
    try:
        billing_session = await create_billing_portal_session(
            customer_id=stripe_customer_id,
            return_url=f"{request.url.scheme}://{request.url.netloc}/portal/dashboard",
        )
    except StripeBillingError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    record_msp_audit_event(
        msp_id=str(msp["id"]),
        action="portal.billing.portal_redirect",
        actor=actor,
        request=request,
        target_type="stripe_customer",
        target_id=str(stripe_customer_id),
        details={"return_url": f"{request.url.scheme}://{request.url.netloc}/portal/dashboard"},
    )
    return RedirectResponse(billing_session["url"], status_code=303)


@app.get("/portal/billing/manage")
async def portal_manage_billing_get(request: Request, key: str | None = None) -> Response:
    return await portal_manage_billing_impl(request, key=key)


@app.post("/portal/billing/manage")
async def portal_manage_billing(request: Request, key: str | None = None) -> Response:
    return await portal_manage_billing_impl(request, key=key)


@app.post("/stripe/webhook")
async def stripe_webhook(request: Request) -> dict[str, str]:
    payload = await request.body()
    signature = request.headers.get("stripe-signature")
    if not verify_webhook_signature(payload=payload, signature_header=signature):
        raise HTTPException(status_code=400, detail="Invalid Stripe webhook signature")

    event = json.loads(payload.decode("utf-8"))
    event_type = event.get("type")
    obj = event.get("data", {}).get("object", {})
    invoice_id = obj.get("id")
    if invoice_id and event_type in {"invoice.finalized", "invoice.paid", "invoice.payment_failed"}:
        status_map = {
            "invoice.finalized": "finalized",
            "invoice.paid": "paid",
            "invoice.payment_failed": "payment_failed",
        }
        mapped_status = status_map[event_type]
        control_plane.update_billing_run_status(
            stripe_invoice_id=invoice_id,
            status=mapped_status,
            hosted_invoice_url=obj.get("hosted_invoice_url"),
        )
        seat_event = control_plane.update_seat_billing_event_status(
            stripe_invoice_id=invoice_id,
            status=mapped_status,
            hosted_invoice_url=obj.get("hosted_invoice_url"),
        )
        billing_run = control_plane.billing_run_by_invoice_id(str(invoice_id))
        msp_id = str(obj.get("metadata", {}).get("msp_id") or (billing_run or {}).get("msp_id") or "")
        if msp_id:
            record_system_audit_event(
                msp_id=msp_id,
                action="system.billing.invoice_status_updated",
                status=mapped_status,
                target_type="stripe_invoice",
                target_id=str(invoice_id),
                details={
                    "event_type": event_type,
                    "hosted_invoice_url": obj.get("hosted_invoice_url"),
                },
            )
        seat_msp_id = str((seat_event or {}).get("msp_id") or "")
        if seat_msp_id:
            record_system_audit_event(
                msp_id=seat_msp_id,
                action="system.billing.seat_invoice_status_updated",
                status=mapped_status,
                target_type="stripe_invoice",
                target_id=str(invoice_id),
                organization_id=str((seat_event or {}).get("organization_id") or "") or None,
                details={
                    "event_type": event_type,
                    "membership_id": (seat_event or {}).get("membership_id"),
                    "phone_number": (seat_event or {}).get("phone_number"),
                    "hosted_invoice_url": obj.get("hosted_invoice_url"),
                },
            )
        billing_failure_msp_id = msp_id or seat_msp_id
        if (
            mapped_status == "payment_failed"
            and billing_failure_msp_id
            and truthy_env("VICALL_SUSPEND_MSP_ON_PAYMENT_FAILED", "true")
        ):
            current_msp = control_plane.get_msp(billing_failure_msp_id)
            if current_msp is not None and str(current_msp["status"]) == MSP_STATUS_ACTIVE:
                control_plane.set_msp_status(
                    msp_id=billing_failure_msp_id,
                    status=MSP_STATUS_SUSPENDED,
                )
                record_system_audit_event(
                    msp_id=billing_failure_msp_id,
                    action="system.billing.msp_suspended_payment_failed",
                    status="suspended",
                    target_type="stripe_invoice",
                    target_id=str(invoice_id),
                    details={
                        "event_type": event_type,
                        "previous_status": current_msp["status"],
                        "hosted_invoice_url": obj.get("hosted_invoice_url"),
                    },
                )
    return {"status": "ok"}


@app.post("/debug/device-event")
async def device_event(request: DeviceEventRequest) -> dict[str, str]:
    logger.info(
        "[DeviceEvent] identity=%s event=%s details=%s",
        request.identity or "unknown",
        request.event,
        request.details,
    )
    return {"status": "ok"}


@app.post("/calls/device-binding")
async def device_binding(request: DeviceBindingRequest) -> dict[str, str]:
    identity = normalize_twilio_identity(request.identity)
    voip_token = request.voip_token.strip().replace(" ", "").lower()
    if not identity or not voip_token:
        raise HTTPException(status_code=400, detail="Missing identity or VoIP token")
    requested_context = voice_context_from_model(request)
    membership = require_active_voice_membership(
        identity,
        role="device",
        require_unambiguous=not voice_context_is_present(requested_context),
        **requested_context,
    )

    device_bindings[identity] = {
        "voip_token": voip_token,
        "platform": request.platform,
        "context": request.context,
        "membership_id": str(membership["membership_id"]),
        "organization_id": str(membership["organization_id"]),
        "msp_id": str(membership["msp_id"]),
    }
    save_device_bindings(device_bindings)
    logger.info(
        "[DeviceBinding] identity=%s platform=%s context=%s msp=%s org=%s membership=%s token_suffix=%s",
        identity,
        request.platform,
        request.context,
        membership["msp_id"],
        membership["organization_id"],
        membership["membership_id"],
        voip_token[-8:],
    )
    return {"status": "ok", "identity": identity, "token_suffix": voip_token[-8:]}


@app.get("/debug/bindings")
async def debug_bindings() -> dict[str, object]:
    return {
        "count": len(device_bindings),
        "bindings": {
            identity: {
                "platform": binding.get("platform", "unknown"),
                "context": binding.get("context", "unknown"),
                "membership_id": binding.get("membership_id"),
                "organization_id": binding.get("organization_id"),
                "msp_id": binding.get("msp_id"),
                "token_suffix": binding.get("voip_token", "")[-8:],
            }
            for identity, binding in device_bindings.items()
        },
    }


@app.post("/calls/client-notification")
async def client_notification(request: Request) -> JSONResponse:
    if not custom_apns_fallback_enabled():
        logger.warning("[ClientNotification] Custom APNs fallback disabled")
        return JSONResponse({"status": "disabled"}, status_code=404)

    try:
        payload = await request.json()
    except Exception as exc:
        logger.exception("[ClientNotification] Could not parse JSON")
        raise HTTPException(status_code=400, detail="Invalid notification payload") from exc

    twi_to = str(payload.get("twi_to") or payload.get("To") or "")
    if twi_to.startswith("client:"):
        identity = twi_to.split(":", 1)[1]
    else:
        identity = twi_to
    identity = normalize_twilio_identity(identity) or ""

    binding_context = voice_context_from_binding(identity)
    if not active_voice_membership(identity, **binding_context):
        logger.warning(
            "[ClientNotification] Blocked inactive binding To=%s CallSid=%s",
            twi_to,
            payload.get("twi_call_sid") or payload.get("CallSid"),
        )
        return JSONResponse({"status": "inactive"}, status_code=403)

    binding = device_bindings.get(identity)
    if not binding:
        logger.warning(
            "[ClientNotification] No binding found To=%s CallSid=%s",
            twi_to,
            payload.get("twi_call_sid") or payload.get("CallSid"),
        )
        return JSONResponse({"status": "not_found"}, status_code=404)

    status_code, response_text = await send_voip_apns_push(
        device_token=binding["voip_token"],
        payload=payload,
    )
    logger.info(
        "[ClientNotification] APNs sent To=%s CallSid=%s APNsStatus=%s APNsResponse=%s token_suffix=%s",
        twi_to,
        payload.get("twi_call_sid") or payload.get("CallSid"),
        status_code,
        response_text,
        binding["voip_token"][-8:],
    )
    if status_code != 200:
        return JSONResponse(
            {"status": "apns_failed", "apns_status": status_code, "apns_response": response_text},
            status_code=502,
        )
    return JSONResponse({"status": "ok", "identity": identity})


def public_base_url(request: Request) -> str:
    configured = os.getenv("PUBLIC_BASE_URL")
    if configured:
        return configured.rstrip("/")
    inferred = str(request.base_url).rstrip("/")
    if inferred.startswith("http://") and inferred.endswith(".fly.dev"):
        return "https://" + inferred.removeprefix("http://")
    return inferred


def parse_twilio_duration_seconds(form: Any) -> int | None:
    for key in ("CallDuration", "DialCallDuration", "Duration"):
        value = form.get(key) if hasattr(form, "get") else None
        if value is None:
            continue
        try:
            return max(int(float(str(value).strip())), 0)
        except (TypeError, ValueError):
            continue
    return None


def call_session_key(
    *,
    session_key: str | None = None,
    room: str | None = None,
    call_sid: str | None = None,
    parent_call_sid: str | None = None,
) -> str | None:
    normalized_session = (session_key or "").strip()
    if normalized_session:
        return normalized_session
    normalized_room = (room or "").strip()
    if normalized_room:
        return f"room:{normalized_room}"
    fallback_sid = (parent_call_sid or "").strip() or (call_sid or "").strip()
    if fallback_sid:
        return f"call:{fallback_sid}"
    return None


MEDIA_MIRROR_SAMPLE_RATE = 16_000
MEDIA_MIRROR_MAX_SECONDS = max(int(os.getenv("TWILIO_AI_AUDIO_MIRROR_ROLLING_SECONDS", "12")), 3)
MEDIA_MIRROR_MAX_BYTES_PER_STREAM = MEDIA_MIRROR_SAMPLE_RATE * MEDIA_MIRROR_MAX_SECONDS * 2
MEDIA_MIRROR_STALE_SECONDS = max(int(os.getenv("TWILIO_AI_AUDIO_MIRROR_STALE_SECONDS", "3600")), 300)
MEDIA_MIRROR_AUTH_CACHE_SECONDS = max(int(os.getenv("TWILIO_AI_AUDIO_MIRROR_AUTH_CACHE_SECONDS", "60")), 5)


def ai_audio_mirror_enabled() -> bool:
    return os.getenv("TWILIO_AI_AUDIO_MIRROR_ENABLED", "true").lower() in TRUTHY_ENV_VALUES


def audio_mirror_auth_validation_disabled() -> bool:
    return os.getenv("TWILIO_AI_AUDIO_MIRROR_SKIP_AUTH_VALIDATION", "false").lower() in TRUTHY_ENV_VALUES


async def validate_audio_mirror_bearer(authorization: str | None) -> str:
    access_token = require_bearer_token(authorization)
    if audio_mirror_auth_validation_disabled():
        return access_token

    now = time.time()
    cached_until = media_audio_auth_cache.get(access_token)
    if cached_until and cached_until > now:
        return access_token

    await validate_authenticated_account_deletion(access_token)
    media_audio_auth_cache[access_token] = now + MEDIA_MIRROR_AUTH_CACHE_SECONDS
    if len(media_audio_auth_cache) > 256:
        expired = [token for token, expires_at in media_audio_auth_cache.items() if expires_at <= now]
        for token in expired:
            media_audio_auth_cache.pop(token, None)
    return access_token


def media_mirror_websocket_url(request: Request) -> str:
    base = public_base_url(request)
    if base.startswith("https://"):
        return "wss://" + base.removeprefix("https://") + "/calls/media-stream"
    if base.startswith("http://"):
        return "ws://" + base.removeprefix("http://") + "/calls/media-stream"
    return base.rstrip("/") + "/calls/media-stream"


def media_mirror_stream_name(session_key: str) -> str:
    digest = sha256(session_key.encode("utf-8")).hexdigest()[:18]
    return f"vicall_ai_{digest}"


def media_mirror_start_twiml(
    *,
    request: Request,
    session_key: str | None,
    mirror_token: str | None,
) -> str:
    if not ai_audio_mirror_enabled() or not session_key or not mirror_token:
        return ""

    safe_url = escape(media_mirror_websocket_url(request), {'"': "&quot;"})
    safe_name = escape(media_mirror_stream_name(session_key), {'"': "&quot;"})
    safe_session = escape(session_key, {'"': "&quot;"})
    safe_token = escape(mirror_token, {'"': "&quot;"})
    return (
        "    <Start>\n"
        f"        <Stream name=\"{safe_name}\" url=\"{safe_url}\" track=\"both_tracks\">\n"
        f"            <Parameter name=\"session\" value=\"{safe_session}\" />\n"
        f"            <Parameter name=\"mirror_token\" value=\"{safe_token}\" />\n"
        "        </Stream>\n"
        "    </Start>\n"
    )


def media_mirror_empty_response(session_key: str, remote_cursor: int = 0, local_cursor: int = 0) -> dict[str, object]:
    return {
        "session": session_key,
        "sample_rate": MEDIA_MIRROR_SAMPLE_RATE,
        "remote_cursor": remote_cursor,
        "local_cursor": local_cursor,
        "remote_pcm16_base64": None,
        "local_pcm16_base64": None,
        "remote_samples": 0,
        "local_samples": 0,
        "active": False,
    }


def media_mirror_new_session(session_key: str, mirror_token: str) -> dict[str, Any]:
    now = time.time()
    return {
        "session": session_key,
        "mirror_token": mirror_token,
        "remote_pcm": bytearray(),
        "local_pcm": bytearray(),
        "remote_start_cursor": 0,
        "local_start_cursor": 0,
        "remote_cursor": 0,
        "local_cursor": 0,
        "active": False,
        "created_at": now,
        "updated_at": now,
        "stream_sid": None,
        "call_sid": None,
    }


def media_mirror_prune_locked(now: float | None = None) -> None:
    cutoff = (now or time.time()) - MEDIA_MIRROR_STALE_SECONDS
    stale_keys = [
        key
        for key, session in media_audio_sessions.items()
        if float(session.get("updated_at") or 0) < cutoff
    ]
    for key in stale_keys:
        media_audio_sessions.pop(key, None)


async def media_mirror_ensure_session(session_key: str, mirror_token: str) -> dict[str, Any]:
    async with media_audio_lock:
        media_mirror_prune_locked()
        session = media_audio_sessions.get(session_key)
        if session is None:
            session = media_mirror_new_session(session_key, mirror_token)
            media_audio_sessions[session_key] = session
        elif not compare_digest(str(session.get("mirror_token") or ""), mirror_token):
            raise HTTPException(status_code=403, detail="Invalid audio mirror token")
        session["updated_at"] = time.time()
        return session


async def media_mirror_register_webhook_session(session_key: str | None, mirror_token: str | None) -> None:
    if not session_key or not mirror_token:
        return
    await media_mirror_ensure_session(session_key, mirror_token)


async def media_mirror_mark_stream_started(
    *,
    session_key: str,
    mirror_token: str,
    stream_sid: str | None,
    call_sid: str | None,
) -> bool:
    try:
        session = await media_mirror_ensure_session(session_key, mirror_token)
    except HTTPException:
        return False

    async with media_audio_lock:
        current = media_audio_sessions.get(session_key)
        if current is None:
            return False
        current["active"] = True
        current["stream_sid"] = stream_sid
        current["call_sid"] = call_sid
        current["updated_at"] = time.time()
    logger.info(
        "[MediaMirror] Stream started Session=%s StreamSid=%s CallSid=%s",
        session_key,
        stream_sid or "unknown",
        call_sid or "unknown",
    )
    return True


async def media_mirror_mark_stream_stopped(session_key: str | None) -> None:
    if not session_key:
        return
    async with media_audio_lock:
        session = media_audio_sessions.get(session_key)
        if session is None:
            return
        session["active"] = False
        session["updated_at"] = time.time()
    logger.info("[MediaMirror] Stream stopped Session=%s", session_key)


def mulaw_decode_sample(value: int) -> int:
    value = (~value) & 0xFF
    sign = value & 0x80
    exponent = (value >> 4) & 0x07
    mantissa = value & 0x0F
    sample = ((mantissa << 3) + 0x84) << exponent
    sample -= 0x84
    if sign:
        sample = -sample
    return max(-32768, min(32767, sample))


def pcm16le_append(output: bytearray, sample: int) -> None:
    clamped = max(-32768, min(32767, int(sample)))
    output.extend(clamped.to_bytes(2, byteorder="little", signed=True))


def mulaw_8k_to_pcm16le_16k(payload: bytes) -> bytes:
    if not payload:
        return b""
    decoded = [mulaw_decode_sample(value) for value in payload]
    output = bytearray(len(decoded) * 4)
    output.clear()
    last_index = len(decoded) - 1
    for index, sample in enumerate(decoded):
        next_sample = decoded[index + 1] if index < last_index else sample
        pcm16le_append(output, sample)
        pcm16le_append(output, (sample + next_sample) // 2)
    return bytes(output)


def media_mirror_stream_side(track: str | None) -> str:
    normalized = (track or "").strip().lower()
    if normalized in {"inbound", "inbound_track"}:
        return "local"
    if normalized in {"outbound", "outbound_track"}:
        return "remote"
    return "remote"


async def media_mirror_append_pcm(session_key: str, side: str, pcm16le: bytes) -> None:
    if not pcm16le:
        return
    if len(pcm16le) % 2 != 0:
        pcm16le = pcm16le[:-1]
    if not pcm16le:
        return

    buffer_key = "remote_pcm" if side == "remote" else "local_pcm"
    cursor_key = "remote_cursor" if side == "remote" else "local_cursor"
    start_key = "remote_start_cursor" if side == "remote" else "local_start_cursor"
    samples_added = len(pcm16le) // 2
    async with media_audio_lock:
        session = media_audio_sessions.get(session_key)
        if session is None:
            return
        buffer = session[buffer_key]
        buffer.extend(pcm16le)
        session[cursor_key] = int(session.get(cursor_key) or 0) + samples_added
        if len(buffer) > MEDIA_MIRROR_MAX_BYTES_PER_STREAM:
            trim_bytes = len(buffer) - MEDIA_MIRROR_MAX_BYTES_PER_STREAM
            trim_bytes -= trim_bytes % 2
            if trim_bytes > 0:
                del buffer[:trim_bytes]
        session[start_key] = int(session.get(cursor_key) or 0) - (len(buffer) // 2)
        session["updated_at"] = time.time()


def media_mirror_chunk_locked(
    session: dict[str, Any],
    *,
    side: str,
    requested_cursor: int,
) -> tuple[bytes, int, int]:
    buffer_key = "remote_pcm" if side == "remote" else "local_pcm"
    cursor_key = "remote_cursor" if side == "remote" else "local_cursor"
    start_key = "remote_start_cursor" if side == "remote" else "local_start_cursor"
    buffer = session[buffer_key]
    start_cursor = int(session.get(start_key) or 0)
    end_cursor = int(session.get(cursor_key) or 0)
    actual_cursor = min(max(int(requested_cursor or 0), start_cursor), end_cursor)
    byte_offset = max(0, (actual_cursor - start_cursor) * 2)
    chunk = bytes(buffer[byte_offset:])
    return chunk, end_cursor, len(chunk) // 2


async def media_mirror_latest_audio(
    *,
    session_key: str,
    mirror_token: str,
    remote_cursor: int,
    local_cursor: int,
) -> dict[str, object]:
    await media_mirror_ensure_session(session_key, mirror_token)
    async with media_audio_lock:
        session = media_audio_sessions.get(session_key)
        if session is None:
            return media_mirror_empty_response(session_key, remote_cursor, local_cursor)
        remote_chunk, remote_end, remote_samples = media_mirror_chunk_locked(
            session,
            side="remote",
            requested_cursor=remote_cursor,
        )
        local_chunk, local_end, local_samples = media_mirror_chunk_locked(
            session,
            side="local",
            requested_cursor=local_cursor,
        )
        session["updated_at"] = time.time()
        return {
            "session": session_key,
            "sample_rate": MEDIA_MIRROR_SAMPLE_RATE,
            "remote_cursor": remote_end,
            "local_cursor": local_end,
            "remote_pcm16_base64": b64encode(remote_chunk).decode("ascii") if remote_chunk else None,
            "local_pcm16_base64": b64encode(local_chunk).decode("ascii") if local_chunk else None,
            "remote_samples": remote_samples,
            "local_samples": local_samples,
            "active": bool(session.get("active")),
        }


def _clean_voice_context_value(value: Any) -> str | None:
    normalized = str(value or "").strip()
    return normalized or None


def voice_account_context(
    *,
    membership_id: Any = None,
    organization_id: Any = None,
    msp_id: Any = None,
) -> dict[str, str | None]:
    return {
        "membership_id": _clean_voice_context_value(membership_id),
        "organization_id": _clean_voice_context_value(organization_id),
        "msp_id": _clean_voice_context_value(msp_id),
    }


def voice_context_is_present(context: dict[str, str | None]) -> bool:
    return any(context.get(key) for key in ("membership_id", "organization_id", "msp_id"))


def voice_context_from_model(model: Any, *, prefix: str | None = None) -> dict[str, str | None]:
    if prefix:
        prefixed = voice_account_context(
            membership_id=getattr(model, f"{prefix}_membership_id", None),
            organization_id=getattr(model, f"{prefix}_organization_id", None),
            msp_id=getattr(model, f"{prefix}_msp_id", None),
        )
        if voice_context_is_present(prefixed):
            return prefixed
    return voice_account_context(
        membership_id=getattr(model, "membership_id", None),
        organization_id=getattr(model, "organization_id", None),
        msp_id=getattr(model, "msp_id", None),
    )


def voice_context_from_mapping(mapping: Any, *, prefix: str | None = None) -> dict[str, str | None]:
    def value_for(*names: str) -> str | None:
        for name in names:
            value = mapping.get(name) if hasattr(mapping, "get") else None
            cleaned = _clean_voice_context_value(value)
            if cleaned:
                return cleaned
        return None

    if prefix:
        lower_prefix = prefix[:1].lower() + prefix[1:]
        prefixed = voice_account_context(
            membership_id=value_for(
                f"{prefix}MembershipId",
                f"{prefix}_membership_id",
                f"{lower_prefix}_membership_id",
            ),
            organization_id=value_for(
                f"{prefix}OrganizationId",
                f"{prefix}_organization_id",
                f"{lower_prefix}_organization_id",
            ),
            msp_id=value_for(f"{prefix}MspId", f"{prefix}MSPId", f"{prefix}_msp_id", f"{lower_prefix}_msp_id"),
        )
        if voice_context_is_present(prefixed):
            return prefixed

    return voice_account_context(
        membership_id=value_for("MembershipId", "membership_id"),
        organization_id=value_for("OrganizationId", "organization_id"),
        msp_id=value_for("MspId", "MSPId", "msp_id"),
    )


def voice_context_from_binding(identity: str | None) -> dict[str, str | None]:
    binding = device_bindings.get(normalize_twilio_identity(identity) or "")
    if not binding:
        return voice_account_context()
    return voice_account_context(
        membership_id=binding.get("membership_id"),
        organization_id=binding.get("organization_id"),
        msp_id=binding.get("msp_id"),
    )


def voice_context_query(prefix: str, context: dict[str, str | None]) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, value in context.items():
        if not value:
            continue
        values[f"{prefix}_{key}"] = value
    return values


def twiml_client_parameter(name: str, value: str | None) -> str:
    if not value:
        return ""
    safe_name = escape(name, {'"': "&quot;"})
    safe_value = escape(value, {'"': "&quot;"})
    return f"            <Parameter name=\"{safe_name}\" value=\"{safe_value}\" />\n"


def ambiguous_voice_membership_detail(identity: str | None) -> dict[str, object]:
    memberships = control_plane.active_voice_memberships_for_identity(identity)
    return {
        "message": "Multiple active Vicall accounts match this phone. Select the MSP/company account before calling.",
        "memberships": [
            {
                "membership_id": row.get("membership_id"),
                "organization_id": row.get("organization_id"),
                "organization_name": row.get("organization_name"),
                "msp_id": row.get("msp_id"),
                "msp_name": row.get("msp_name"),
            }
            for row in memberships
        ],
    }


def active_voice_membership(
    identity: str | None,
    *,
    membership_id: str | None = None,
    organization_id: str | None = None,
    msp_id: str | None = None,
    require_unambiguous: bool = False,
) -> dict[str, Any] | None:
    normalized_identity = normalize_twilio_identity(identity)
    return control_plane.active_voice_membership_for_identity(
        normalized_identity,
        membership_id=membership_id,
        organization_id=organization_id,
        msp_id=msp_id,
        require_unambiguous=require_unambiguous,
    )


def require_active_voice_membership(
    identity: str | None,
    *,
    role: str,
    membership_id: str | None = None,
    organization_id: str | None = None,
    msp_id: str | None = None,
    require_unambiguous: bool = False,
) -> dict[str, Any]:
    try:
        membership = active_voice_membership(
            identity,
            membership_id=membership_id,
            organization_id=organization_id,
            msp_id=msp_id,
            require_unambiguous=require_unambiguous,
        )
    except AmbiguousVoiceMembershipError as exc:
        raise HTTPException(
            status_code=409,
            detail=ambiguous_voice_membership_detail(identity),
        ) from exc
    if membership is None:
        logger.warning(
            "[TwilioVoice] Blocked inactive voice identity role=%s identity=%s",
            role,
            normalize_twilio_identity(identity) or "unknown",
        )
        raise HTTPException(status_code=403, detail=f"Vicall voice access is inactive for {role}")
    return membership


def inactive_voice_twiml(reason: str) -> str:
    safe_reason = escape(reason)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<Response>\n"
        f"    <Say>{safe_reason}</Say>\n"
        "    <Hangup />\n"
        "</Response>"
    )


def twilio_binding_identities(phone_number: str | None, identity: str | None = None) -> set[str]:
    identities: set[str] = set()
    normalized_identity = normalize_twilio_identity(identity)
    if normalized_identity:
        identities.add(normalized_identity)
    normalized_phone = normalize_phone_number(phone_number)
    if normalized_phone:
        digits = "".join(ch for ch in normalized_phone if ch.isdigit())
        if digits:
            for suffix in TWILIO_IDENTITY_SUFFIXES:
                identities.add(f"user_{digits}{suffix}")
    return identities


def record_call_event_safely(**kwargs: Any) -> dict[str, Any] | None:
    try:
        return control_plane.record_call_event(**kwargs)
    except Exception:
        logger.exception("[TwilioVoice] Failed to persist call tracking event")
        return None


def conference_twiml(
    room: str,
    request: Request | None = None,
    role: str = "participant",
    session_key: str | None = None,
    mirror_token: str | None = None,
    from_context: dict[str, str | None] | None = None,
    to_context: dict[str, str | None] | None = None,
) -> str:
    safe_room = escape(room)
    dial_attrs = ""
    if request is not None and role == "caller":
        base = public_base_url(request)
        query = {"room": room}
        if session_key:
            query["session"] = session_key
        query.update(voice_context_query("from", from_context or {}))
        query.update(voice_context_query("to", to_context or {}))
        action_url = f"{base}/calls/conference-caller-complete?{urlencode(query)}"
        safe_action_url = escape(action_url, {'"': "&quot;"})
        dial_attrs = f' action="{safe_action_url}" method="POST"'

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<Response>\n"
        f"    <Dial{dial_attrs}>\n"
        f"        <Conference startConferenceOnEnter=\"true\" endConferenceOnExit=\"true\" beep=\"false\" waitUrl=\"\">{safe_room}</Conference>\n"
        "    </Dial>\n"
        "</Response>"
    )


def client_dial_twiml(
    to_identity: str,
    from_identity: str,
    request: Request,
    session_key: str | None = None,
    mirror_token: str | None = None,
    from_context: dict[str, str | None] | None = None,
    to_context: dict[str, str | None] | None = None,
) -> str:
    safe_to = escape(to_identity)
    base = public_base_url(request)
    status_query = {
        "from": from_identity or "vericall",
        "to": to_identity,
    }
    if session_key:
        status_query["session"] = session_key
    status_query.update(voice_context_query("from", from_context or {}))
    status_query.update(voice_context_query("to", to_context or {}))
    status_url = f"{base}/calls/client-status?{urlencode(status_query)}"
    safe_status_url = escape(status_url, {'"': "&quot;"})
    stream_twiml = media_mirror_start_twiml(
        request=request,
        session_key=session_key,
        mirror_token=mirror_token,
    )
    if (session_key and mirror_token) or voice_context_is_present(from_context or {}) or voice_context_is_present(to_context or {}):
        client_twiml = (
            f"        <Client statusCallback=\"{safe_status_url}\" statusCallbackMethod=\"POST\" statusCallbackEvent=\"initiated ringing answered completed\">\n"
            f"            <Identity>{safe_to}</Identity>\n"
            f"{twiml_client_parameter('session', session_key)}"
            f"{twiml_client_parameter('mirror_token', mirror_token)}"
            f"{twiml_client_parameter('from_membership_id', (from_context or {}).get('membership_id'))}"
            f"{twiml_client_parameter('from_organization_id', (from_context or {}).get('organization_id'))}"
            f"{twiml_client_parameter('from_msp_id', (from_context or {}).get('msp_id'))}"
            f"{twiml_client_parameter('to_membership_id', (to_context or {}).get('membership_id'))}"
            f"{twiml_client_parameter('to_organization_id', (to_context or {}).get('organization_id'))}"
            f"{twiml_client_parameter('to_msp_id', (to_context or {}).get('msp_id'))}"
            "        </Client>\n"
        )
    else:
        client_twiml = (
            f"        <Client statusCallback=\"{safe_status_url}\" statusCallbackMethod=\"POST\" statusCallbackEvent=\"initiated ringing answered completed\">{safe_to}</Client>\n"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<Response>\n"
        f"{stream_twiml}"
        "    <Dial answerOnBridge=\"true\">\n"
        f"{client_twiml}"
        "    </Dial>\n"
        "</Response>"
    )


def _env_pem(name: str) -> str:
    b64_value = os.getenv(f"{name}_B64")
    if b64_value:
        return b64decode(b64_value).decode("utf-8")
    return require_env(name)


async def send_voip_apns_push(device_token: str, payload: dict) -> tuple[int, str]:
    import httpx

    apns_payload = dict(payload)
    # Twilio's client notification payload is meant to be delivered to the
    # mobile SDK without changing the Twilio fields. Native Twilio VoIP pushes
    # use an empty APS dictionary, so mirror that shape for diagnostics.
    apns_payload.setdefault("aps", {})

    cert_pem = _env_pem("APNS_VOIP_CERT_PEM")
    key_pem = _env_pem("APNS_VOIP_KEY_PEM")
    topic = os.getenv("APNS_VOIP_TOPIC", "com.reeceway.vericall.dev.voip")
    use_sandbox = os.getenv("APNS_USE_SANDBOX", "true").lower() in {"1", "true", "yes"}
    host = "api.sandbox.push.apple.com" if use_sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{device_token}"

    cert_file = tempfile.NamedTemporaryFile("w", delete=False)
    key_file = tempfile.NamedTemporaryFile("w", delete=False)
    try:
        cert_file.write(cert_pem)
        cert_file.flush()
        key_file.write(key_pem)
        key_file.flush()
        cert_file.close()
        key_file.close()

        headers = {
            "apns-topic": topic,
            "apns-push-type": "voip",
            "apns-priority": "10",
            "apns-expiration": "0",
        }
        message_id = str(payload.get("twi_message_id") or "")
        if message_id:
            headers["apns-collapse-id"] = message_id[:64]

        async with httpx.AsyncClient(
            http2=True,
            cert=(cert_file.name, key_file.name),
            timeout=10.0,
        ) as client:
            response = await client.post(url, json=apns_payload, headers=headers)
        return response.status_code, response.text
    finally:
        try:
            os.unlink(cert_file.name)
        except OSError:
            pass
        try:
            os.unlink(key_file.name)
        except OSError:
            pass


def create_conference_client_invite(
    *,
    to_identity: str,
    from_identity: str,
    room: str,
    request: Request,
    session_key: str | None = None,
    from_context: dict[str, str | None] | None = None,
    to_context: dict[str, str | None] | None = None,
) -> str:
    from twilio.rest import Client

    account_sid = require_env("TWILIO_ACCOUNT_SID")
    api_key = require_env("TWILIO_API_KEY")
    api_secret = require_env("TWILIO_API_SECRET")
    client = Client(api_key, api_secret, account_sid)

    base = public_base_url(request)
    join_url = f"{base}/calls/conference-join?room={room}"
    status_query = {"room": room}
    if session_key:
        status_query["session"] = session_key
    status_query.update(voice_context_query("from", from_context or {}))
    status_query.update(voice_context_query("to", to_context or {}))
    status_url = f"{base}/calls/conference-status?{urlencode(status_query)}"
    rest_caller_identity = os.getenv("TWILIO_REST_CLIENT_CALLER_ID", "vericall")
    invite_timeout = int(os.getenv("TWILIO_CLIENT_INVITE_TIMEOUT", "30"))

    cancel_pending_client_invites(
        client=client,
        to_identity=to_identity,
        from_identity=rest_caller_identity,
    )

    call = client.calls.create(
        to=f"client:{to_identity}",
        from_=f"client:{rest_caller_identity}",
        url=join_url,
        method="POST",
        timeout=invite_timeout,
        status_callback=status_url,
        status_callback_method="POST",
        status_callback_event=["initiated", "ringing", "answered", "completed"],
    )
    pending_invites_by_room[room] = call.sid
    record_call_event_safely(
        canonical_key=session_key or call_session_key(room=room),
        room=room,
        caller_identity=from_identity,
        callee_identity=to_identity,
        caller_membership_id=(from_context or {}).get("membership_id"),
        caller_organization_id=(from_context or {}).get("organization_id"),
        caller_msp_id=(from_context or {}).get("msp_id"),
        callee_membership_id=(to_context or {}).get("membership_id"),
        callee_organization_id=(to_context or {}).get("organization_id"),
        callee_msp_id=(to_context or {}).get("msp_id"),
        twilio_call_sid=call.sid,
        leg_role="callee_invite",
        status="initiated",
        callback_event="initiated",
    )

    logger.info(
        "[TwilioVoice] Conference invite created From=%s TwilioFrom=%s To=%s Room=%s CallSid=%s",
        from_identity,
        rest_caller_identity,
        to_identity,
        room,
        call.sid,
    )
    return call.sid


def cancel_pending_client_invites(*, client, to_identity: str, from_identity: str) -> None:
    target_to = f"client:{to_identity}"
    target_from = f"client:{from_identity}"
    for status in ("queued", "ringing"):
        try:
            calls = client.calls.list(to=target_to, status=status, limit=20)
        except Exception:
            logger.exception(
                "[TwilioVoice] Could not list pending invites To=%s Status=%s",
                target_to,
                status,
            )
            continue

        for call in calls:
            if getattr(call, "from_", "") != target_from:
                continue
            try:
                client.calls(call.sid).update(status="canceled")
                logger.info(
                    "[TwilioVoice] Canceled stale pending invite CallSid=%s From=%s To=%s Status=%s",
                    call.sid,
                    target_from,
                    target_to,
                    status,
                )
            except Exception:
                logger.exception(
                    "[TwilioVoice] Failed to cancel stale invite CallSid=%s",
                    call.sid,
                )


def cancel_room_invite(room: str, reason: str) -> None:
    call_sid = pending_invites_by_room.pop(room, None)
    if not call_sid:
        return

    try:
        from twilio.rest import Client

        account_sid = require_env("TWILIO_ACCOUNT_SID")
        api_key = require_env("TWILIO_API_KEY")
        api_secret = require_env("TWILIO_API_SECRET")
        client = Client(api_key, api_secret, account_sid)
        client.calls(call_sid).update(status="canceled")
        logger.info(
            "[TwilioVoice] Canceled room invite Room=%s CallSid=%s Reason=%s",
            room,
            call_sid,
            reason,
        )
    except Exception:
        logger.exception(
            "[TwilioVoice] Failed to cancel room invite Room=%s CallSid=%s Reason=%s",
            room,
            call_sid,
            reason,
        )


@app.websocket("/calls/media-stream")
async def twilio_media_stream(websocket: WebSocket) -> None:
    await websocket.accept()
    session_key: str | None = None
    try:
        while True:
            message = await websocket.receive_text()
            try:
                payload = json.loads(message)
            except json.JSONDecodeError:
                logger.warning("[MediaMirror] Ignoring invalid WebSocket JSON")
                continue

            event = str(payload.get("event") or "").strip().lower()
            if event == "connected":
                continue

            if event == "start":
                start = payload.get("start") if isinstance(payload.get("start"), dict) else {}
                custom = start.get("customParameters") if isinstance(start.get("customParameters"), dict) else {}
                session_key = call_session_key(
                    session_key=str(custom.get("session") or "").strip(),
                    call_sid=str(start.get("callSid") or payload.get("CallSid") or "").strip(),
                )
                mirror_token = str(
                    custom.get("mirror_token")
                    or custom.get("MirrorToken")
                    or custom.get("mirrorToken")
                    or ""
                ).strip()
                if not session_key or not mirror_token:
                    logger.warning("[MediaMirror] Rejecting stream missing session or mirror token")
                    await websocket.close(code=1008)
                    return
                allowed = await media_mirror_mark_stream_started(
                    session_key=session_key,
                    mirror_token=mirror_token,
                    stream_sid=str(start.get("streamSid") or "").strip() or None,
                    call_sid=str(start.get("callSid") or "").strip() or None,
                )
                if not allowed:
                    logger.warning("[MediaMirror] Rejecting stream with invalid mirror token Session=%s", session_key)
                    await websocket.close(code=1008)
                    return
                continue

            if event == "media":
                if not session_key:
                    continue
                media = payload.get("media") if isinstance(payload.get("media"), dict) else {}
                encoded_payload = str(media.get("payload") or "")
                if not encoded_payload:
                    continue
                try:
                    pcm16le = mulaw_8k_to_pcm16le_16k(b64decode(encoded_payload))
                except Exception:
                    logger.exception("[MediaMirror] Failed to decode media payload Session=%s", session_key)
                    continue
                await media_mirror_append_pcm(
                    session_key,
                    media_mirror_stream_side(str(media.get("track") or "")),
                    pcm16le,
                )
                continue

            if event == "stop":
                await media_mirror_mark_stream_stopped(session_key)
                return
    except WebSocketDisconnect:
        await media_mirror_mark_stream_stopped(session_key)
    except Exception:
        logger.exception("[MediaMirror] WebSocket stream failed Session=%s", session_key or "unknown")
        await media_mirror_mark_stream_stopped(session_key)


@app.get("/calls/ai-audio/latest")
async def twilio_ai_audio_latest(
    session: str,
    remote_cursor: int = 0,
    local_cursor: int = 0,
    authorization: str | None = Header(default=None),
    x_vicall_audio_mirror_token: str | None = Header(default=None, alias="X-Vicall-Audio-Mirror-Token"),
) -> dict[str, object]:
    await validate_audio_mirror_bearer(authorization)
    session_key = call_session_key(session_key=session)
    mirror_token = (x_vicall_audio_mirror_token or "").strip()
    if not session_key:
        raise HTTPException(status_code=400, detail="session is required")
    if not mirror_token:
        raise HTTPException(status_code=401, detail="Missing audio mirror token")
    return await media_mirror_latest_audio(
        session_key=session_key,
        mirror_token=mirror_token,
        remote_cursor=max(int(remote_cursor or 0), 0),
        local_cursor=max(int(local_cursor or 0), 0),
    )


@app.post("/calls/twilio-token")
async def twilio_token(request: TwilioTokenRequest) -> JSONResponse:
    identity = normalize_twilio_identity(request.identity) or ""
    push_environment = (request.push_environment or "development").strip().lower()
    bundle_identifier = (request.bundle_identifier or "").strip()
    if not identity:
        raise HTTPException(status_code=400, detail="Missing identity")
    requested_context = voice_context_from_model(request)
    membership = require_active_voice_membership(
        identity,
        role="token",
        require_unambiguous=not voice_context_is_present(requested_context),
        **requested_context,
    )

    try:
        from twilio.jwt.access_token import AccessToken
        from twilio.jwt.access_token.grants import VoiceGrant

        account_sid = require_env("TWILIO_ACCOUNT_SID")
        api_key = require_env("TWILIO_API_KEY")
        api_secret = require_env("TWILIO_API_SECRET")
        twiml_app_sid = require_env("TWILIO_TWIML_APP_SID")
        push_credential_sid = twilio_push_credential_sid(push_environment, bundle_identifier)

        voice_grant = VoiceGrant(
            outgoing_application_sid=twiml_app_sid,
            incoming_allow=True,
            push_credential_sid=push_credential_sid,
        )

        token = AccessToken(
            account_sid,
            api_key,
            api_secret,
            identity=identity,
            ttl=3600,
        )
        token.add_grant(voice_grant)

        jwt_token = token.to_jwt()
        if isinstance(jwt_token, bytes):
            jwt_token = jwt_token.decode("utf-8")

        logger.info(
            "[TwilioVoice] Token generated for identity=%s push_environment=%s bundle_identifier=%s msp=%s org=%s membership=%s",
            identity,
            push_environment,
            bundle_identifier or "unknown",
            membership["msp_id"],
            membership["organization_id"],
            membership["membership_id"],
        )
        return JSONResponse(
            {
                "token": jwt_token,
                "identity": identity,
                "expires_in": 3600,
                "push_environment": push_environment,
                "membership_id": membership["membership_id"],
                "organization_id": membership["organization_id"],
                "msp_id": membership["msp_id"],
            }
        )
    except Exception as exc:
        logger.exception("[TwilioVoice] Token generation failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/calls/twilio-voice")
async def twilio_voice_webhook(request: Request) -> PlainTextResponse:
    form = await request.form()
    to_identity = normalize_twilio_identity(str(form.get("To") or "")) or ""
    from_identity = normalize_twilio_identity(str(form.get("From") or "")) or ""
    call_sid = (form.get("CallSid") or "").strip()
    mode = (form.get("Mode") or "").strip()
    room = (form.get("Room") or "").strip()
    requested_session_key = str(form.get("Session") or "").strip()
    mirror_token = str(form.get("MirrorToken") or "").strip()
    from_context = voice_context_from_mapping(form, prefix="From")
    if not voice_context_is_present(from_context):
        from_context = voice_context_from_binding(from_identity)
    to_context = voice_context_from_mapping(form, prefix="To")
    if not voice_context_is_present(to_context):
        to_context = voice_context_from_binding(to_identity)
    session_key = call_session_key(
        session_key=requested_session_key,
        room=room if mode == "conference" else None,
        call_sid=call_sid,
    )
    await media_mirror_register_webhook_session(session_key, mirror_token)

    logger.info(
        "[TwilioVoice] Webhook From=%s To=%s CallSid=%s Mode=%s Room=%s Session=%s AudioMirror=%s",
        from_identity,
        to_identity,
        call_sid,
        mode,
        room,
        session_key or "none",
        "yes" if mirror_token else "no",
    )

    try:
        caller_membership = (
            require_active_voice_membership(
                from_identity,
                role="caller",
                require_unambiguous=not voice_context_is_present(from_context),
                **from_context,
            )
            if from_identity
            else None
        )
    except HTTPException as exc:
        message = (
            "Vicall account selection is required before calling."
            if exc.status_code == 409
            else "Vicall caller account is inactive."
        )
        return PlainTextResponse(
            inactive_voice_twiml(message),
            media_type="application/xml",
        )
    if caller_membership is None:
        return PlainTextResponse(
            inactive_voice_twiml("Vicall caller account is inactive."),
            media_type="application/xml",
        )
    try:
        recipient_membership = (
            require_active_voice_membership(
                to_identity,
                role="recipient",
                require_unambiguous=not voice_context_is_present(to_context),
                **to_context,
            )
            if to_identity
            else None
        )
    except HTTPException as exc:
        message = (
            "Vicall recipient account selection is required before calling."
            if exc.status_code == 409
            else "Vicall recipient account is inactive."
        )
        return PlainTextResponse(
            inactive_voice_twiml(message),
            media_type="application/xml",
        )
    if to_identity and recipient_membership is None:
        return PlainTextResponse(
            inactive_voice_twiml("Vicall recipient account is inactive."),
            media_type="application/xml",
        )

    record_call_event_safely(
        canonical_key=session_key,
        room=room or None,
        caller_identity=from_identity,
        callee_identity=to_identity,
        caller_membership_id=from_context.get("membership_id"),
        caller_organization_id=from_context.get("organization_id"),
        caller_msp_id=from_context.get("msp_id"),
        callee_membership_id=to_context.get("membership_id"),
        callee_organization_id=to_context.get("organization_id"),
        callee_msp_id=to_context.get("msp_id"),
        twilio_call_sid=call_sid or None,
        leg_role="caller",
        status="initiated",
        callback_event="initiated",
    )

    use_conference_wake = os.getenv("TWILIO_USE_CONFERENCE_WAKE", "false").lower() in {
        "1",
        "true",
        "yes",
    }
    if mode == "conference" and room and use_conference_wake:
        if to_identity and from_identity:
            try:
                call_sid = create_conference_client_invite(
                    to_identity=to_identity,
                    from_identity=from_identity,
                    room=room,
                    request=request,
                    session_key=session_key,
                    from_context=from_context,
                    to_context=to_context,
                )
                logger.info(
                    "[TwilioVoice] Webhook-triggered callee wake invite Room=%s CallSid=%s",
                    room,
                    call_sid,
                )
            except Exception:
                logger.exception(
                    "[TwilioVoice] Webhook-triggered callee wake invite failed From=%s To=%s Room=%s",
                    from_identity,
                    to_identity,
                    room,
                )
        return PlainTextResponse(
            conference_twiml(
                room,
                request=request,
                role="caller",
                session_key=session_key,
                mirror_token=mirror_token,
                from_context=from_context,
                to_context=to_context,
            ),
            media_type="application/xml",
        )

    if not to_identity:
        twiml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<Response><Say>No recipient specified.</Say></Response>"
        )
        return PlainTextResponse(twiml, media_type="application/xml")

    twiml = client_dial_twiml(
        to_identity=to_identity,
        from_identity=from_identity or "vericall",
        request=request,
        session_key=session_key,
        mirror_token=mirror_token,
        from_context=from_context,
        to_context=to_context,
    )
    return PlainTextResponse(twiml, media_type="application/xml")


@app.api_route("/calls/client-status", methods=["GET", "POST"])
async def client_status(request: Request) -> dict[str, str]:
    form = await request.form() if request.method == "POST" else {}
    params = request.query_params
    expected_from = (params.get("from") or "").strip()
    expected_to = (params.get("to") or "").strip()
    session_key = call_session_key(session_key=params.get("session"))
    call_sid = (form.get("CallSid") or "").strip()
    parent_call_sid = (form.get("ParentCallSid") or "").strip()
    call_status = (form.get("CallStatus") or "").strip()
    callback_event = (form.get("CallbackEvent") or form.get("StatusCallbackEvent") or "").strip()
    from_value = (form.get("From") or "").strip()
    to_value = (form.get("To") or "").strip()
    from_context = voice_context_from_mapping(params, prefix="from")
    if not voice_context_is_present(from_context):
        from_context = voice_context_from_binding(from_value or expected_from)
    to_context = voice_context_from_mapping(params, prefix="to")
    if not voice_context_is_present(to_context):
        to_context = voice_context_from_binding(to_value or expected_to)
    if not session_key:
        session_key = call_session_key(call_sid=call_sid, parent_call_sid=parent_call_sid)
    record_call_event_safely(
        canonical_key=session_key,
        caller_identity=from_value or expected_from,
        callee_identity=to_value or expected_to,
        caller_membership_id=from_context.get("membership_id"),
        caller_organization_id=from_context.get("organization_id"),
        caller_msp_id=from_context.get("msp_id"),
        callee_membership_id=to_context.get("membership_id"),
        callee_organization_id=to_context.get("organization_id"),
        callee_msp_id=to_context.get("msp_id"),
        twilio_call_sid=call_sid or None,
        parent_call_sid=parent_call_sid or None,
        leg_role="client",
        status=call_status,
        callback_event=callback_event,
        duration_seconds=parse_twilio_duration_seconds(form),
    )
    logger.info(
        "[TwilioVoice] Client status Event=%s Status=%s CallSid=%s ParentCallSid=%s From=%s To=%s ExpectedFrom=%s ExpectedTo=%s",
        callback_event,
        call_status,
        call_sid,
        parent_call_sid,
        from_value,
        to_value,
        expected_from,
        expected_to,
    )
    return {"status": "ok"}


@app.post("/calls/conference-invite")
async def conference_invite(request: ClientInviteRequest, raw_request: Request) -> JSONResponse:
    to_identity = normalize_twilio_identity(request.to) or ""
    from_identity = normalize_twilio_identity(request.from_identity) or ""
    room = request.room.strip()
    from_context = voice_context_from_model(request, prefix="from")
    to_context = voice_context_from_model(request, prefix="to")
    if not voice_context_is_present(to_context):
        to_context = voice_context_from_binding(to_identity)

    if not to_identity or not from_identity or not room:
        raise HTTPException(status_code=400, detail="Missing to, from_identity, or room")
    require_active_voice_membership(
        from_identity,
        role="conference caller",
        require_unambiguous=not voice_context_is_present(from_context),
        **from_context,
    )
    require_active_voice_membership(
        to_identity,
        role="conference recipient",
        require_unambiguous=not voice_context_is_present(to_context),
        **to_context,
    )

    try:
        session_key = call_session_key(room=room)
        record_call_event_safely(
            canonical_key=session_key,
            room=room,
            caller_identity=from_identity,
            callee_identity=to_identity,
            caller_membership_id=from_context.get("membership_id"),
            caller_organization_id=from_context.get("organization_id"),
            caller_msp_id=from_context.get("msp_id"),
            callee_membership_id=to_context.get("membership_id"),
            callee_organization_id=to_context.get("organization_id"),
            callee_msp_id=to_context.get("msp_id"),
            leg_role="conference_request",
            status="initiated",
            callback_event="initiated",
        )
        call_sid = create_conference_client_invite(
            to_identity=to_identity,
            from_identity=from_identity,
            room=room,
            request=raw_request,
            session_key=session_key,
            from_context=from_context,
            to_context=to_context,
        )

        return JSONResponse(
            {
                "call_sid": call_sid,
                "from": from_identity,
                "to": to_identity,
                "room": room,
                "session": session_key,
            }
        )
    except Exception as exc:
        logger.exception("[TwilioVoice] Conference invite failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.api_route("/calls/conference-join", methods=["GET", "POST"])
async def conference_join(room: str) -> PlainTextResponse:
    logger.info("[TwilioVoice] Conference join Room=%s", room)
    return PlainTextResponse(conference_twiml(room, role="callee"), media_type="application/xml")


@app.api_route("/calls/conference-caller-complete", methods=["GET", "POST"])
async def conference_caller_complete(request: Request) -> PlainTextResponse:
    form = await request.form() if request.method == "POST" else {}
    params = request.query_params
    room = (form.get("room") or params.get("room") or "").strip()
    call_sid = (form.get("CallSid") or "").strip()
    call_status = (form.get("CallStatus") or "").strip()
    from_value = (form.get("From") or "").strip() or None
    to_value = (form.get("To") or "").strip() or None
    from_context = voice_context_from_mapping(params, prefix="from")
    if not voice_context_is_present(from_context):
        from_context = voice_context_from_binding(from_value)
    to_context = voice_context_from_mapping(params, prefix="to")
    if not voice_context_is_present(to_context):
        to_context = voice_context_from_binding(to_value)
    session_key = call_session_key(
        session_key=params.get("session"),
        room=room,
        call_sid=call_sid,
    )
    record_call_event_safely(
        canonical_key=session_key,
        room=room or None,
        caller_identity=from_value,
        callee_identity=to_value,
        caller_membership_id=from_context.get("membership_id"),
        caller_organization_id=from_context.get("organization_id"),
        caller_msp_id=from_context.get("msp_id"),
        callee_membership_id=to_context.get("membership_id"),
        callee_organization_id=to_context.get("organization_id"),
        callee_msp_id=to_context.get("msp_id"),
        twilio_call_sid=call_sid or None,
        leg_role="conference_caller",
        status=call_status,
        callback_event="completed",
        duration_seconds=parse_twilio_duration_seconds(form),
    )
    logger.info(
        "[TwilioVoice] Caller leg complete Room=%s CallSid=%s Status=%s",
        room,
        call_sid,
        call_status,
    )
    if room:
        cancel_room_invite(room, reason=f"caller_{call_status or 'complete'}")
    return PlainTextResponse(
        '<?xml version="1.0" encoding="UTF-8"?><Response></Response>',
        media_type="application/xml",
    )


@app.api_route("/calls/conference-status", methods=["GET", "POST"])
async def conference_status(request: Request) -> dict[str, str]:
    form = await request.form() if request.method == "POST" else {}
    params = request.query_params
    room = (form.get("room") or params.get("room") or "").strip()
    call_sid = (form.get("CallSid") or "").strip()
    call_status = (form.get("CallStatus") or "").strip()
    callback_event = (form.get("CallbackEvent") or form.get("StatusCallbackEvent") or call_status or "").strip()
    to_value = (form.get("To") or "").strip()
    from_value = (form.get("From") or "").strip()
    from_context = voice_context_from_mapping(params, prefix="from")
    if not voice_context_is_present(from_context):
        from_context = voice_context_from_binding(from_value)
    to_context = voice_context_from_mapping(params, prefix="to")
    if not voice_context_is_present(to_context):
        to_context = voice_context_from_binding(to_value)
    session_key = call_session_key(
        session_key=params.get("session"),
        room=room,
        call_sid=call_sid,
    )
    rest_caller_identity = os.getenv("TWILIO_REST_CLIENT_CALLER_ID", "vericall")
    tracked_from = "" if from_value in {rest_caller_identity, f"client:{rest_caller_identity}"} else from_value
    record_call_event_safely(
        canonical_key=session_key,
        room=room or None,
        caller_identity=tracked_from or None,
        callee_identity=to_value or None,
        caller_membership_id=from_context.get("membership_id"),
        caller_organization_id=from_context.get("organization_id"),
        caller_msp_id=from_context.get("msp_id"),
        callee_membership_id=to_context.get("membership_id"),
        callee_organization_id=to_context.get("organization_id"),
        callee_msp_id=to_context.get("msp_id"),
        twilio_call_sid=call_sid or None,
        leg_role="conference_callee",
        status=call_status,
        callback_event=callback_event,
        duration_seconds=parse_twilio_duration_seconds(form),
    )
    logger.info(
        "[TwilioVoice] Conference status Room=%s CallSid=%s Status=%s From=%s To=%s",
        room,
        call_sid,
        call_status,
        from_value,
        to_value,
    )
    if room and call_sid == pending_invites_by_room.get(room) and call_status in {
        "answered",
        "completed",
        "busy",
        "failed",
        "no-answer",
        "canceled",
    }:
        pending_invites_by_room.pop(room, None)
    return {"status": "ok"}
