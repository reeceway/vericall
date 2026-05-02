from dotenv import load_dotenv
try:
    load_dotenv()
except OSError:
    pass
from fastapi import FastAPI, Depends, HTTPException, WebSocket, Header, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import select, or_, and_, func
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List, Optional, Dict
from datetime import datetime, timedelta
from uuid import UUID, uuid4
import hmac
import logging

from app.database import get_db, init_db
from app.models import User, Device, Call, RefreshToken
from app.auth import (
    generate_otp, verify_otp, create_access_token,
    create_refresh_token, verify_refresh_token, REFRESH_TOKEN_EXPIRE_DAYS,
    latest_staging_smoke_otp, normalize_phone as normalize_auth_phone,
    staging_smoke_enabled, staging_smoke_secret
)
from app.crypto import (
    verify_ecdsa_signature, get_public_key_fingerprint,
    format_call_signature_message
)
from app.websocket import handle_websocket, WebSocketManager
from app.push import send_call_handshake_push
from app.logger import (
    RequestLogger, AuthLogger, CryptoLogger, CallLogger,
    ErrorLogger, log_call
)

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(
    title="VeriCall API",
    description="Secure caller verification and WebRTC signaling",
    version="1.0.0"
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Startup event
@app.on_event("startup")
async def startup_event():
    await init_db()
    logger.info("Database initialized")


# ============= Pydantic Models =============

class RequestOTPRequest(BaseModel):
    phone_number: str = Field(..., min_length=10, max_length=20)


class RequestOTPResponse(BaseModel):
    message: str
    phone_number: str


class VerifyOTPRequest(BaseModel):
    phone_number: str
    otp: str
    public_key: str
    device_name: Optional[str] = None


class CheckOTPRequest(BaseModel):
    phone_number: str = Field(..., min_length=10, max_length=20)
    otp: str = Field(..., min_length=4, max_length=12)


class CheckOTPResponse(BaseModel):
    ok: bool
    phone_number: str


class VerifyOTPResponse(BaseModel):
    access_token: str
    refresh_token: str
    user_id: UUID
    device_id: UUID
    expires_in: int = 1800  # 30 minutes in seconds


class RefreshTokenRequest(BaseModel):
    refresh_token: str


class RefreshTokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int = 1800


class ContactSyncRequest(BaseModel):
    phone_numbers: Optional[List[str]] = None
    contacts: Optional[List[str]] = None  # iOS sends "contacts" field

    @property
    def numbers(self) -> List[str]:
        return self.phone_numbers or self.contacts or []


class ContactInfo(BaseModel):
    phone_number: str
    name: Optional[str]
    public_key_fingerprint: str


class ContactSyncResponse(BaseModel):
    contacts: List[ContactInfo]


class CallInitiateRequest(BaseModel):
    recipient_id: UUID
    timestamp: int
    nonce: str
    signature: str


class CallInitiateResponse(BaseModel):
    call_id: UUID
    verified: bool
    message: Optional[str] = None


class CallAnswerRequest(BaseModel):
    call_id: UUID


class CallEndRequest(BaseModel):
    call_id: UUID


class RegisterPushTokenRequest(BaseModel):
    push_token: str = Field(..., min_length=10)
    token_type: str = Field(..., pattern="^(apns|voip)$")
    platform: str = Field(default="ios")


def require_staging_smoke_secret(provided_secret: Optional[str]) -> str:
    if not staging_smoke_enabled():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Not found"
        )
    configured_secret = staging_smoke_secret()
    if not configured_secret:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Staging smoke secret is not configured"
        )
    if not provided_secret or not hmac.compare_digest(provided_secret, configured_secret):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid staging ops secret"
        )
    return configured_secret


# ============= Auth Endpoints =============

@app.post("/auth/request-otp", response_model=RequestOTPResponse)
async def request_otp(request: RequestOTPRequest):
    """Request an OTP for phone number verification."""
    try:
        otp = generate_otp(request.phone_number)
    except RuntimeError as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=str(e)
        )

    return RequestOTPResponse(
        message="Verification code sent via SMS",
        phone_number=request.phone_number
    )


@app.get("/auth/staging/otp/latest")
async def get_staging_otp(
    phone_number: str,
    x_vicall_staging_ops_secret: Optional[str] = Header(default=None, alias="X-Vicall-Staging-Ops-Secret"),
):
    """Return the latest OTP for the requested phone in dedicated staging smoke environments."""
    require_staging_smoke_secret(x_vicall_staging_ops_secret)
    normalized_phone = normalize_auth_phone(phone_number)
    if not normalized_phone:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="phone_number is required"
        )
    cached_otp = latest_staging_smoke_otp(normalized_phone)
    if not cached_otp or not cached_otp.get("otp"):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No staging OTP available for phone number"
        )
    return {
        "status": "ready",
        "phone_number": normalized_phone,
        "otp": cached_otp["otp"],
        "captured_at": cached_otp.get("captured_at"),
    }


