# Project Status: vericall

Created: Mon  9 Feb 18:13:08 EST 2026
Updated: Mon  9 Feb 19:15 EST 2026

## Backend Dev (Agent #1)
- Status: ✅ COMPLETE - EXACT API CONTRACT IMPLEMENTED
- Task: FastAPI backend with exact specifications from TECH_SPEC.md
- Time Budget: 4-5 hours (2.5 hours actual)
- Blockers: None

### Deliverables Completed (EXACT API Contract):

#### EXACT Constants Implemented:
```python
VOICE_SAMPLE_RATE = 16000
VOICE_EMBEDDING_DIMENSION = 192  # Changed from 256
VOICE_MATCH_THRESHOLD = 0.75     # Changed from 0.85
VOICE_WARNING_THRESHOLD = 0.55   # New
SIGNATURE_ALGORITHM = "ECDSA-P256-SHA256"
```

#### EXACT API Endpoints Implemented:

**Authentication:**
- ✅ POST /api/v1/auth/request-otp
- ✅ POST /api/v1/auth/verify-otp (with publicKey, deviceId)
- ✅ POST /api/v1/auth/refresh

**Users:**
- ✅ GET /api/v1/users/me
- ✅ PATCH /api/v1/users/me

**Contacts:**
- ✅ POST /api/v1/contacts/sync

**Voice (192-dim embeddings):**
- ✅ POST /api/v1/voice/enroll (embedding: 192 floats)
- ✅ GET /api/v1/voice/voiceprint/{userId}
- ✅ POST /api/v1/voice/verify

**Calls (with ECDSA signatures):**
- ✅ POST /api/v1/calls/initiate (includes signature)
- ✅ POST /api/v1/calls/answer
- ✅ POST /api/v1/calls/end

**WebSocket:**
- ✅ WS /ws (exact event protocol from spec)

#### Database Schema (PostgreSQL):
```sql
users: id, phone_number, display_name, device_id, device_public_key, 
       voice_enrolled, push_token, ...
otps: id, phone_number, code_hash, is_used, attempts, expires_at
refresh_tokens: id, user_id, token_hash, device_id, is_revoked, expires_at
voice_prints: id, user_id, embedding[192], quality_score, sample_count
calls: id, caller_id, recipient_id, status, caller_signature, 
       voice_match_scores, average_voice_match, ...
```

#### Services:
1. **device_verification.py** - ECDSA P-256 signature verification, JWT tokens
2. **voice_ml.py** - Cosine similarity for 192-dim embeddings
3. **redis_service.py** - Sessions, presence, call state, notifications

#### Deployment:
- ✅ Dockerfile - Multi-stage build
- ✅ fly.toml - Fly.io config (vericall-api.fly.dev)
- ✅ deploy.sh - Automated deployment script
- ✅ README.md - Complete API docs
- ✅ API_QUICK_REFERENCE.md - iOS team reference

### File Structure:
```
backend/
├── app/
│   ├── config.py              # EXACT constants from spec
│   ├── main.py                # FastAPI with WebSocket
│   ├── models/
│   │   └── database.py        # Updated schema (OTP, RefreshToken, 192-dim)
│   ├── routes/
│   │   ├── auth.py            # OTP flow, JWT tokens
│   │   ├── calls.py           # Signature-based calls
│   │   ├── voice.py           # 192-dim embeddings
│   │   └── contacts.py        # Contact sync
│   └── services/
│       ├── device_verification.py  # ECDSA-P256
│       ├── voice_ml.py        # 192-dim similarity
│       └── redis_service.py   # Sessions/notifications
├── migrations/
│   └── versions/
│       └── 20250209_1800_initial_schema.py
├── Dockerfile
├── fly.toml
├── deploy.sh
└── README.md
```

## iOS Onboarding (Agent #2)
- Status: ✅ COMPLETE - API CONTRACT UPDATED
- Task: SwiftUI onboarding flow with exact API specifications from TECH_SPEC.md
- Current: All components using exact constants and API endpoints
- Blockers: None

### Deliverables Completed (Updated for Exact API Contract):

#### EXACT Constants Implemented (from TECH_SPEC.md):
```swift
static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
static let wsBaseURL = "wss://vericall-api.fly.dev"
static let voiceSampleRate: Double = 16000
static let voiceEmbeddingDimension = 192
static let voiceMatchThreshold: Float = 0.75
static let voiceWarningThreshold: Float = 0.55
static let signatureAlgorithm = "ECDSA-P256-SHA256"
```

