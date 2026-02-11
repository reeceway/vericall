import json
from typing import Dict, Optional
from uuid import UUID

from fastapi import WebSocket, WebSocketDisconnect
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import decode_access_token, get_user_id_from_token, get_device_id_from_token
from app.database import AsyncSessionLocal
from app.models import User, Device


# Active WebSocket connections: user_id -> WebSocket
active_connections: Dict[UUID, WebSocket] = {}


class WebSocketManager:
    """Manages WebSocket connections for real-time call signaling."""
    
    @staticmethod
    async def connect(websocket: WebSocket, token: str):
        """Authenticate and connect a WebSocket."""
        await websocket.accept()
        
        # Validate token
        payload = decode_access_token(token)
        if not payload:
            await websocket.send_json({
                "type": "error",
                "message": "Invalid or expired token"
            })
            await websocket.close(code=4001)
            return None
        
        user_id = UUID(payload["sub"])
        device_id = UUID(payload["device_id"])
        
        # Store connection
        active_connections[user_id] = websocket
        
        await websocket.send_json({
            "type": "connected",
            "user_id": str(user_id),
            "device_id": str(device_id)
        })
        
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


async def handle_websocket(websocket: WebSocket):
    """Main WebSocket handler."""
    user_id: Optional[UUID] = None
    
    try:
        # Get token from query parameter
        token = websocket.query_params.get("token")
        if not token:
            await websocket.close(code=4001)
            return
        
        # Authenticate
        user_id = await WebSocketManager.connect(websocket, token)
        if not user_id:
            return
        
        # Main message loop
        while True:
            try:
                data = await websocket.receive_text()
                message = json.loads(data)
                
                await process_message(user_id, message, websocket)
                
            except json.JSONDecodeError:
                await websocket.send_json({
                    "type": "error",
                    "message": "Invalid JSON"
                })
    
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"WebSocket error: {e}")
    finally:
        if user_id:
            await WebSocketManager.disconnect(user_id)


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
    elif msg_type and msg_type.startswith("native_call:"):
        await handle_native_call(sender_id, message, websocket)
    else:
        await websocket.send_json({
            "type": "error",
            "message": f"Unknown message type: {msg_type}"
        })


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
    to_phone = message.get("to_phone")
    to_user_id = message.get("to_user_id")
    
    print(f"[Native Call] Processing {msg_type} from {sender_id}")
    print(f"[Native Call] to_phone: {to_phone}, to_user_id: {to_user_id}")
    
    recipient_id = None
    
    # First try to_user_id if provided
    if to_user_id:
        try:
            recipient_id = UUID(to_user_id)
        except (ValueError, TypeError):
            pass
    
    # Fall back to phone number lookup
    if not recipient_id and to_phone:
        recipient_user = await get_user_by_phone(to_phone)
        if recipient_user:
            recipient_id = recipient_user.id
            print(f"[Native Call] Found user {recipient_id} for phone {to_phone}")
        else:
            print(f"[Native Call] No user found for phone {to_phone}")
    
    if not recipient_id:
        await websocket.send_json({
            "type": "native_call:error",
            "original_type": msg_type,
            "message": "Could not find recipient user"
        })
        return
    
    # Forward the message to the recipient
    # Add sender info to the message
    forwarded_message = {
        **message,
        "from_user_id": str(sender_id),
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
        print(f"[Native Call] Recipient {recipient_id} is offline")
        await websocket.send_json({
            "type": "native_call:offline",
            "original_type": msg_type,
            "to_user_id": str(recipient_id),
            "message": "Recipient is offline"
        })
        # TODO: Queue for push notification to wake the app


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