@app.post("/auth/check-otp", response_model=CheckOTPResponse)
async def check_otp(request: CheckOTPRequest):
    """Verify an OTP without creating app users, devices, or tokens.

    This is used by the MSP portal login flow. The mobile app should continue
    using /auth/verify-otp so device-bound app sessions are created normally.
    """
    normalized_phone = normalize_auth_phone(request.phone_number)
    if not verify_otp(normalized_phone, request.otp):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid or expired OTP"
        )
    return CheckOTPResponse(ok=True, phone_number=normalized_phone)


@app.post("/auth/verify-otp", response_model=VerifyOTPResponse)
async def verify_otp_endpoint(
    request: VerifyOTPRequest,
    db: AsyncSession = Depends(get_db)
):
    """Verify OTP and create user/device."""
    # Verify OTP
    if not verify_otp(request.phone_number, request.otp):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid or expired OTP"
        )
    
    # Get or create user – normalize the phone number
    clean_phone = normalize_phone(request.phone_number)
    from sqlalchemy import func as sa_func
    db_normalized = sa_func.regexp_replace(User.phone_number, '[^0-9+]', '', 'g')
    result = await db.execute(
        select(User).where(or_(User.phone_number == clean_phone, db_normalized == clean_phone))
    )
    user = result.scalar_one_or_none()
    
    if not user:
        user = User(
            phone_number=clean_phone,
            name=None
        )
        db.add(user)
        await db.flush()  # Get user.id
    
    # Generate device fingerprint
    fingerprint = get_public_key_fingerprint(request.public_key)
    
    # Check if device exists
    result = await db.execute(
        select(Device).where(Device.fingerprint == fingerprint)
    )
    device = result.scalar_one_or_none()
    
    if device:
        # Update device if exists
        device.public_key = request.public_key
        if request.device_name:
            device.device_name = request.device_name
    else:
        # Create new device
        device = Device(
            user_id=user.id,
            public_key=request.public_key,
            fingerprint=fingerprint,
            device_name=request.device_name or "Unknown Device"
        )
        db.add(device)
        await db.flush()
    
    # Create tokens
    access_token = create_access_token(user.id, device.id)
    refresh_token, refresh_token_hash = create_refresh_token()
    
    # Store refresh token
    refresh_token_record = RefreshToken(
        user_id=user.id,
        token_hash=refresh_token_hash,
        expires_at=datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    )
    db.add(refresh_token_record)
    
    return VerifyOTPResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user_id=user.id,
        device_id=device.id,
        expires_in=1800
    )


@app.post("/auth/refresh", response_model=RefreshTokenResponse)
async def refresh_token(
    request: RefreshTokenRequest,
    db: AsyncSession = Depends(get_db)
):
    """Refresh access token."""
    # Find refresh token in database
    from app.auth import decode_access_token  # Import here to avoid circular import
    
    result = await db.execute(
        select(RefreshToken, User, Device)
        .join(User, RefreshToken.user_id == User.id)
        .join(Device, Device.user_id == User.id)
        .where(RefreshToken.expires_at > datetime.utcnow())
    )
    
    # Check all valid refresh tokens
    for token_record, user, device in result.all():
        if verify_refresh_token(request.refresh_token, token_record.token_hash):
            # Generate new tokens
            new_access_token = create_access_token(user.id, device.id)
            new_refresh_token, new_refresh_hash = create_refresh_token()
            
            # Update refresh token
            token_record.token_hash = new_refresh_hash
            token_record.expires_at = datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
            
            return RefreshTokenResponse(
                access_token=new_access_token,
                refresh_token=new_refresh_token,
                expires_in=1800
            )
    
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired refresh token"
    )


# ============= User Endpoints =============

class UserLookupRequest(BaseModel):
    phone_number: str


class UserResponse(BaseModel):
    id: UUID
    phone_number: str
    display_name: Optional[str] = None
    created_at: Optional[datetime] = None

    class Config:
        from_attributes = True


class UserLookupResponse(BaseModel):
    user: Optional[UserResponse] = None
    found: bool


class UpdateProfileRequest(BaseModel):
    display_name: str


def normalize_phone(raw: str) -> str:
    """Strip all formatting from a phone number, keep only digits and +."""
    return ''.join(c for c in raw if c.isdigit() or c == '+')


