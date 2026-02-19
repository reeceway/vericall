# Contributing to VeriCall

This guide covers local development setup for all three components: the backend API, the iOS app, and the voice ML module.

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Xcode | 15+ | iOS development |
| Python | 3.9+ | Backend + voice ML |
| Docker | any | Local PostgreSQL |
| Fly CLI | latest | Backend deployment |
| Node/npm | optional | Tooling scripts |

---

## 1. Backend

### Environment Variables

Create `backend/.env`:

```bash
# Database
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/vericall

# Redis (Upstash or local)
REDIS_URL=redis://localhost:6379

# JWT
JWT_SECRET=your-local-dev-secret-min-32-chars
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
REFRESH_TOKEN_EXPIRE_DAYS=30

# Twilio (OTP SMS)
TWILIO_ACCOUNT_SID=your-twilio-sid
TWILIO_AUTH_TOKEN=your-twilio-token
TWILIO_PHONE_NUMBER=+15550000000

# Firebase (push notifications)
FIREBASE_CREDENTIALS_JSON=path/to/firebase-credentials.json

# APNS (Apple push notifications)
APNS_KEY_PATH=path/to/AuthKey.p8
APNS_KEY_ID=your-key-id
APNS_TEAM_ID=your-team-id
APNS_BUNDLE_ID=com.yourteam.VeriCall
```

> For local testing you can skip Twilio and Firebase — use the iOS app's mock mode instead.

### Start the backend

```bash
cd backend

# Create virtual environment
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Start PostgreSQL
docker run -d --name vericall-db \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=vericall \
  -p 5432:5432 postgres:15

# Start Redis (optional, for WebSocket sessions)
docker run -d --name vericall-redis -p 6379:6379 redis:7

# Run migrations
alembic upgrade head

# Start the server (hot reload)
uvicorn app.main:app --reload --port 8000
```

The API and interactive docs are at `http://localhost:8000/docs`.

### Running tests

```bash
cd backend
pytest
```

### Deploy to Fly.io

```bash
cd backend
fly deploy
```

The app is configured in `fly.toml` and deploys to `vericall-api.fly.dev`.

---

## 2. iOS App

### Xcode setup

1. Open `ios/VeriCall.xcodeproj` in Xcode 15+
2. Select your target device or simulator
3. Under **Signing & Capabilities**:
   - Set your Apple Developer team
   - Enable **Push Notifications**
   - Enable **Background Modes**: Remote notifications, VoIP, Audio
4. Add `GoogleService-Info.plist` for Firebase (obtain from Firebase Console)

### Pointing at local backend

Edit [ios/VeriCall/App/Constants.swift](ios/VeriCall/App/Constants.swift):

```swift
// Development
static let apiBaseURL = "http://localhost:8000/api/v1"
static let wsBaseURL  = "ws://localhost:8000"

// Production
// static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
// static let wsBaseURL  = "wss://vericall-api.fly.dev"
```

> On a physical device, replace `localhost` with your Mac's LAN IP (e.g., `192.168.1.x`).

### Mock mode

The app ships with a mock mode that bypasses the backend entirely. To enable it, set in [ios/VeriCall/Services/APIService.swift](ios/VeriCall/Services/APIService.swift):

```swift
private let useMockData = true
```

In mock mode:
- OTP code is always `123456`
- Tokens are synthetic JWTs
- Voice embeddings are randomly generated (192-dim)

This lets you work on UI without running a backend at all.

### ECDSA keys on simulator

The Secure Enclave is unavailable in the iOS Simulator. The app automatically falls back to software-backed Keychain keys in that environment — behavior is identical from the app's perspective.

---

## 3. Voice ML

### Setup

```bash
cd voice-ml

python -m venv venv
source venv/bin/activate

pip install -r requirements.txt

# Download the Resemblyzer speaker model on first use
python -c "from resemblyzer import VoiceEncoder; VoiceEncoder()"
```

### Running the demo

```bash
python demo_voice_ml.py
```

### Running tests

```bash
python test_voice_ml.py
```

### Manual API calls

