import os
import hashlib
import hmac
from datetime import datetime, timedelta
from typing import Optional, Tuple
from uuid import UUID

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.logger import AuthLogger

# Configuration
SECRET_KEY = os.getenv("SECRET_KEY", "your-secret-key-change-in-production")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30
REFRESH_TOKEN_EXPIRE_DAYS = 7

# Password hashing context (for token hashes)
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Mock OTP for hackathon
MOCK_OTP = "123456"


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
    # Generate random token
    token_bytes = os.urandom(32)
    token = token_bytes.hex()
    
    # Hash the token for storage
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


# Mock OTP storage (in-memory for hackathon)
_pending_otps: dict[str, Tuple[str, datetime]] = {}


def generate_otp(phone_number: str) -> str:
    """Generate and store OTP for phone number. Returns the OTP for logging."""
    # For hackathon: always use mock OTP
    otp = MOCK_OTP
    
    # Store with 5 minute expiry
    expiry = datetime.utcnow() + timedelta(minutes=5)
    _pending_otps[phone_number] = (otp, expiry)
    
    AuthLogger.log_otp_request(phone_number, success=True)
    return otp


def verify_otp(phone_number: str, otp: str) -> bool:
    """Verify OTP for phone number."""
    if phone_number not in _pending_otps:
        AuthLogger.log_otp_verify(phone_number, success=False, error="No pending OTP")
        return False
    
    stored_otp, expiry = _pending_otps[phone_number]
    
    # Check expiry
    if datetime.utcnow() > expiry:
        del _pending_otps[phone_number]
        AuthLogger.log_otp_verify(phone_number, success=False, error="OTP expired")
        return False
    
    # Verify OTP
    if stored_otp == otp:
        del _pending_otps[phone_number]
        AuthLogger.log_otp_verify(phone_number, success=True)
        return True
    
    AuthLogger.log_otp_verify(phone_number, success=False, error="Invalid OTP")
    return False