@app.post("/users/lookup", response_model=UserLookupResponse)
async def lookup_user(
    request: UserLookupRequest,
    db: AsyncSession = Depends(get_db)
):
    """Look up a VeriCall user by phone number."""
    normalized = normalize_phone(request.phone_number)
    logger.info(f"[Lookup] Looking up phone: '{request.phone_number}' → normalized: '{normalized}'")
    
    # Use SQL regexp_replace to strip formatting from stored numbers too
    # This handles stored values like '(412) 862-8887' matching input '4128628887'
    from sqlalchemy import text
    db_normalized = func.regexp_replace(User.phone_number, '[^0-9+]', '', 'g')
    
    # Build list of values to try
    candidates = [normalized]
    if normalized.startswith('+'):
        candidates.append(normalized[1:])  # without +
    if normalized.startswith('+61'):
        candidates.append('0' + normalized[3:])  # +61 → 0
    if normalized.startswith('0'):
        candidates.append('+61' + normalized[1:])  # 0 → +61
    # Also try without leading +1 for US numbers
    if normalized.startswith('+1'):
        candidates.append(normalized[2:])  # +14128628887 → 4128628887
    if len(normalized) == 10 and normalized.isdigit():
        candidates.append('+1' + normalized)  # 4128628887 → +14128628887
    
    result = await db.execute(
        select(User).where(db_normalized.in_(candidates))
    )
    user = result.scalar_one_or_none()

    if user:
        logger.info(f"[Lookup] ✅ FOUND user {user.id} with phone '{user.phone_number}' name='{user.name}'")
        return UserLookupResponse(
            user=UserResponse(
                id=user.id,
                phone_number=user.phone_number,
                display_name=user.name,
                created_at=user.created_at
            ),
            found=True
        )

    logger.info(f"[Lookup] ❌ NOT FOUND for phone '{normalized}' (tried {candidates})")
    return UserLookupResponse(user=None, found=False)


@app.patch("/users/me", response_model=UserResponse)
async def update_profile(
    request: UpdateProfileRequest,
    db: AsyncSession = Depends(get_db)
):
    """Update the current user's profile. Requires Authorization header."""
    from app.auth import decode_access_token
    from fastapi import Request as FastAPIRequest

    # For now, find user by most recently created (simplified)
    # In production, extract from JWT Authorization header
    result = await db.execute(
        select(User).order_by(User.created_at.desc()).limit(1)
    )
    user = result.scalar_one_or_none()

    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )

    user.name = request.display_name
    await db.flush()

    return UserResponse(
        id=user.id,
        phone_number=user.phone_number,
        display_name=user.name,
        created_at=user.created_at
    )


# ============= Contacts Endpoints =============

@app.post("/contacts/sync", response_model=ContactSyncResponse)
async def sync_contacts(
    request: ContactSyncRequest,
    db: AsyncSession = Depends(get_db)
):
    """Sync contacts - return users that match provided phone numbers with their fingerprints."""
    numbers = request.numbers
    if not numbers:
        return ContactSyncResponse(contacts=[])

    # Normalize phone numbers and build variations (e.g. 04xx <-> +614xx)
    all_variations = set()
    for pn in numbers:
        normalized = ''.join(c for c in pn if c.isdigit() or c == '+')
        all_variations.add(normalized)
        # Australian: 04xx -> +614xx
        if normalized.startswith('0') and len(normalized) == 10:
            all_variations.add('+61' + normalized[1:])
        # Australian: +614xx -> 04xx
        if normalized.startswith('+61'):
            all_variations.add('0' + normalized[3:])

    # Query users with matching phone numbers
    result = await db.execute(
        select(User, Device)
        .join(Device, Device.user_id == User.id)
        .where(User.phone_number.in_(list(all_variations)))
    )
    
    # Build contact list (one entry per device, unique fingerprint)
    seen_fingerprints = set()
    contacts = []
    
    for user, device in result.all():
        if device.fingerprint not in seen_fingerprints:
            seen_fingerprints.add(device.fingerprint)
            contacts.append(ContactInfo(
                phone_number=user.phone_number,
                name=user.name,
                public_key_fingerprint=device.fingerprint
            ))
    
    return ContactSyncResponse(contacts=contacts)


# ============= Call Endpoints =============

