from dotenv import load_dotenv
load_dotenv()
from fastapi import FastAPI, Depends, HTTPException, WebSocket, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import select, or_, and_
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List, Optional, Dict
from datetime import datetime, timedelta
from uuid import UUID, uuid4
import logging

from app.database import get_db, init_db
from app.models import User, Device, Call, RefreshToken
from app.auth import (
    generate_otp, verify_otp, create_access_token,
    create_refresh_token, verify_refresh_token, REFRESH_TOKEN_EXPIRE_DAYS
)
from app.crypto import (
    verify_ecdsa_signature, get_public_key_fingerprint,
    format_call_signature_message
)
from app.websocket import handle_websocket, WebSocketManager
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
    phone_numbers: List[str]


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
    voice_thumbprint: Optional[List[float]] = None  # Array of 192 floats for voice verification


class CallInitiateResponse(BaseModel):
    call_id: UUID
    verified: bool
    message: Optional[str] = None


class CallAnswerRequest(BaseModel):
    call_id: UUID


class CallEndRequest(BaseModel):
    call_id: UUID


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
    
    # Get or create user
    result = await db.execute(
        select(User).where(User.phone_number == request.phone_number)
    )
    user = result.scalar_one_or_none()
    
    if not user:
        user = User(
            phone_number=request.phone_number,
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


# ============= Contacts Endpoints =============

@app.post("/contacts/sync", response_model=ContactSyncResponse)
async def sync_contacts(
    request: ContactSyncRequest,
    db: AsyncSession = Depends(get_db)
):
    """Sync contacts - return users that match provided phone numbers with their fingerprints."""
    if not request.phone_numbers:
        return ContactSyncResponse(contacts=[])
    
    # Normalize phone numbers (remove spaces, dashes, etc.)
    normalized_numbers = [
        ''.join(c for c in pn if c.isdigit() or c == '+')
        for pn in request.phone_numbers
    ]
    
    # Query users with matching phone numbers
    result = await db.execute(
        select(User, Device)
        .join(Device, Device.user_id == User.id)
        .where(User.phone_number.in_(normalized_numbers))
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
        voice_thumbprint=request.voice_thumbprint,  # Store voice thumbprint for verification
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
            "voice_thumbprint": call.voice_thumbprint  # Include caller's voice thumbprint
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
        "voice_thumbprint": call.voice_thumbprint  # Include caller's voice thumbprint for verification
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


# ============= Health Check =============

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "vericall-api"}