```bash
# Enroll a voice
curl -X POST http://localhost:8000/api/v1/voice/enroll \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"embedding": [0.1, -0.2, ...], "sampleCount": 5}'

# Verify during a call
curl -X POST http://localhost:8000/api/v1/voice/verify \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"embedding": [0.1, -0.2, ...], "userId": "uuid-here"}'
```

---

## Shared Constants

All three components must stay in sync on these values. If you change any of them, update all three:

| Constant | Value | Defined in |
|----------|-------|-----------|
| Embedding dimensions | `192` | `Constants.swift`, `config.py`, `speaker_model.py` |
| Match threshold | `0.75` | `Constants.swift`, `config.py`, `voice_verification.py` |
| Warning threshold | `0.55` | `Constants.swift`, `config.py`, `voice_verification.py` |
| Audio sample rate | `16000` Hz | `Constants.swift`, `config.py`, `voice_enrollment.py` |
| Signature algorithm | `ECDSA-P256-SHA256` | `Constants.swift`, `crypto.py` |

---

## Project Layout

```
vericall/
├── backend/
│   ├── app/
│   │   ├── main.py           # FastAPI app + WebSocket hub
│   │   ├── auth.py           # OTP flow, JWT management
│   │   ├── crypto.py         # ECDSA-P256 signature verification
│   │   ├── models.py         # SQLAlchemy ORM models
│   │   ├── database.py       # Async database session
│   │   ├── websocket.py      # Signaling event handlers
│   │   ├── push.py           # Firebase FCM
│   │   └── push_apns.py      # Apple APNS
│   ├── migrations/           # Alembic migrations
│   ├── Dockerfile
│   ├── fly.toml
│   └── requirements.txt
│
├── ios/VeriCall/
│   ├── App/
│   │   ├── VeriCallApp.swift         # @main entry point
│   │   ├── AppDelegate.swift         # Lifecycle, push registration
│   │   ├── RootView.swift            # Navigation root
│   │   └── Constants.swift           # All shared constants
│   ├── Services/
│   │   ├── APIService.swift          # REST client, JWT refresh
│   │   ├── CallManager.swift         # Call orchestration
│   │   ├── CallWebSocketService.swift # WS signaling
│   │   ├── VoIPCallService.swift     # CallKit integration
│   │   ├── RTPAudioService.swift     # RTP audio transport
│   │   ├── MoQTransportService.swift # QUIC P2P transport
│   │   ├── AudioStreamService.swift  # Capture + playback
│   │   ├── DeepfakeDetectionService.swift # WavLM CoreML
│   │   ├── StorageService.swift      # Keychain wrapper
│   │   └── NativeCallObserver.swift  # Call state observer
│   ├── Views/                        # SwiftUI screens
│   └── Models/                       # Data types
│
└── voice-ml/
    ├── speaker_model.py      # Core: 192-dim embedding extraction
    ├── voice_enrollment.py   # Enrollment service
    ├── voice_verification.py # Real-time verification
    ├── test_voice_ml.py      # Tests
    └── demo_voice_ml.py      # Demo script
```

---

## WebSocket Development

The WebSocket endpoint (`WS /ws?token=<jwt>`) handles all call signaling. For development you can connect with any WS client:

```bash
# Using websocat
websocat "ws://localhost:8000/ws?token=$TOKEN"

# Send a ping
{"type": "ping"}
```

See [WEBSOCKET_PROTOCOL.md](WEBSOCKET_PROTOCOL.md) for the full event reference.

---

## Database Migrations

```bash
cd backend

# Create a new migration after changing models.py
alembic revision --autogenerate -m "describe your change"

# Apply migrations
alembic upgrade head

# Roll back one step
alembic downgrade -1
```

---

## Pull Request Checklist

- [ ] All three components still use the same constants (embedding dim, thresholds, sample rate)
- [ ] Backend API changes are reflected in `TECH_SPEC.md`
- [ ] WebSocket event changes are reflected in `WEBSOCKET_PROTOCOL.md`
- [ ] New iOS capabilities are noted in the Xcode setup section above
- [ ] `voice-ml` tests pass: `python test_voice_ml.py`
