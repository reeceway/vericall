# VeriCall Technical Specification

## 🎯 Mission
Build a working iOS app + backend in ONE NIGHT that demonstrates cryptographic caller verification + real-time voice matching. Must handle a few thousand users at hackathon demo.

**End Result:** Two people open the app, one calls the other, recipient sees "✓ Device Verified" before answering, then "Voice Match: 94%" during the call. If someone else speaks, it shows "⚠️ Voice Mismatch: 31%".

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         VERICALL SYSTEM ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         iOS APP (Swift)                             │   │
│  │                                                                     │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │   │
│  │  │ Onboarding   │  │ Calling      │  │ Voice        │              │   │
│  │  │ Agent #2     │  │ Agent #3     │  │ Agent #4     │              │   │
│  │  │ SwiftUI      │  │ CallKit      │  │ ML/AI        │              │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘              │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              │ HTTPS + WebSocket                           │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         BACKEND (Node.js/FastAPI)                   │   │
│  │                         Agent #1                                    │   │
│  │                                                                     │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │   │
│  │  │ Auth API     │  │ Call API     │  │ Voice API    │              │   │
│  │  │ /auth/*      │  │ /calls/*     │  │ /voice/*     │              │   │
│  │  │ Device       │  │ WebRTC       │  │ ML Model     │              │   │
│  │  │ Verification │  │ Signaling    │  │ Integration  │              │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘              │   │
│  │                                                                     │   │
│  │  ┌──────────────┐  ┌──────────────┐                                │   │
│  │  │ PostgreSQL   │  │ Redis        │                                │   │
│  │  │ (Supabase)   │  │ (Upstash)    │                                │   │
│  │  │ Users,Calls   │  │ Sessions,WS  │                                │   │
│  │  └──────────────┘  └──────────────┘                                │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 👥 Agent Assignments

| Agent | Responsibility | Time Budget | Depends On | Tech Stack |
|-------|---------------|-------------|------------|------------|
| **Agent #1** | Backend API + Database | 4-5 hours | Nothing | FastAPI/Node.js, PostgreSQL, Redis |
| **Agent #2** | iOS Onboarding + Auth | 3-4 hours | Agent #1 (auth endpoints) | SwiftUI, Keychain |
| **Agent #3** | iOS Calling Flow + UI | 3-4 hours | Agent #1 (call endpoints) | SwiftUI, CallKit, WebRTC |
| **Agent #4** | Voice ML + Verification | 4-5 hours | Agent #1 (voice endpoints) | Python ML, iOS CoreML |
| **Orchestrator** | Integration + Testing | 2-3 hours | All agents | Coordination |

### Parallel Execution Timeline
- **Hour 0-1:** Agent #1 starts backend
- **Hour 1:** Agents #2, #3, #4 start (use mock API initially)
- **Hour 4-5:** Integration begins
- **Hour 6-7:** Testing + bug fixes
- **Hour 8:** Demo ready

---

## 📋 Shared Constants

### Backend URLs
```python
# Backend Config
API_BASE_URL = "https://vericall-api.fly.dev/api/v1"  # Production
# API_BASE_URL = "http://localhost:3000/api/v1"       # Development

WS_BASE_URL = "wss://vericall-api.fly.dev/ws"         # Production
# WS_BASE_URL = "ws://localhost:3000/ws"              # Development
```

### iOS Constants (Swift)
```swift
struct Constants {
    static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
    static let wsBaseURL = "wss://vericall-api.fly.dev/ws"
    
    // Feature flags
    static let enableDeviceVerification = true
    static let enableVoiceMatching = true
    
    // Thresholds
    static let voiceMatchThreshold: Float = 0.85  // 85% = verified
    static let voiceMismatchThreshold: Float = 0.50  // Below 50% = alert
}
```

---

## 🔐 Core Workflows

### 1. Device Registration & Verification
```
User opens app → Generate device keypair → Register with backend
→ Backend stores public key → Returns device certificate
```

### 2. Call Initiation
```
Caller: Press call button → Backend creates call session
→ Generate call token → Send push to recipient
→ Recipient sees: "Incoming call from [name] - ✓ Device Verified"
```

### 3. Voice Verification During Call
```
Real-time audio stream → Extract voice embeddings every 3 seconds
→ Compare to caller's voice print → Display match percentage
→ If mismatch < 50%: Show "⚠️ Voice Mismatch" alert
```

---

## 🛠️ Technical Implementation

### Backend Agent #1 Tasks

**Database Schema (PostgreSQL):**
```sql
-- Users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number VARCHAR(20) UNIQUE NOT NULL,
    device_public_key TEXT NOT NULL,
    voice_embedding VECTOR(256),  -- For voice print
    created_at TIMESTAMP DEFAULT NOW()
);

-- Calls table
CREATE TABLE calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    caller_id UUID REFERENCES users(id),
    recipient_id UUID REFERENCES users(id),
    status VARCHAR(20) DEFAULT 'pending',  -- pending, active, ended
    started_at TIMESTAMP,
    ended_at TIMESTAMP,
    caller_verified BOOLEAN DEFAULT false,
    voice_match_scores JSONB  -- Store match history
);

-- Device certificates
CREATE TABLE device_certs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id),
    certificate TEXT NOT NULL,
    expires_at TIMESTAMP
);
```

**API Endpoints:**
- `POST /auth/register` - Register new device
- `POST /auth/verify-device` - Verify device certificate
- `POST /calls/initiate` - Start new call
- `POST /calls/accept` - Accept incoming call
- `POST /calls/end` - End call
- `POST /voice/verify` - Submit voice sample for verification
- `WS /ws/calls/{call_id}` - Real-time call signaling

**Tech Stack:**
- FastAPI (Python) or Express (Node.js)
- PostgreSQL via Supabase
- Redis via Upstash (for sessions/WebSocket)
- WebSocket for real-time signaling
- Deploy to Fly.io or Railway

---

### iOS Onboarding Agent #2 Tasks

**Screens:**
1. **Splash/Welcome** - App logo, brief description
2. **Phone Input** - Enter phone number
3. **Verification Code** - SMS verification
4. **Device Setup** - Generate cryptographic keys
5. **Voice Enrollment** - Record voice samples (3x)

**Key Features:**
- SwiftUI for all UI
- SecureEnclave for private key storage
- Keychain for device certificate
- Camera/mic permissions
- Push notification registration

**Deliverables:**
- Complete onboarding flow
- Device key generation
- API integration for registration
- Local storage of credentials

---

### iOS Calling Agent #3 Tasks

**Screens:**
1. **Contacts List** - Show verified contacts
2. **Call Screen (Incoming)** - Show caller info + verification status
3. **Call Screen (Active)** - Show voice match percentage
4. **Call History** - Past calls with verification status

**Key Features:**
- CallKit integration for native call UI
- WebRTC for voice calling (or use Twilio)
- Real-time WebSocket connection
- Voice match UI (circular progress indicator)
- Alert for voice mismatch

**Deliverables:**
- Contact list UI
- Incoming call screen with verification badge
- Active call screen with voice match display
- CallKit integration
- Push notification handling

---

### Voice ML Agent #4 Tasks

**Backend Voice API:**
- `POST /voice/enroll` - Create voice print from 3 samples
- `POST /voice/verify` - Compare voice sample to stored print
- Returns: `{ match_score: 0.94, is_match: true }`

**Voice Processing:**
- Use open-source speaker recognition (e.g., Resemblyzer, SpeechBrain)
- Extract 256-dimension voice embeddings
- Cosine similarity for comparison
- Real-time processing (< 500ms)

**iOS Integration:**
- Record audio every 3 seconds during call
- Send to backend for verification
- Display result in real-time
- Cache voice prints locally

**Tech Stack:**
- Python: SpeechBrain or Resemblyzer
- Convert to CoreML for on-device inference (optional)
- Real-time audio streaming

**Deliverables:**
- Voice enrollment endpoint
- Voice verification endpoint
- iOS audio capture during calls
- Real-time match display

---

## 📊 API Contracts

### Device Registration
```http
POST /api/v1/auth/register
Content-Type: application/json

{
  "phone_number": "+1234567890",
  "device_public_key": "-----BEGIN PUBLIC KEY-----...",
  "push_token": "apns_token_here"
}

Response: {
  "user_id": "uuid",
  "device_certificate": "signed_cert_here",
  "expires_at": "2026-03-09T18:00:00Z"
}
```

### Initiate Call
```http
POST /api/v1/calls/initiate
Authorization: Bearer {device_cert}
Content-Type: application/json

{
  "recipient_phone": "+0987654321"
}

Response: {
  "call_id": "uuid",
  "status": "pending",
  "recipient_verified": true,
  "webrtc_config": {...}
}
```

### Voice Verification
```http
POST /api/v1/voice/verify
Authorization: Bearer {device_cert}
Content-Type: multipart/form-data

audio_file: [binary audio data]
call_id: "uuid"

Response: {
  "match_score": 0.94,
  "is_match": true,
  "confidence": "high"
}
```

---

## 🚀 Deployment

### Backend Deployment (Fly.io)
```bash
# Deploy to Fly.io
fly launch --name vericall-api
fly deploy

# Set secrets
fly secrets set DATABASE_URL=postgresql://...
fly secrets set REDIS_URL=redis://...
fly secrets set JWT_SECRET=...
```

### iOS App
- Build for iOS 16+
- TestFlight for beta testing
- App Store for distribution (post-hackathon)

---

## ✅ Acceptance Criteria

### Backend (Agent #1)
- [ ] All API endpoints return correct responses
- [ ] Device registration with cryptographic keys works
- [ ] Call signaling via WebSocket functions
- [ ] Database schema deployed to Supabase
- [ ] Deployed and accessible at `vericall-api.fly.dev`
- [ ] Handles 1000+ concurrent connections

### iOS Onboarding (Agent #2)
- [ ] User can complete full onboarding in < 2 minutes
- [ ] Device keys generated and stored securely
- [ ] Voice enrollment records 3 samples
- [ ] Push notifications registered

### iOS Calling (Agent #3)
- [ ] Incoming calls show native CallKit UI
- [ ] "Device Verified" badge appears for verified callers
- [ ] Active call screen shows real-time voice match
- [ ] Voice mismatch alert triggers correctly
- [ ] Call history saved and displayed

### Voice ML (Agent #4)
- [ ] Voice enrollment creates accurate voice print
- [ ] Verification returns match score in < 1 second
- [ ] Match accuracy > 90% for same speaker
- [ ] Mismatch detection < 50% for different speakers
- [ ] Real-time updates during active call

### Integration (Orchestrator)
- [ ] End-to-end flow: Register → Call → Verify Voice
- [ ] Two iPhones can call each other
- [ ] Demo video recorded showing all features
- [ ] Handles 1000+ users (load tested)

---

## 📋 SHARED CONSTANTS (CRITICAL - ALL AGENTS MUST USE)

### iOS (Swift)
```swift
struct Constants {
    static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
    static let wsBaseURL = "wss://vericall-api.fly.dev"
    static let appGroupID = "group.com.vericall.shared"
    static let keychainService = "com.vericall.keychain"
    
    // Voice
    static let voiceSampleRate: Double = 16000
    static let voiceEmbeddingDimension = 192
    static let voiceMatchThreshold: Float = 0.75
    static let voiceWarningThreshold: Float = 0.55
    
    // Crypto
    static let signatureAlgorithm = "ECDSA-P256-SHA256"
}
```

### Backend (TypeScript)
```typescript
export const constants = {
    jwtSecret: process.env.JWT_SECRET || 'dev-secret-change-in-prod',
    jwtExpiresIn: '7d',
    
    // Voice
    voiceEmbeddingDimension: 192,
    voiceMatchThreshold: 0.75,
    voiceWarningThreshold: 0.55,
    
    // Rate limits
    otpRateLimit: 5,      // per minute
    callRateLimit: 60,    // per minute
};
```

---

## 🔌 API CONTRACT (EXACT SPEC - NO DEVIATIONS)

### Authentication
**POST /api/v1/auth/request-otp**
```json
// Request
{ "phoneNumber": "+15550001234" }

// Response
{ "success": true, "expiresIn": 300 }
```

**POST /api/v1/auth/verify-otp**
```json
// Request
{
    "phoneNumber": "+15550001234",
    "code": "123456",
    "publicKey": "base64-encoded-p256-public-key",
    "deviceId": "uuid",
    "deviceName": "iPhone 15 Pro"
}

// Response
{
    "success": true,
    "accessToken": "jwt-token",
    "refreshToken": "refresh-token",
    "user": { "id", "phoneNumber", "displayName" }
}
```

**POST /api/v1/auth/refresh**
```json
// Request
{ "refreshToken": "token" }

// Response
{ "accessToken", "refreshToken" }
```

### Users & Contacts
**GET /api/v1/users/me**
```json
// Headers: Authorization: Bearer {token}
// Response
{
    "user": {
        "id", "phoneNumber", "displayName", "voiceEnrolled"
    }
}
```

**PATCH /api/v1/users/me**
```json
// Headers: Authorization: Bearer {token}
// Request: { "displayName": "John Doe" }
// Response: { "user": {...} }
```

**POST /api/v1/contacts/sync**
```json
// Headers: Authorization: Bearer {token}
// Request
{ "phoneNumbers": ["+15550001234", "+15550005678"] }

// Response
{
    "contacts": [
        {
            "phoneNumber", "userId", "displayName",
            "publicKeyFingerprint", "voiceEnrolled"
        }
    ]
}
```

### Calls
**POST /api/v1/calls/initiate**
```json
// Headers: Authorization: Bearer {token}
// Request
{
    "recipientId": "user-uuid",
    "timestamp": 1707500000,
    "nonce": "random-32-char-hex",
    "signature": "base64-ecdsa-signature"
}

// Response
{
    "callId": "call-uuid",
    "verified": true,
    "recipient": {
        "id", "displayName", "socketConnected"
    }
}
```

**POST /api/v1/calls/answer**
```json
// Headers: Authorization: Bearer {token}
// Request: { "callId": "call-uuid" }
// Response: { "success": true }
```

**POST /api/v1/calls/end**
```json
// Headers: Authorization: Bearer {token}
// Request: { "callId": "call-uuid" }
// Response: { "success": true }
```

### Voice
**POST /api/v1/voice/enroll**
```json
// Headers: Authorization: Bearer {token}
// Request
{
    "embedding": [0.123, -0.456, ...], // 192 floats
    "sampleCount": 5
}

// Response
{ "success": true, "quality": 0.92 }
```

**GET /api/v1/voice/voiceprint/{userId}**
```json
// Headers: Authorization: Bearer {token}
// Response
{
    "enrolled": true,
    "voiceprint": {
        "embedding": [...],
        "version": "1.0"
    }
}
```

### WebSocket Events
**Client → Server**
```json
{ "type": "authenticate", "token": "jwt-token" }
{ "type": "call:initiate", "recipientId": "uuid", "signature": "..." }
{ "type": "call:answer", "callId": "uuid" }
{ "type": "call:end", "callId": "uuid" }
{ "type": "call:ice-candidate", "callId": "uuid", "candidate": {...} }
{ "type": "call:sdp-offer", "callId": "uuid", "sdp": "..." }
{ "type": "call:sdp-answer", "callId": "uuid", "sdp": "..." }
```

**Server → Client**
```json
{ "type": "authenticated", "userId": "uuid" }
{ "type": "call:incoming", "callId": "uuid", "caller": { "id", "displayName", "verified" } }
{ "type": "call:answered", "callId": "uuid" }
{ "type": "call:ended", "callId": "uuid" }
{ "type": "call:ice-candidate", "callId": "uuid", "candidate": {...} }
{ "type": "call:sdp-offer", "callId": "uuid", "sdp": "..." }
{ "type": "call:sdp-answer", "callId": "uuid", "sdp": "..." }
{ "type": "error", "message": "..." }
```

---

## 📁 File Structure

```
projects/vericall/
├── backend/                 # Agent #1
│   ├── app/
│   │   ├── main.py
│   │   ├── routes/
│   │   │   ├── auth.py
│   │   │   ├── calls.py
│   │   │   └── voice.py
│   │   ├── models/
│   │   │   └── database.py
│   │   └── services/
│   │       ├── device_verification.py
│   │       ├── webrtc_signaling.py
│   │       └── voice_ml.py
│   ├── Dockerfile
│   ├── fly.toml
│   └── requirements.txt
├── ios/                     # Agent #2 & #3
│   ├── VeriCall/
│   │   ├── App/
│   │   │   ├── VeriCallApp.swift
│   │   │   └── Constants.swift
│   │   ├── Views/
│   │   │   ├── Onboarding/
│   │   │   │   ├── WelcomeView.swift
│   │   │   │   ├── PhoneInputView.swift
│   │   │   │   ├── VerificationCodeView.swift
│   │   │   │   └── VoiceEnrollmentView.swift
│   │   │   ├── Contacts/
│   │   │   │   └── ContactListView.swift
│   │   │   └── Calling/
│   │   │       ├── IncomingCallView.swift
│   │   │       ├── ActiveCallView.swift
│   │   │       └── CallHistoryView.swift
│   │   ├── Services/
│   │   │   ├── APIService.swift
│   │   │   ├── CallManager.swift
│   │   │   ├── DeviceCrypto.swift
│   │   │   └── VoiceCapture.swift
│   │   └── Models/
│   │       ├── User.swift
│   │       ├── Call.swift
│   │       └── VoiceMatch.swift
│   └── VeriCall.xcodeproj
├── voice-ml/                # Agent #4 (backend component)
│   ├── models/
│   │   └── speaker_recognition.py
│   ├── api.py
│   └── requirements.txt
├── tests/                   # QA Agent
│   ├── backend/
│   ├── ios/
│   └── integration/
└── docs/
    ├── DEMO_SCRIPT.md
    └── PITCH_DECK.md
```

---

## 🎯 Demo Script

**Setup:**
1. Two iPhones with VeriCall installed
2. Both users complete onboarding
3. Both users in same room (for demo)

**Demo Flow:**
1. **Show Onboarding** (30 sec)
   - Phone verification
   - Device key generation
   - Voice enrollment

2. **Show Contact List** (15 sec)
   - See verified contacts
   - Green checkmark = device verified

3. **Initiate Call** (30 sec)
   - User A calls User B
   - User B sees: "Incoming from Alice - ✓ Device Verified"
   - User B answers

4. **Live Voice Matching** (45 sec)
   - Screen shows: "Voice Match: 94%"
   - User A speaks → percentage updates
   - Have User C speak → shows "⚠️ Voice Mismatch: 31%"
   - Crowd goes wild

5. **Technical Deep Dive** (30 sec)
   - Show cryptographic verification
   - Explain voice embeddings
   - Mention 1000+ user capacity

**Total: 2.5 minutes**

---

## 🛡️ Security Considerations

- **Device Keys:** Stored in iOS SecureEnclave, never leaves device
- **Voice Data:** Encrypted in transit and at rest
- **Call Signaling:** WebSocket over WSS (TLS)
- **Voice Embeddings:** One-way hash, can't reconstruct voice
- **Rate Limiting:** Prevent abuse of voice verification API

---

## 💡 Potential Extensions (Post-Hackathon)

- **Blockchain attestation** - Store verification on-chain
- **Cross-platform** - Android app
- **Enterprise** - API for banks, call centers
- **AI Voice Cloning Detection** - Detect deepfake voices specifically
- **Video Verification** - Add facial recognition

---

**END OF TECH SPEC**
