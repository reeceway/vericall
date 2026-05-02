import os
import hashlib
import hmac
import time
import logging
from datetime import datetime, timedelta
from typing import Optional, Tuple
from uuid import UUID

from jose import JWTError, jwt
from passlib.context import CryptContext
from twilio.http.http_client import TwilioHttpClient
from twilio.rest import Client as TwilioClient

from app.logger import AuthLogger

logger = logging.getLogger(__name__)

# Configuration
SECRET_KEY = os.getenv("SECRET_KEY", "your-secret-key-change-in-production")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30
REFRESH_TOKEN_EXPIRE_DAYS = 7

# Password hashing context (for token hashes)
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Twilio configuration
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID")
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN")
TWILIO_VERIFY_SID = os.getenv("TWILIO_VERIFY_SID")
TWILIO_HTTP_TIMEOUT_SECONDS = float(os.getenv("TWILIO_HTTP_TIMEOUT_SECONDS", "8"))
TWILIO_HTTP_MAX_RETRIES = int(os.getenv("TWILIO_HTTP_MAX_RETRIES", "1"))

# Initialize Twilio client
twilio_client = None
if TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN:
    twilio_http_client = TwilioHttpClient(
        timeout=TWILIO_HTTP_TIMEOUT_SECONDS,
        max_retries=TWILIO_HTTP_MAX_RETRIES,
    )
    twilio_client = TwilioClient(
        TWILIO_ACCOUNT_SID,
        TWILIO_AUTH_TOKEN,
        http_client=twilio_http_client,
    )
    logger.info("Twilio client initialized")
else:
    logger.warning("Twilio credentials not set - SMS will not be sent")

TRUTHY_ENV_VALUES = {"1", "true", "yes", "on"}
_STAGING_SMOKE_OTPS: dict[str, dict[str, str]] = {}


def env_truthy(name: str) -> bool:
    return (os.getenv(name) or "").strip().lower() in TRUTHY_ENV_VALUES


def staging_smoke_secret() -> Optional[str]:
    return (os.getenv("VICALL_STAGING_SMOKE_SECRET") or "").strip() or None


def staging_smoke_otp_window_seconds() -> int:
    try:
        return max(60, int(os.getenv("VICALL_STAGING_SMOKE_OTP_WINDOW_SECONDS", "300")))
    except ValueError:
        return 300


def staging_smoke_enabled() -> bool:
    if not env_truthy("VICALL_STAGING_SMOKE_ENABLED"):
        return False
    if any(
        (os.getenv(name) or "").strip().lower() == "production"
        for name in ("APP_ENV", "ENV", "ENVIRONMENT", "VICALL_ENVIRONMENT")
    ):
        return False
    return bool(staging_smoke_secret())


def staging_smoke_allowed(phone_number: str) -> bool:
    if not staging_smoke_enabled():
        return False
    normalized_phone = normalize_phone(phone_number)
    configured_allowlist = [
        normalize_phone(value)
        for value in os.getenv("VICALL_STAGING_SMOKE_PHONE_NUMBERS", "").replace("\n", ",").split(",")
        if value.strip()
    ]
    if configured_allowlist:
        return normalized_phone in configured_allowlist
    return True