@app.post("/calls/initiate", response_model=CallInitiateResponse)
async def initiate_call(
    request: CallInitiateRequest,
    db: AsyncSession = Depends(get_db)
    # Note: In production, add JWT dependency here
):
    """Initiate a call with device verification."""
    # Get caller's device (in production, get from JWT)
    # For now, we'll find the caller by looking up devices
    
    # Get recipient
    result = await db.execute(
        select(User).where(User.id == request.recipient_id)
    )
    recipient = result.scalar_one_or_none()
    
    if not recipient:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipient not found"
        )
    
    # Find caller by signature verification
    # In production, this should be determined from JWT
    # For this implementation, we'll need to verify against all possible caller devices
    
    # For demo purposes, we'll create the call and mark as verified
    # The actual verification would require knowing the caller's device from auth
    
    call = Call(
        caller_id=request.recipient_id,  # Placeholder - should be from auth
        recipient_id=request.recipient_id,
        device_verified=False,  # Will be updated after verification
        started_at=None
    )
    db.add(call)
    await db.flush()
    
    # Create message to verify
    message = format_call_signature_message(
        str(call.caller_id),
        str(call.recipient_id),
        request.timestamp,
        request.nonce
    )
    
    # Find caller's device by verifying signature
    verified = False
    caller_id = None
    
    result = await db.execute(select(Device))
    all_devices = result.scalars().all()
    
    for device in all_devices:
        if verify_ecdsa_signature(device.public_key, message, request.signature):
            verified = True
            call.caller_id = device.user_id
            call.device_verified = True
            call.started_at = datetime.utcnow()
            caller_id = device.user_id
            break
    
    if not verified:
        await db.delete(call)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid signature - device verification failed"
        )
    
    # Notify recipient via WebSocket if they're online
    if WebSocketManager.is_user_online(call.recipient_id):
        await WebSocketManager.send_to_user(call.recipient_id, {
            "type": "call:incoming",
            "call_id": str(call.id),
            "caller_id": str(call.caller_id),
        })
    
    return CallInitiateResponse(
        call_id=call.id,
        verified=verified,
        message="Call initiated successfully" if verified else "Verification failed"
    )


@app.post("/calls/{call_id}/answer")
async def answer_call(
    call_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """Mark a call as answered."""
    result = await db.execute(
        select(Call).where(Call.id == call_id)
    )
    call = result.scalar_one_or_none()
    
    if not call:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Call not found"
        )
    
    call.started_at = datetime.utcnow()
    
    return {
        "call_id": call_id,
        "status": "answered",
        "caller_id": str(call.caller_id),
    }


@app.post("/calls/{call_id}/end")
async def end_call(
    call_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    """Mark a call as ended."""
    result = await db.execute(
        select(Call).where(Call.id == call_id)
    )
    call = result.scalar_one_or_none()
    
    if not call:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Call not found"
        )
    
    call.ended_at = datetime.utcnow()
    
    duration = None
    if call.started_at:
        duration = (call.ended_at - call.started_at).total_seconds()
    
    return {
        "call_id": call_id,
        "status": "ended",
        "duration_seconds": duration
    }


# ============= WebSocket Endpoint =============

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time call signaling."""
    await handle_websocket(websocket)


# ============= Device Endpoints =============

@app.post("/devices/push-token")
async def register_push_token(
    request: RegisterPushTokenRequest,
    db: AsyncSession = Depends(get_db),
    authorization: Optional[str] = Header(None)
):
    """
    Register a push token for the current device.
    Requires Authorization header with Bearer token.
    """
    from app.auth import decode_access_token
    
    user_id = None
    device_id = None
    
    # Extract user_id and device_id from JWT
    if authorization and authorization.startswith("Bearer "):
        token = authorization[7:]
        try:
            payload = decode_access_token(token)
            user_id = UUID(payload.get("sub")) if payload.get("sub") else None
            device_id = UUID(payload.get("device_id")) if payload.get("device_id") else None
        except Exception as e:
            logger.warning(f"Failed to decode token for push registration: {e}")
    
    if user_id and device_id:
        # Find the exact device for this user
        result = await db.execute(
            select(Device).where(
                Device.user_id == user_id,
                Device.id == device_id
            )
        )
        device = result.scalar_one_or_none()
    elif user_id:
        # Find any device for this user
        result = await db.execute(
            select(Device).where(Device.user_id == user_id).limit(1)
        )
        device = result.scalar_one_or_none()
    else:
        # Fallback: find device by existing token
        result = await db.execute(
            select(Device).where(
                or_(
                    Device.push_token == request.push_token,
                    Device.voip_token == request.push_token
                )
            ).limit(1)
        )
        device = result.scalar_one_or_none()
    
    if device:
        if request.token_type == "voip":
            device.voip_token = request.push_token
            logger.info(f"Registered VoIP token for device {device.id} (user {device.user_id})")
        else:
            device.push_token = request.push_token
            logger.info(f"Registered push token for device {device.id} (user {device.user_id})")
        await db.commit()
    else:
        logger.warning(f"No device found for push token registration (user_id={user_id}, device_id={device_id})")
    
    return {"status": "registered", "token_type": request.token_type}


# ============= Health Check =============

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "vericall-api"}
