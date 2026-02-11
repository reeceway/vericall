import json
from typing import Dict, Optional, List
from uuid import UUID

from fastapi import WebSocket, WebSocketDisconnect
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import decode_access_token, get_user_id_from_token, get_device_id_from_token
from app.database import AsyncSessionLocal
from app.models import User, Device
from app.push import send_call_handshake_push


# Active WebSocket connections: user_id -> WebSocket
active_connections: Dict[UUID, WebSocket] = {}

# Call matching pool: users who are in a call and waiting to be matched
# user_id -> { "timestamp": float, "voiceThumbprint": [...], "direction": "outgoing"|"incoming" }
import time
pending_callers: Dict[UUID, dict] = {}

# How long (seconds) a caller stays in the matching pool
MATCH_WINDOW_SECONDS = 30


class WebSocketManager:
    """Manages WebSocket connections for real-time call signaling."""
    
    @staticmethod
    async def connect(websocket: WebSocket, token: str):
        """Authenticate and connect a WebSocket."""
        await websocket.accept()
        
        # Validate token
        payload = decode_access_token(token)
        if not payload:
            print("[WebSocket] Token validation failed - invalid or expired")
            await websocket.send_json({
                "type": "error",
                "message": "Invalid or expired token"
            })
            await websocket.close(code=4001)
            return None
        
        user_id = UUID(payload["sub"])
        device_id = UUID(payload["device_id"])
        
        print(f"[WebSocket] ✅ Token valid for user {user_id}")
        
        # Store connection
        active_connections[user_id] = websocket
        
        await websocket.send_json({
            "type": "connected",
            "user_id": str(user_id),
            "device_id": str(device_id)
        })
        
        print(f"[WebSocket] ✅ Sent connected message to user {user_id}")
        
        return user_id
    
    @staticmethod
    async def disconnect(user_id: UUID):
        """Remove a WebSocket connection."""
        if user_id in active_connections:
            del active_connections[user_id]
    
    @staticmethod
    async def send_to_user(user_id: UUID, message: dict):
        """Send a message to a specific user."""
        if user_id in active_connections:
            websocket = active_connections[user_id]
            await websocket.send_json(message)
            return True
        return False
    
    @staticmethod
    def is_user_online(user_id: UUID) -> bool:
        """Check if a user is currently connected."""
        return user_id in active_connections


async def get_user_by_phone(phone_number: str) -> Optional[User]:
    """Look up a user by their phone number."""
    # Normalize phone number (remove spaces, dashes, etc.)
    normalized = ''.join(c for c in phone_number if c.isdigit() or c == '+')
    
    async with AsyncSessionLocal() as session:
        # Try exact match first
        result = await session.execute(
            select(User).where(User.phone_number == normalized)
        )
        user = result.scalar_one_or_none()
        
        if not user:
            # Try without country code prefix variations
            if normalized.startswith('+'):
                # Try without the +
                result = await session.execute(
                    select(User).where(User.phone_number == normalized[1:])
                )
                user = result.scalar_one_or_none()
            
            if not user and normalized.startswith('+61'):
                # Australian number - try with 0 prefix instead
                result = await session.execute(
                    select(User).where(User.phone_number == '0' + normalized[3:])
                )
                user = result.scalar_one_or_none()
            
            if not user and normalized.startswith('0'):
                # Try with +61 prefix (Australian)
                result = await session.execute(
                    select(User).where(User.phone_number == '+61' + normalized[1:])
                )
                user = result.scalar_one_or_none()
        
        return user


async def get_user_voip_token(user_id: UUID) -> Optional[str]:
    """Get the VoIP push token for a user's device."""
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(Device).where(
                Device.user_id == user_id,
                Device.voip_token.isnot(None)
            )
        )
        device = result.scalar_one_or_none()
        return device.voip_token if device else None


