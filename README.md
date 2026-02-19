# VeriCall 🛡️

**Know Who's Really Calling**

AI voice clone detection for iOS. Real-time protection against voice scams and deepfake fraud.

[![iOS](https://img.shields.io/badge/platform-iOS-blue)](https://github.com/reeceway/vericall)
[![Swift](https://img.shields.io/badge/language-Swift-orange)](https://swift.org)
[![Python](https://img.shields.io/badge/backend-Python-green)](https://python.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## The Problem

AI voice scams stole **$10 billion** last year. Scammers can clone your voice with just **3 seconds** of audio and trick your family into sending money. Traditional approaches try to detect fake voices after the fact — an arms race defenders keep losing.

VeriCall takes the opposite approach: **verify the real thing, don't chase fakes**.

---

## How It Works

Every VeriCall user has two layers of identity anchored to their device:

**1. Device Verification (before answering)**
The caller's iPhone signs the call request using a private key that never leaves the device's Secure Enclave. The recipient sees "✓ Device Verified" before picking up — cryptographic proof the call came from the registered phone.

**2. Voice Verification (during the call)**
The app extracts 192-dimensional voice embeddings from the live audio stream and compares them against the caller's enrolled voice print using cosine similarity. A live score — "Voice Match: 94%" — updates every few seconds throughout the call.

**3. Deepfake Detection (real-time)**
A WavLM CoreML model runs fully on-device, flagging AI-generated audio with ~84% accuracy at ~50ms latency.

### Key Features

- 🔐 **Cryptographic device signing** — ECDSA-P256, private key never leaves Secure Enclave
- 📱 **On-device ML** — complete privacy, audio never leaves your phone
- ⚡ **Real-time alerts** — voice match score updates every 4 seconds during a call
- 🎯 **High accuracy** — WavLM deepfake detector + 192-dim speaker embeddings
- 🔒 **P2P audio** — QUIC transport direct device-to-device, backend never touches audio

---

## Architecture

```
┌───────────────────────────────────────────────────────┐
│                  iOS App (Swift)                      │
│                                                       │
│  Onboarding ──► CallKit ──► Voice ML ──► Deepfake    │
│  (OTP + key)    (QUIC P2P)  (192-dim)   (WavLM)     │
└─────────────────────────┬─────────────────────────────┘
                          │  HTTPS + WebSocket (signaling only)
                          ▼
┌───────────────────────────────────────────────────────┐
│              Backend (FastAPI / Python)               │
│         deployed at vericall-api.fly.dev              │
│                                                       │
│  /auth/*  ──  /voice/*  ──  /calls/*  ──  WS /ws    │
│                                                       │
│  PostgreSQL (Supabase)     Redis (Upstash)            │
└───────────────────────────────────────────────────────┘
```

**Media transport**: Direct P2P via QUIC (Apple's Network.framework), with WebSocket used only for signaling. The backend never touches audio.

---

## Key Numbers

| Parameter | Value |
|-----------|-------|
| Voice embedding dimensions | 192 |
| Voice match threshold | ≥ 0.75 (isMatch = true) |
| Voice warning threshold | < 0.55 |
| Audio sample rate | 16 kHz mono PCM |
| Verification chunk size | 3 seconds, every 4 seconds |
| Deepfake detection latency | ~50 ms |
| Deepfake detection accuracy | ~84% |
| Signature algorithm | ECDSA-P256-SHA256 |
| Backend URL | `https://vericall-api.fly.dev` |

---

## Repository Structure

```
vericall/
├── ios/                    # Swift/SwiftUI iOS application
│   └── VeriCall/
│       ├── App/            # Entry point, constants, config
│       ├── Views/          # SwiftUI screens (onboarding, calling, settings)
│       ├── Services/       # Business logic (API, CallKit, crypto, audio)
│       └── Models/         # Data types
│
├── backend/                # Python FastAPI backend
│   └── app/
│       ├── main.py         # FastAPI app, WebSocket hub
│       ├── auth.py         # OTP + JWT authentication
│       ├── crypto.py       # ECDSA-P256 signature verification
│       ├── models.py       # SQLAlchemy models
│       └── websocket.py    # Signaling event handlers
│
├── voice-ml/               # Python voice embedding & verification
│   ├── speaker_model.py    # 192-dim embeddings (Resemblyzer)
│   ├── voice_enrollment.py # Enrollment from audio or embeddings
│   └── voice_verification.py # Real-time cosine similarity matching
│
└── model-eval/             # ML model evaluation scripts and results
```

---

## Quick Start

### Beta Testing

1. Join TestFlight beta (10 spots available)
2. Install the iOS app
3. Verify your phone number
4. Make a test call to another beta user

**[Apply for Beta Access →](mailto:reece@redemptionanalytics.com)**

### Run the backend locally

```bash
cd backend
pip install -r requirements.txt

docker run -d --name vericall-db \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=vericall -p 5432:5432 postgres:15

uvicorn app.main:app --reload
# Swagger UI: http://localhost:8000/docs
```

### Run the iOS app

1. Open `ios/VeriCall.xcodeproj` in Xcode 15+
2. Set your development team in Signing & Capabilities
3. Enable: Push Notifications, Background Modes (Remote Notifications, VoIP, Audio)
4. Build and run on a physical device or simulator

For full setup instructions see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Tech Stack

**iOS**: Swift 5.9, SwiftUI, CallKit, AVFoundation, Network.framework (QUIC), CoreML, CryptoKit, SecureEnclave, Firebase FCM

**Backend**: Python 3.9, FastAPI, SQLAlchemy 2.0 (async), PostgreSQL, Redis, Twilio SMS, Fly.io

**Voice ML**: Resemblyzer (GE2E speaker encoder), LibROSA, NumPy, SciPy

**ML Models**: WavLM (deepfake detection, FP16 CoreML), Resemblyzer 256→192 dim reduction

---

## Documentation Index

| Document | What it covers |
|----------|---------------|
| [TECH_SPEC.md](TECH_SPEC.md) | Complete API contract, exact constants, agent assignments |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Developer setup, local dev workflow, environment variables |
| [SECURITY.md](SECURITY.md) | Threat model, cryptographic design, trust boundaries |
| [WEBSOCKET_PROTOCOL.md](WEBSOCKET_PROTOCOL.md) | WebSocket event reference (all client ↔ server events) |
| [DEPLOY_AND_TEST.md](DEPLOY_AND_TEST.md) | Step-by-step deployment and integration testing |
| [P2P_ARCHITECTURE.md](P2P_ARCHITECTURE.md) | QUIC/MoQ media transport, Bonjour discovery |
| [HYBRID_ARCHITECTURE.md](HYBRID_ARCHITECTURE.md) | Cloud + local voice verification design |
| [ALGORITHM.md](ALGORITHM.md) | WavLM deepfake detection model details |
| [LOCAL_VOICE.md](LOCAL_VOICE.md) | Spectral fingerprinting for local-only verification |
| [QUANTIZATION_ANALYSIS.md](QUANTIZATION_ANALYSIS.md) | CoreML model quantization (FP16 vs FP32) |
| [BUSINESS_MODEL.md](BUSINESS_MODEL.md) | Enterprise go-to-market strategy |
| [CONSUMER_BUSINESS_MODEL.md](CONSUMER_BUSINESS_MODEL.md) | Consumer-facing product strategy |
| [STATUS.md](STATUS.md) | Build status and task completion tracker |
| [backend/README.md](backend/README.md) | Backend API reference |
| [ios/README.md](ios/README.md) | iOS app API integration details |
| [voice-ml/README.md](voice-ml/README.md) | Voice ML module usage |

---

## Roadmap

- [ ] App Store submission
- [ ] Android version
- [ ] Advanced voice fingerprinting
- [ ] Enterprise API

---

## Maker

**Reece Way**
- Email: reece@redemptionanalytics.com
- Twitter: [@reeceway](https://twitter.com/reeceway)
- GitHub: [@reeceway](https://github.com/reeceway)

---

## License

MIT

---

<p align="center">Built with ❤️ for the future of secure calling</p>
