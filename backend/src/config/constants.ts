// EXACT constants from TECH_SPEC.md
export const CONSTANTS = {
  // API
  API_BASE_URL: 'https://vericall-api.fly.dev/api/v1',
  WS_BASE_URL: 'wss://vericall-api.fly.dev',

  // Crypto
  SIGNATURE_ALGORITHM: 'ECDSA-P256-SHA256',

  // JWT
  JWT_EXPIRES_IN: '7d',
  JWT_REFRESH_EXPIRES_IN: '30d',

  // Rate limits
  OTP_RATE_LIMIT: 5,      // per minute
  CALL_RATE_LIMIT: 60,    // per minute

  // OTP
  OTP_EXPIRES_IN: 300,    // 5 minutes in seconds
  OTP_LENGTH: 6,
} as const;

// ICE servers for WebRTC
export const DEFAULT_ICE_SERVERS = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
  { urls: 'stun:stun2.l.google.com:19302' },
];
