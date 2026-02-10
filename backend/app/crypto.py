import hashlib
from typing import Optional

from ecdsa import VerifyingKey, SECP256k1, BadSignatureError


def verify_ecdsa_signature(
    public_key_pem: str,
    message: str,
    signature_hex: str
) -> bool:
    """
    Verify an ECDSA signature.
    
    Args:
        public_key_pem: The public key in PEM format
        message: The message that was signed (concatenated string)
        signature_hex: The signature in hexadecimal format
    
    Returns:
        True if signature is valid, False otherwise
    """
    try:
        # Load the public key
        vk = VerifyingKey.from_pem(public_key_pem)
        
        # Convert message to bytes
        message_bytes = message.encode('utf-8')
        
        # Convert signature from hex to bytes
        signature_bytes = bytes.fromhex(signature_hex)
        
        # Verify the signature
        return vk.verify(signature_bytes, message_bytes, hashfunc=hashlib.sha256)
    
    except BadSignatureError:
        return False
    except Exception as e:
        print(f"Signature verification error: {e}")
        return False


def get_public_key_fingerprint(public_key_pem: str) -> str:
    """
    Generate a fingerprint for a public key.
    
    Args:
        public_key_pem: The public key in PEM format
    
    Returns:
        A hex string fingerprint of the public key
    """
    # Normalize the key by removing whitespace and headers
    key_content = public_key_pem.strip()
    
    # Create SHA-256 hash of the public key
    key_hash = hashlib.sha256(key_content.encode('utf-8')).hexdigest()
    
    return key_hash[:64]  # Return first 64 chars


def format_call_signature_message(
    caller_id: str,
    recipient_id: str,
    timestamp: int,
    nonce: str
) -> str:
    """
    Format the message to be signed for call initiation.
    
    The message format must match what the client signs:
    "call:{caller_id}:{recipient_id}:{timestamp}:{nonce}"
    """
    return f"call:{caller_id}:{recipient_id}:{timestamp}:{nonce}"
