# VeriCall Security Model

This document describes the threat model VeriCall is designed to address, the cryptographic mechanisms used, and the security assumptions the system relies on.

---

## Threat Model

### What VeriCall protects against

**Primary threat: AI voice cloning impersonation**
An attacker uses a voice cloning model to generate audio that sounds like a known contact (parent, bank, employer) and places a phone call. Traditional telephony has no mechanism to verify that the voice on the line belongs to the person registered to that number.

**Secondary threat: Real-time voice spoofing**
An attacker intercepts or proxies a call and substitutes a synthesized voice mid-conversation.

**Tertiary threat: SIM swap / phone number hijack**
An attacker gains control of a phone number through carrier fraud and impersonates the victim by calling from that number.

### What VeriCall does NOT protect against

- **Compromised device**: If the attacker controls the victim's physical device and has unlocked it, all bets are off. The private key lives in the Secure Enclave, but an attacker with physical access and biometric bypass has the same threat surface as any app.
- **Backend compromise**: A fully compromised backend server could return false verification results. The backend does not have access to private keys, but it does store voice prints and mediates the verification flow.
- **Enrollment-time attack**: If an attacker enrolls their own voice as a legitimate user (by bypassing OTP and device registration), they pass all subsequent voice checks. Enrollment security depends on OTP delivery integrity.
- **Adversarial ML attacks against deepfake detection**: A sufficiently sophisticated voice clone designed specifically to fool the WavLM detector could evade classification. This is a known limitation of any statistical deepfake detector.
- **Non-VeriCall users**: Both parties must use VeriCall for verification to work. There is no protection when calling someone who hasn't enrolled.

---

## Two-Factor Verification Design

VeriCall applies two independent factors:

### Factor 1: Device Verification (cryptographic)

**Mechanism**: ECDSA-P256-SHA256 signatures

During registration, the iOS app generates a P-256 elliptic curve key pair:
- **Private key**: Generated and stored in the device's Secure Enclave. It is never exported, never leaves the chip.
- **Public key**: Uploaded to the backend in base64-encoded DER format during the `verify-otp` call.

When initiating a call, the caller's device signs a payload containing:
```json
{
  "callId": "uuid",
  "callerId": "user-uuid",
  "recipientId": "user-uuid",
  "nonce": "random-hex",
  "timestamp": 1739000000
}
```

The backend verifies this signature against the stored public key using `cryptography` (Python):
```python
# backend/app/crypto.py
public_key.verify(signature_bytes, payload_bytes, ec.ECDSA(hashes.SHA256()))
```

**What this proves**: The call was initiated from the specific device registered by the caller. An attacker who has only the caller's voice (or phone number) cannot forge this signature — they need the device.

**Replay protection**: The `nonce` is a random value generated per call. The `timestamp` must be within a configurable window (default 5 minutes). Used nonces are tracked in Redis.

### Factor 2: Voice Verification (biometric)

**Mechanism**: 192-dimensional voice embeddings + cosine similarity

During enrollment, the user records 5 voice samples. The iOS app extracts a 192-dimensional embedding from each sample using a Resemblyzer-based encoder, then sends the embeddings (not the raw audio) to the backend.

The backend stores the mean of the enrollment embeddings as the user's "voice print".

During a call, every 4 seconds the app extracts an embedding from the most recent 3-second audio chunk and computes cosine similarity against the stored voice print:

```
score = dot(live_embedding, enrolled_embedding) /
        (||live_embedding|| × ||enrolled_embedding||)
```

| Score | Interpretation |
|-------|---------------|
| ≥ 0.75 | Voice match — shown as green "Voice Match: N%" |
| 0.55 – 0.74 | Uncertain — no alarm, but no green indicator |
| < 0.55 | Warning — shown as red "Voice Mismatch: N%" |

The score is computed and displayed locally on the recipient's device. Neither raw audio nor real-time embeddings are sent to the backend during a call; the voice print is fetched once at call-start.

**What this proves**: The person speaking sounds sufficiently similar to the enrolled voice. It does not prove liveness (a perfect voice clone of the enrolled user would pass), but combined with device verification it substantially raises the cost of an attack.

### Factor 3: Deepfake Detection (defense-in-depth)

A WavLM-based CoreML model runs on-device, analyzing incoming audio for statistical markers of AI synthesis. This is a probabilistic signal (≈84% accuracy), not a cryptographic guarantee. It is reported as a separate indicator rather than replacing the voice match score.

Rolling majority vote over the last 5 samples is used to smooth out transient false positives.

---

## Key Material and Storage

| Material | Storage location | Accessible to |
|----------|-----------------|--------------|
| ECDSA private key | Secure Enclave (hardware) | CryptoKit on the registered device only |
| JWT access token | iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) | App only, not synced to iCloud |
| JWT refresh token | iOS Keychain (same class) | App only |
| User ID | iOS Keychain | App only |
| Voice print embeddings | Backend PostgreSQL | Backend API, fetched per call |
| Enrolled voice print (local copy) | iOS Keychain | App only, used for local verification |
| Push token (FCM/APNS) | Backend PostgreSQL | Backend push services |

The backend stores **no private keys**. Public keys and voice prints are stored; neither alone is sufficient to impersonate a user.

---

## OTP / Registration Security

1. A one-time passcode is generated server-side and delivered via Twilio SMS.
2. The OTP is stored as a **bcrypt hash** in the database, not in plaintext.
3. OTPs expire after 5 minutes.
4. OTP attempts are rate-limited per phone number.
5. After 5 failed attempts, the OTP is invalidated and a new one must be requested.

The OTP flow is the weakest link in the enrollment chain — it relies on carrier-level phone number integrity. SIM swap attacks could allow an attacker to register their own device and voice print under a hijacked number. This is a known limitation of all SMS-OTP based systems.

---

## Network Security

- All API communication uses HTTPS (TLS 1.2+).
- WebSocket signaling uses WSS.
- Audio is transported directly device-to-device over QUIC (no backend relay); the backend never touches audio data.
- JWT tokens are short-lived (60 minutes); refresh tokens expire after 30 days.

---

## Backend Trust Boundary

The backend is trusted for:
- Routing call signaling (WebSocket)
- Verifying ECDSA call signatures
- Storing and serving voice prints
- OTP delivery and verification
- JWT issuance

The backend is **not** trusted for:
- Storing private keys (it never sees them)
- Processing real-time audio (audio goes P2P)
- The final voice match decision (computed on the recipient's device)

A compromised backend could return a false voice print, making a different person's voice appear to match. This is a known architectural trade-off. Future work could address this with end-to-end authenticated voice prints (the caller signs their own voice print at enrollment time).

---

## Security Contacts

This is a hackathon project. For security issues in a production context, the appropriate contact would be the project maintainer via the GitHub repository.