async def handle_websocket(websocket: WebSocket):
    """Main WebSocket handler."""
    user_id: Optional[UUID] = None
    
    print(f"[WebSocket] New connection attempt from {websocket.client}")
    
    try:
        # Get token from query parameter
        token = websocket.query_params.get("token")
        if not token:
            print("[WebSocket] No token provided in query params")
            await websocket.close(code=4001)
            return
        
        print(f"[WebSocket] Token received: {token[:20]}...")
        
        # Authenticate
        user_id = await WebSocketManager.connect(websocket, token)
        if not user_id:
            print("[WebSocket] Authentication failed")
            return
        
        print(f"[WebSocket] ✅ User {user_id} connected successfully")
        
        # Main message loop
        while True:
            try:
                data = await websocket.receive_text()
                print(f"[WebSocket] Received from {user_id}: {data[:100]}...")
                message = json.loads(data)
                
                await process_message(user_id, message, websocket)
                
            except json.JSONDecodeError:
                await websocket.send_json({
                    "type": "error",
                    "message": "Invalid JSON"
                })
    
    except WebSocketDisconnect:
        print(f"[WebSocket] User {user_id} disconnected")
    except Exception as e:
        print(f"[WebSocket] Error: {e}")
    finally:
        if user_id:
            await WebSocketManager.disconnect(user_id)
            print(f"[WebSocket] Cleaned up connection for {user_id}")


async def process_message(sender_id: UUID, message: dict, websocket: WebSocket):
    """Process incoming WebSocket messages."""
    msg_type = message.get("type")
    
    if msg_type == "call:initiate":
        await handle_call_initiate(sender_id, message, websocket)
    elif msg_type == "call:answer":
        await handle_call_answer(sender_id, message, websocket)
    elif msg_type == "call:end":
        await handle_call_end(sender_id, message, websocket)
    elif msg_type == "ping":
        await websocket.send_json({"type": "pong"})
    elif msg_type == "native_call:in_call":
        await handle_in_call(sender_id, message, websocket)
    elif msg_type == "native_call:call_ended":
        await handle_call_pool_ended(sender_id, websocket)
    elif msg_type and msg_type.startswith("native_call:"):
        await handle_native_call(sender_id, message, websocket)
    else:
        await websocket.send_json({
            "type": "error",
            "message": f"Unknown message type: {msg_type}"
        })


async def handle_in_call(sender_id: UUID, message: dict, websocket: WebSocket):
    """
    Handle 'I'm in a call' broadcast. No phone number needed.
    The backend matches two VeriCall users who enter calls around the same time.
    """
    voice_thumbprint = message.get("voiceThumbprint")
    direction = message.get("direction", "unknown")
    now = time.time()

    # Get sender info
    sender_display_name = None
    sender_phone = None
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(User).where(User.id == sender_id)
        )
        sender_user = result.scalar_one_or_none()
        if sender_user:
            sender_display_name = sender_user.name
            sender_phone = sender_user.phone_number

    print(f"[CallMatch] User {sender_display_name or sender_id} entered a call ({direction})")

    # Clean up stale entries
    stale = [uid for uid, info in pending_callers.items()
             if now - info["timestamp"] > MATCH_WINDOW_SECONDS]
    for uid in stale:
        del pending_callers[uid]

    # Check if there's already another user in the pool to match with
    match_id = None
    for uid, info in pending_callers.items():
        if uid != sender_id:
            match_id = uid
            break

    if match_id:
        # Found a match! Exchange handshakes between both users
        match_info = pending_callers.pop(match_id)

        # Get matched user's info
        match_display_name = None
        match_phone = None
        async with AsyncSessionLocal() as session:
            result = await session.execute(
                select(User).where(User.id == match_id)
            )
            match_user = result.scalar_one_or_none()
            if match_user:
                match_display_name = match_user.name
                match_phone = match_user.phone_number

        print(f"[CallMatch] MATCHED {sender_display_name} <-> {match_display_name}")

        # Send match_info's voiceprint to sender
        if match_info.get("voiceThumbprint"):
            await WebSocketManager.send_to_user(sender_id, {
                "type": "native_call:handshake",
                "fromUserId": str(match_id),
                "displayName": match_display_name,
                "phoneNumber": match_phone or "",
                "voiceThumbprint": match_info["voiceThumbprint"],
                "timestamp": message.get("timestamp"),
            })

        # Send sender's voiceprint to match
        if voice_thumbprint and WebSocketManager.is_user_online(match_id):
            await WebSocketManager.send_to_user(match_id, {
                "type": "native_call:handshake",
                "fromUserId": str(sender_id),
                "displayName": sender_display_name,
                "phoneNumber": sender_phone or "",
                "voiceThumbprint": voice_thumbprint,
                "timestamp": message.get("timestamp"),
            })

        await websocket.send_json({
            "type": "native_call:matched",
            "matched_user_id": str(match_id),
            "matched_name": match_display_name,
        })

        print(f"[CallMatch] Handshakes exchanged between {sender_id} and {match_id}")
    else:
        # No match yet - add to pool and wait
        pending_callers[sender_id] = {
            "timestamp": now,
            "voiceThumbprint": voice_thumbprint,
            "direction": direction,
            "displayName": sender_display_name,
            "phoneNumber": sender_phone,
        }
        await websocket.send_json({
            "type": "native_call:waiting",
            "message": "Waiting for other party...",
        })
        print(f"[CallMatch] {sender_display_name or sender_id} added to matching pool ({len(pending_callers)} waiting)")


