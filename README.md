# VeriCall 🛡️

**Know Who's Really Calling**

AI voice clone detection for iOS. Real-time protection against voice scams and deepfake fraud.

[![iOS](https://img.shields.io/badge/platform-iOS-blue)](https://github.com/reeceway/vericall)
[![Swift](https://img.shields.io/badge/language-Swift-orange)](https://swift.org)
[![Python](https://img.shields.io/badge/backend-Python-green)](https://python.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## 🚨 The Problem

AI voice scams stole **$10 billion** last year. Scammers can clone your voice with just **3 seconds** of audio and trick your family into sending money. Most people can't tell the difference between real and AI-generated voices.

## ✨ The Solution

VeriCall detects AI-generated voices in **real-time during calls** using on-device machine learning.

### Key Features

- 🔐 **Real-time Detection** - Analyzes voice patterns during active calls
- 📱 **On-Device ML** - Complete privacy, audio never leaves your phone
- ⚡ **Instant Alerts** - Know immediately if a voice is AI-generated
- 🎯 **94%+ Accuracy** - ConvNeXt deep learning model
- 🔒 **Secure** - WebRTC + CoreML, zero cloud processing

## 🎥 Demo

[Demo Video Coming Soon]

## 🏗️ Architecture

```
iOS App (SwiftUI)
├── WebRTC Calling
├── CoreML Voice Detection
├── Secure Enclave Key Storage
└── WebSocket Signaling

Backend (FastAPI)
├── Phone OTP Auth
├── Device Verification (ECDSA)
├── Call Signaling
└── PostgreSQL + Redis

Deployment: Fly.io (Auto-scaling)
```

## 🚀 Getting Started

### Beta Testing

1. Join TestFlight beta (10 spots available)
2. Install the iOS app
3. Verify your phone number
4. Make a test call to another beta user
5. Try voice clone detection

**[Apply for Beta Access →](mailto:reece@redemptionanalytics.com)**

### Development Setup

```bash
# Clone repo
git clone https://github.com/reeceway/vericall.git
cd vericall

# Backend
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload

# iOS (requires Xcode)
cd ios/VeriCall
open VeriCall.xcodeproj
```

## 📱 Tech Stack

- **iOS**: SwiftUI, WebRTC, CoreML, SecureEnclave
- **Backend**: FastAPI, PostgreSQL, Redis
- **ML**: ConvNeXt (voice detection), custom embeddings
- **Infra**: Fly.io, Docker

## 🎯 Hackathon Build

Built in **10 days** for a hackathon:

- Day 1-2: Architecture & design
- Day 3-5: Backend API & WebRTC
- Day 6-8: iOS app & voice detection
- Day 9-10: Polish & demo prep

## 📊 Stats

- 39 Swift files
- 8 Python modules
- 0 cloud dependencies for ML
- 100% on-device privacy

## 🔮 Roadmap

- [ ] App Store submission
- [ ] Android version
- [ ] Advanced voice fingerprinting
- [ ] Enterprise API

## 🤝 Contributing

This is a hackathon project. Beta feedback welcome!

## 📄 License

MIT

## 👤 Maker

**Reece Way**
- Email: reece@redemptionanalytics.com
- Twitter: [@reeceway](https://twitter.com/reeceway)
- GitHub: [@reeceway](https://github.com/reeceway)

---

<p align="center">Built with ❤️ for the future of secure calling</p>
