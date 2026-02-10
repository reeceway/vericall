"""
Logging configuration for VeriCall backend
"""
import logging
import sys
from datetime import datetime
from typing import Any, Dict, Optional
import json

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s | %(levelname)-8s | %(name)-20s | %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('vericall.log')
    ]
)

# Category loggers
auth_logger = logging.getLogger('vericall.auth')
crypto_logger = logging.getLogger('vericall.crypto')
network_logger = logging.getLogger('vericall.network')
call_logger = logging.getLogger('vericall.call')
websocket_logger = logging.getLogger('vericall.websocket')
db_logger = logging.getLogger('vericall.database')
error_logger = logging.getLogger('vericall.errors')

class RequestLogger:
    """Logs HTTP requests and responses"""
    
    @staticmethod
    def log_request(
        method: str,
        path: str,
        headers: Optional[Dict[str, Any]] = None,
        body: Optional[Dict[str, Any]] = None,
        client_ip: Optional[str] = None
    ):
        """Log incoming request"""
        msg = f"📤 REQUEST | {method} {path}"
        if client_ip:
            msg += f" | Client: {client_ip}"
        if headers:
            # Log important headers only
            important = ['authorization', 'content-type', 'user-agent']
            filtered = {k: v for k, v in headers.items() if k.lower() in important}
            msg += f" | Headers: {filtered}"
        if body:
            # Mask sensitive fields
            safe_body = RequestLogger._mask_sensitive(body)
            msg += f" | Body: {json.dumps(safe_body, default=str)[:500]}"
        
        network_logger.info(msg)
    
    @staticmethod
    def log_response(
        method: str,
        path: str,
        status_code: int,
        duration_ms: float,
        body: Optional[Dict[str, Any]] = None,
        error: Optional[str] = None
    ):
        """Log outgoing response"""
        emoji = "✅" if 200 <= status_code < 300 else "⚠️" if status_code < 500 else "❌"
        msg = f"📥 RESPONSE | {emoji} {method} {path} | {status_code} | {duration_ms:.2f}ms"
        
        if error:
            msg += f" | Error: {error}"
        elif body:
            msg += f" | Body: {json.dumps(body, default=str)[:500]}"
        
        if status_code >= 400:
            network_logger.warning(msg)
        else:
            network_logger.info(msg)
    
    @staticmethod
    def _mask_sensitive(data: Dict[str, Any]) -> Dict[str, Any]:
        """Mask sensitive fields in logs"""
        sensitive = ['password', 'token', 'secret', 'code', 'private_key', 'signature']
        masked = {}
        for key, value in data.items():
            if any(s in key.lower() for s in sensitive):
                masked[key] = '***'
            elif isinstance(value, dict):
                masked[key] = RequestLogger._mask_sensitive(value)
            else:
                masked[key] = value
        return masked

class AuthLogger:
    """Logs authentication events"""
    
    @staticmethod
    def log_otp_request(phone: str, success: bool, error: Optional[str] = None):
        """Log OTP request"""
        status = "✅" if success else "❌"
        msg = f"🔐 OTP REQUEST | {status} | Phone: {phone[:7]}***"
        if error:
            msg += f" | Error: {error}"
        
        if success:
            auth_logger.info(msg)
        else:
            auth_logger.warning(msg)
    
    @staticmethod
    def log_otp_verify(phone: str, success: bool, user_id: Optional[str] = None, error: Optional[str] = None):
        """Log OTP verification"""
        status = "✅" if success else "❌"
        msg = f"🔐 OTP VERIFY | {status} | Phone: {phone[:7]}***"
        if user_id:
            msg += f" | User: {user_id[:8]}..."
        if error:
            msg += f" | Error: {error}"
        
        if success:
            auth_logger.info(msg)
        else:
            auth_logger.warning(msg)
    
    @staticmethod
    def log_token_refresh(user_id: str, success: bool, error: Optional[str] = None):
        """Log token refresh"""
        status = "✅" if success else "❌"
        msg = f"🔐 TOKEN REFRESH | {status} | User: {user_id[:8]}..."
        if error:
            msg += f" | Error: {error}"
        auth_logger.info(msg)

class CryptoLogger:
    """Logs cryptographic operations"""
    
    @staticmethod
    def log_signature_verification(
        fingerprint: str,
        success: bool,
        timestamp_age: Optional[float] = None,
        error: Optional[str] = None
    ):
        """Log signature verification attempt"""
        status = "✅ VALID" if success else "❌ INVALID"
        msg = f"🔑 SIGNATURE | {status} | Key: {fingerprint[:16]}..."
        if timestamp_age is not None:
            msg += f" | Age: {timestamp_age:.1f}s"
        if error:
            msg += f" | Error: {error}"
        
        if success:
            crypto_logger.info(msg)
        else:
            crypto_logger.warning(msg)
    
    @staticmethod
    def log_key_generation(fingerprint: str, algorithm: str = "ECDSA-P256"):
        """Log key generation"""
        crypto_logger.info(f"🔑 KEY GEN | Algorithm: {algorithm} | Fingerprint: {fingerprint[:16]}...")
    
    @staticmethod
    def log_key_storage(user_id: str, device_name: str):
        """Log key storage"""
        crypto_logger.info(f"🔑 KEY STORE | User: {user_id[:8]}... | Device: {device_name}")