async def handle_call_pool_ended(sender_id: UUID, websocket: WebSocket):
    """Remove user from the matching pool when call ends."""
    if sender_id in pending_callers:
        del pending_callers[sender_id]
        print(f"[CallMatch] Removed {sender_id} from matching pool")
    await websocket.send_json({"type": "native_call:pool_cleared"})


async def handle_native_call(sender_id: UUID, message: dict, websocket: WebSocket):
    """
    Handle native call handshake messages.
    These are used for verifying real phone calls via the carrier network.
    
    Message types:
    - native_call:handshake - Initial handshake with voice thumbprint
    - native_call:request_thumbprint - Request for voice thumbprint verification
    - native_call:handshake_response - Response to handshake with verification result
    """
    msg_type = message.get("type")
    
    # Accept both iOS field names and backend field names
    phone_number = message.get("phoneNumber") or message.get("to_phone")
    recipient_id_str = message.get("recipientId") or message.get("to_user_id")
    
    print(f"[Native Call] Processing {msg_type} from {sender_id}")
    print(f"[Native Call] phoneNumber: {phone_number}, recipientId: {recipient_id_str}")
    
    recipient_id = None
    
    # First try recipientId if provided
    if recipient_id_str:
        try:
            recipient_id = UUID(recipient_id_str)
        except (ValueError, TypeError):
            pass
    
    # Fall back to phone number lookup
    if not recipient_id and phone_number:
        recipient_user = await get_user_by_phone(phone_number)
        if recipient_user:
            recipient_id = recipient_user.id
            print(f"[Native Call] Found user {recipient_id} for phone {phone_number}")
        else:
            print(f"[Native Call] No user found for phone {phone_number}")
    
    if not recipient_id:
        await websocket.send_json({
            "type": "native_call:error",
            "original_type": msg_type,
            "message": "Could not find recipient user"
        })
        return
    
    # Get sender info for the forwarded message
    sender_display_name = None
    sender_phone = None
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(User).where(User.id == sender_id)
        )
        sender_user = result.scalar_one_or_none()
        if sender_user:
            sender_display_name = sender_user.name  # Use 'name' field from User model
            sender_phone = sender_user.phone_number
    
    # Forward the message to the recipient with iOS-compatible field names
    forwarded_message = {
        "type": msg_type,
        "fromUserId": str(sender_id),
        "displayName": sender_display_name,
        "phoneNumber": sender_phone or phone_number,
        "voiceThumbprint": message.get("voiceThumbprint"),
        "timestamp": message.get("timestamp"),
    }
    
    if WebSocketManager.is_user_online(recipient_id):
        sent = await WebSocketManager.send_to_user(recipient_id, forwarded_message)
        if sent:
            print(f"[Native Call] Forwarded {msg_type} to user {recipient_id}")
            await websocket.send_json({
                "type": "native_call:delivered",
                "original_type": msg_type,
                "to_user_id": str(recipient_id)
            })
        else:
            await websocket.send_json({
                "type": "native_call:error",
                "original_type": msg_type,
                "message": "Failed to send to recipient"
            })
    else:
        print(f"[Native Call] Recipient {recipient_id} is offline - trying VoIP push")
        
        # Get recipient's VoIP token
        voip_token = await get_user_voip_token(recipient_id)
        
        if voip_token:
            # Send VoIP push with handshake data
            voice_thumbprint = message.get("voiceThumbprint")
            push_sent = await send_call_handshake_push(
                voip_token=voip_token,
                caller_phone=sender_phone or phone_number or "Unknown",
                caller_name=sender_display_name,
                caller_id=str(sender_id),
                voice_thumbprint=voice_thumbprint
            )
            
            if push_sent:
                print(f"[Native Call] VoIP push sent to offline user {recipient_id}")
                await websocket.send_json({
                    "type": "native_call:push_sent",
                    "original_type": msg_type,
                    "to_user_id": str(recipient_id),
                    "message": "VoIP push sent to wake recipient app"
                })
            else:
                print(f"[Native Call] VoIP push failed for user {recipient_id}")
                await websocket.send_json({
                    "type": "native_call:offline",
                    "original_type": msg_type,
                    "to_user_id": str(recipient_id),
                    "message": "Recipient is offline and push failed"
                })
        else:
            print(f"[Native Call] No VoIP token for user {recipient_id}")
            await websocket.send_json({
                "type": "native_call:offline",
                "original_type": msg_type,
                "to_user_id": str(recipient_id),
                "message": "Recipient is offline (no push token)"
            })