#### EXACT API Endpoints Implemented:
1. **POST /api/v1/auth/request-otp** - Request OTP (replaces send-code)
2. **POST /api/v1/auth/verify-otp** - Verify OTP, returns accessToken/refreshToken
3. **POST /api/v1/auth/refresh** - Refresh access token
4. **GET /api/v1/users/me** - Get user profile
5. **PATCH /api/v1/users/me** - Update user profile
6. **POST /api/v1/contacts/sync** - Sync contacts
7. **POST /api/v1/voice/enroll** - Enroll voice with 192-dim embedding
8. **GET /api/v1/voice/voiceprint/{userId}** - Get voiceprint
9. **POST /api/v1/calls/initiate** - Initiate call with signature
10. **POST /api/v1/calls/answer** - Answer call
11. **POST /api/v1/calls/end** - End call

#### SwiftUI Onboarding Flow (4 screens):
1. **WelcomeView.swift** - App intro with animated logo
2. **PhoneInputView.swift** - Phone input → calls request-otp
3. **VerificationCodeView.swift** - 6-digit code → calls verify-otp with publicKey
4. **VoiceEnrollmentView.swift** - Records samples → calls enroll with 192-dim embedding

#### Services (Updated):
1. **DeviceCrypto.swift** - ECDSA-P256-SHA256, exports base64 public key
2. **APIService.swift** - Exact API contract, JWT token management
3. **KeychainService.swift** - Stores accessToken, refreshToken, device keys
4. **AudioRecorder.swift** - 16kHz sample rate for voice

#### Models (Updated):
1. **User.swift** - User model with displayName, voiceEnrolled
2. **Call.swift** - Call state with signatures
3. **VoiceMatch.swift** - Uses exact thresholds (0.75 match, 0.55 warning)

### API Integration Flow:
```
1. PhoneInputView → POST /auth/request-otp
2. VerificationCodeView → POST /auth/verify-otp (with P-256 publicKey)
   → Stores: accessToken, refreshToken, userId
3. VoiceEnrollmentView → POST /voice/enroll (with 192-dim embedding)
```

### Mock Mode:
- OTP code: `123456`
- Mock tokens returned on verify-otp
- Mock embeddings generated for voice enrollment

## iOS Calling (Agent #3)
- Status: ✅ IN PROGRESS
- Task: CallKit integration, WebRTC calling, real-time voice matching UI
- Files Created:
  - ios/VeriCall/Services/CallKitManager.swift
  - ios/VeriCall/Services/CallManager.swift
  - ios/VeriCall/Services/CallWebSocketService.swift
  - ios/VeriCall/Services/AudioRecorder.swift
  - ios/VeriCall/Services/VoiceCaptureService.swift
- Time Budget: 3-4 hours
- Blockers: None

## Voice ML (Agent #4)
- Status: ✅ COMPLETED CORE MODULES
- Files Created:
  - voice-ml/speaker_model.py (192-dim embeddings)
  - voice-ml/voice_enrollment.py
  - voice-ml/voice_verification.py
  - voice-ml/test_voice_ml.py
  - voice-ml/demo_voice_ml.py
  - voice-ml/requirements.txt
- Time Budget: 4-5 hours (COMPLETE)
- Blockers: None

## Timeline
- Hour 0-1: ✅ Backend foundation, all agents started
- Hour 1-2.5: ✅ Backend API complete with EXACT API contract
- Hour 2.5-4: 🔄 iOS agents completing
- Hour 4-5: Integration begins
- Hour 6-7: Testing + bug fixes
- Hour 8: DEMO READY

## Integration Status
- ✅ Backend API ready with EXACT API contract
- ✅ API documentation delivered to iOS team
- ✅ WebSocket events match spec exactly
- ✅ All constants synchronized (192-dim, 0.75 threshold, P-256)
- 🔄 Awaiting iOS completion for full integration testing

## Key Synchronization Points
1. **192-dimension embeddings** - Both backend and iOS updated
2. **0.75 match threshold** - Backend and iOS using same value
3. **0.55 warning threshold** - New threshold added
4. **ECDSA-P256-SHA256** - Signature algorithm for call initiation
5. **JWT tokens** - accessToken/refreshToken flow
6. **WebSocket events** - Exact event names from spec