class CallLogger:
    """Logs call events"""
    
    @staticmethod
    def log_call_initiated(
        call_id: str,
        caller_id: str,
        recipient_id: str,
        verified: bool,
        signature_valid: bool
    ):
        """Log call initiation"""
        status = "✅ VERIFIED" if verified else "❌ UNVERIFIED"
        sig_status = "✅" if signature_valid else "❌"
        call_logger.info(
            f"📞 CALL INIT | {status} | Call: {call_id[:8]}... | "
            f"{caller_id[:8]}... → {recipient_id[:8]}... | Sig: {sig_status}"
        )
    
    @staticmethod
    def log_call_answered(call_id: str, recipient_id: str):
        """Log call answer"""
        call_logger.info(f"📞 CALL ANSWER | Call: {call_id[:8]}... | By: {recipient_id[:8]}...")
    
    @staticmethod
    def log_call_ended(call_id: str, duration_ms: Optional[int] = None):
        """Log call end"""
        msg = f"📞 CALL END | Call: {call_id[:8]}..."
        if duration_ms:
            msg += f" | Duration: {duration_ms/1000:.1f}s"
        call_logger.info(msg)
    
    @staticmethod
    def log_call_error(call_id: str, error: str):
        """Log call error"""
        call_logger.error(f"📞 CALL ERROR | Call: {call_id[:8]}... | Error: {error}")

class WebSocketLogger:
    """Logs WebSocket events"""
    
    @staticmethod
    def log_connection(client_id: str, connected: bool):
        """Log connection/disconnection"""
        status = "✅ CONNECTED" if connected else "❌ DISCONNECTED"
        websocket_logger.info(f"⚡ WS | {status} | Client: {client_id[:8]}...")
    
    @staticmethod
    def log_message(direction: str, client_id: str, msg_type: str, payload_size: Optional[int] = None):
        """Log WebSocket message"""
        emoji = "📤" if direction == "out" else "📥"
        msg = f"⚡ WS {emoji} | {direction.upper()} | Client: {client_id[:8]}... | Type: {msg_type}"
        if payload_size:
            msg += f" | Size: {payload_size}b"
        websocket_logger.debug(msg)
    
    @staticmethod
    def log_authentication(client_id: str, success: bool, error: Optional[str] = None):
        """Log WebSocket auth"""
        status = "✅ AUTHENTICATED" if success else "❌ AUTH FAILED"
        msg = f"⚡ WS | {status} | Client: {client_id[:8]}..."
        if error:
            msg += f" | Error: {error}"
        websocket_logger.info(msg)

class DatabaseLogger:
    """Logs database operations"""
    
    @staticmethod
    def log_query(operation: str, table: str, duration_ms: float, rows: Optional[int] = None):
        """Log database query"""
        msg = f"🗄️  DB | {operation} | Table: {table} | {duration_ms:.2f}ms"
        if rows is not None:
            msg += f" | Rows: {rows}"
        db_logger.debug(msg)
    
    @staticmethod
    def log_error(operation: str, error: str):
        """Log database error"""
        db_logger.error(f"🗄️  DB ERROR | {operation} | Error: {error}")

class ErrorLogger:
    """Logs errors with full context"""
    
    @staticmethod
    def log_exception(
        exception: Exception,
        context: str,
        request_info: Optional[Dict[str, Any]] = None
    ):
        """Log exception with full context"""
        msg = f"❌ EXCEPTION in {context}\n"
        msg += f"Type: {type(exception).__name__}\n"
        msg += f"Message: {str(exception)}\n"
        
        if request_info:
            msg += f"Request: {json.dumps(request_info, default=str)}\n"
        
        # Include traceback
        import traceback
        msg += f"Traceback:\n{traceback.format_exc()}"
        
        error_logger.error(msg)
    
    @staticmethod
    def log_validation_error(field: str, value: Any, error: str):
        """Log validation error"""
        error_logger.warning(f"❌ VALIDATION | Field: {field} | Value: {value} | Error: {error}")

# Request timing middleware
class TimingMiddleware:
    """Middleware to log request timing"""
    
    def __init__(self, app):
        self.app = app
    
    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        
        start_time = datetime.utcnow()
        
        # Capture request details
        method = scope.get("method", "UNKNOWN")
        path = scope.get("path", "UNKNOWN")
        
        # Wrap send to capture response status
        status_code = None
        async def wrapped_send(message):
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message.get("status", 0)
            await send(message)
        
        await self.app(scope, receive, wrapped_send)
        
        # Log timing
        duration = (datetime.utcnow() - start_time).total_seconds() * 1000
        RequestLogger.log_response(method, path, status_code or 0, duration)

# Decorator for logging function calls
def log_call(logger_name: str = "vericall.debug"):
    """Decorator to log function entry/exit"""
    def decorator(func):
        logger = logging.getLogger(logger_name)
        
        async def async_wrapper(*args, **kwargs):
            logger.debug(f"▶️  ENTER {func.__name__}")
            try:
                result = await func(*args, **kwargs)
                logger.debug(f"◀️  EXIT {func.__name__} | Success")
                return result
            except Exception as e:
                logger.error(f"◀️  EXIT {func.__name__} | Error: {e}")
                raise
        
        def sync_wrapper(*args, **kwargs):
            logger.debug(f"▶️  ENTER {func.__name__}")
            try:
                result = func(*args, **kwargs)
                logger.debug(f"◀️  EXIT {func.__name__} | Success")
                return result
            except Exception as e:
                logger.error(f"◀️  EXIT {func.__name__} | Error: {e}")
                raise
        
        return async_wrapper if asyncio.iscoroutinefunction(func) else sync_wrapper
    return decorator

import asyncio