async def handle_call_initiate(sender_id: UUID, message: dict, websocket: WebSocket):
    """Handle call initiation signaling."""
    recipient_id_str = message.get("recipient_id")
    call_id = message.get("call_id")
    offer = message.get("offer")  # WebRTC offer
    voice_thumbprint = message.get("voice_thumbprint")  # Voice thumbprint for verification
    
    if not recipient_id_str or not call_id:
        await websocket.send_json({
            "type": "error",
            "message": "Missing recipient_id or call_id"
        })
        return
    
    try:
        recipient_id = UUID(recipient_id_str)
    except ValueError:
        await websocket.send_json({
            "type": "error",
            "message": "Invalid recipient_id format"
        })
        return
    
    # Build the notification payload
    notification = {
        "type": "call:incoming",
        "call_id": call_id,
        "caller_id": str(sender_id),
        "offer": offer
    }
    
    # Include voice thumbprint if provided
    if voice_thumbprint is not None:
        notification["voice_thumbprint"] = voice_thumbprint
    
    # Forward to recipient if online
    if WebSocketManager.is_user_online(recipient_id):
        await WebSocketManager.send_to_user(recipient_id, notification)
    else:
        await websocket.send_json({
            "type": "call:unavailable",
            "recipient_id": recipient_id_str,
            "message": "Recipient is offline"
        })


async def handle_call_answer(sender_id: UUID, message: dict, websocket: WebSocket):
    """Handle call answer signaling."""
    call_id = message.get("call_id")
    caller_id_str = message.get("caller_id")
    answer = message.get("answer")  # WebRTC answer
    
    if not call_id or not caller_id_str:
        await websocket.send_json({
            "type": "error",
            "message": "Missing call_id or caller_id"
        })
        return
    
    try:
        caller_id = UUID(caller_id_str)
    except ValueError:
        await websocket.send_json({
            "type": "error",
            "message": "Invalid caller_id format"
        })
        return
    
    # Forward to caller
    if WebSocketManager.is_user_online(caller_id):
        await WebSocketManager.send_to_user(caller_id, {
            "type": "call:answered",
            "call_id": call_id,
            "answer": answer
        })


async def handle_call_end(sender_id: UUID, message: dict, websocket: WebSocket):
    """Handle call end signaling."""
    call_id = message.get("call_id")
    other_party_id_str = message.get("other_party_id")
    reason = message.get("reason", "ended")
    
    if not call_id or not other_party_id_str:
        await websocket.send_json({
            "type": "error",
            "message": "Missing call_id or other_party_id"
        })
        return
    
    try:
        other_party_id = UUID(other_party_id_str)
    except ValueError:
        await websocket.send_json({
            "type": "error",
            "message": "Invalid other_party_id format"
        })
        return
    
    # Forward to other party
    if WebSocketManager.is_user_online(other_party_id):
        await WebSocketManager.send_to_user(other_party_id, {
            "type": "call:ended",
            "call_id": call_id,
            "reason": reason
        })
