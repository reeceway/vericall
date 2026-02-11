import os
import hashlib
import hmac
import random
import logging
from datetime import datetime, timedelta
from typing import Optional, Tuple
from uuid import UUID

from jose import JWTError, jwt
from passlib.context import CryptContext
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

# Initialize Twilio client
twilio_client = None
if TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN:
    twilio_client = TwilioClient(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
    logger.info("Twilio client initialized")
else:
    logger.warning("Twilio credentials not set - SMS will not be sent")


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