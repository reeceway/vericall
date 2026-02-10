import crypto from 'crypto';

/**
 * Generate a cryptographically secure nonce
 * Returns 32-character hex string
 */
export const generateNonce = (): string => {
  return crypto.randomBytes(16).toString('hex');
};

/**
 * Generate public key fingerprint
 */
export const getKeyFingerprint = (publicKeyBase64: string): string => {
  return crypto.createHash('sha256').update(publicKeyBase64).digest('hex').substring(0, 16);
};

/**
 * Verify ECDSA P-256 signature
 * 
 * @param publicKeyBase64 - Base64-encoded DER public key
 * @param message - Message that was signed
 * @param signatureBase64 - Base64-encoded signature
 * @returns boolean indicating if signature is valid
 */
export const verifySignature = (
  publicKeyBase64: string,
  message: string,
  signatureBase64: string
): boolean => {
  try {
    const publicKeyDer = Buffer.from(publicKeyBase64, 'base64');
    const signature = Buffer.from(signatureBase64, 'base64');
    
    // Create ECDSA P-256 verify key
    const verifyKey = crypto.createPublicKey({
      key: publicKeyDer,
      format: 'der',
      type: 'spki',
    });
    
    // Verify signature
    const isValid = crypto.verify(
      'sha256',
      Buffer.from(message),
      verifyKey,
      signature
    );
    
    return isValid;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
};

/**
 * Generate call initiation message for signing
 */
export const createCallMessage = (
  recipientId: string,
  timestamp: number,
  nonce: string
): string => {
  return `call:initiate:${recipientId}:${timestamp}:${nonce}`;
};