def staging_smoke_otp_for_phone(phone_number: str, bucket: Optional[int] = None) -> Optional[str]:
    secret = staging_smoke_secret()
    if not secret:
        return None
    normalized_phone = normalize_phone(phone_number)
    otp_window = staging_smoke_otp_window_seconds()
    otp_bucket = bucket if bucket is not None else int(time.time()) // otp_window
    digest = hmac.new(
        secret.encode("utf-8"),
        f"{normalized_phone}:{otp_bucket}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return f"{int(digest[:12], 16) % 1000000:06d}"


def latest_staging_smoke_otp(phone_number: str) -> Optional[dict[str, str]]:
    normalized_phone = normalize_phone(phone_number)
    if not staging_smoke_allowed(normalized_phone):
        return None
    otp = staging_smoke_otp_for_phone(normalized_phone)
    if not otp:
        return None
    cached = _STAGING_SMOKE_OTPS.get(normalized_phone, {})
    return {
        "otp": otp,
        "captured_at": cached.get("captured_at") or datetime.utcnow().isoformat() + "Z",
    }


def create_access_token(user_id: UUID, device_id: UUID) -> str:
    """Create a new access token for user."""
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {
        "sub": str(user_id),
        "device_id": str(device_id),
        "exp": expire,
        "type": "access"
    }
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


def create_refresh_token() -> Tuple[str, str]:
    """Create a new refresh token and its hash."""
    token_bytes = os.urandom(32)
    token = token_bytes.hex()
    token_hash = hashlib.sha256(token_bytes).hexdigest()
    return token, token_hash


def verify_refresh_token(provided_token: str, stored_hash: str) -> bool:
    """Verify a refresh token against its stored hash."""
    token_bytes = bytes.fromhex(provided_token)
    computed_hash = hashlib.sha256(token_bytes).hexdigest()
    return hmac.compare_digest(computed_hash, stored_hash)


def decode_access_token(token: str) -> Optional[dict]:
    """Decode and validate an access token."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("type") != "access":
            return None
        return payload
    except JWTError:
        return None


def get_user_id_from_token(token: str) -> Optional[UUID]:
    """Extract user ID from access token."""
    payload = decode_access_token(token)
    if payload and "sub" in payload:
        return UUID(payload["sub"])
    return None


def get_device_id_from_token(token: str) -> Optional[UUID]:
    """Extract device ID from access token."""
    payload = decode_access_token(token)
    if payload and "device_id" in payload:
        return UUID(payload["device_id"])
    return None


def normalize_phone(phone_number: str) -> str:
    """Normalize phone number to E.164 format (+1XXXXXXXXXX)."""
    digits = ''.join(c for c in phone_number if c.isdigit())
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    if phone_number.startswith("+"):
        return f"+{digits}"
    return f"+{digits}"


def generate_otp(phone_number: str) -> str:
    """Send OTP via Twilio Verify service."""
    phone_number = normalize_phone(phone_number)
    if staging_smoke_allowed(phone_number):
        otp = staging_smoke_otp_for_phone(phone_number)
        if not otp:
            raise RuntimeError("Staging smoke OTP is not configured")
        _STAGING_SMOKE_OTPS[phone_number] = {
            "otp": otp,
            "captured_at": datetime.utcnow().isoformat() + "Z",
        }
        logger.info("Staging smoke OTP issued for %s", phone_number)
        AuthLogger.log_otp_request(phone_number, success=True)
        return "sent"

    if twilio_client and TWILIO_VERIFY_SID:
        try:
            verification = twilio_client.verify \
                .v2 \
                .services(TWILIO_VERIFY_SID) \
                .verifications \
                .create(to=phone_number, channel="sms")
            logger.info(f"Verify SMS sent to {phone_number}, status: {verification.status}")
        except Exception as e:
            logger.error(f"Failed to send Verify SMS to {phone_number}: {e}")
            raise RuntimeError(f"Failed to send verification SMS: {e}")
    else:
        logger.warning(f"Twilio Verify not configured for {phone_number}")
        raise RuntimeError("SMS service not configured")

    AuthLogger.log_otp_request(phone_number, success=True)
    return "sent"


def verify_otp(phone_number: str, otp: str) -> bool:
    """Verify OTP via Twilio Verify service."""
    phone_number = normalize_phone(phone_number)
    if staging_smoke_allowed(phone_number):
        otp_window = staging_smoke_otp_window_seconds()
        current_bucket = int(time.time()) // otp_window
        submitted_otp = str(otp or "").strip()
        valid_otps = [
            staging_smoke_otp_for_phone(phone_number, bucket=current_bucket),
            staging_smoke_otp_for_phone(phone_number, bucket=current_bucket - 1),
        ]
        if any(
            candidate and hmac.compare_digest(candidate, submitted_otp)
            for candidate in valid_otps
        ):
            AuthLogger.log_otp_verify(phone_number, success=True)
            _STAGING_SMOKE_OTPS.pop(phone_number, None)
            return True
        AuthLogger.log_otp_verify(phone_number, success=False, error="Invalid staging smoke OTP")
        return False

    if twilio_client and TWILIO_VERIFY_SID:
        try:
            verification_check = twilio_client.verify \
                .v2 \
                .services(TWILIO_VERIFY_SID) \
                .verification_checks \
                .create(to=phone_number, code=otp)
            if verification_check.status == "approved":
                AuthLogger.log_otp_verify(phone_number, success=True)
                return True
            else:
                AuthLogger.log_otp_verify(phone_number, success=False, error=f"Status: {verification_check.status}")
                return False
        except Exception as e:
            logger.error(f"Verify check failed for {phone_number}: {e}")
            AuthLogger.log_otp_verify(phone_number, success=False, error=str(e))
            return False
    else:
        AuthLogger.log_otp_verify(phone_number, success=False, error="Twilio Verify not configured")
        return False
