# VeriCall - Mac Mini Setup Guide

## 🚀 Quick Start on Your Mac Mini

### Step 1: Clone the Project

**On your Mac Mini, open Terminal:**

```bash
# Option A: If I push to GitHub (give me your repo URL)
git clone https://github.com/YOUR_USERNAME/vericall.git
cd vericall

# Option B: Copy from Pi via SSH (if on same network)
scp -r moltbot@YOUR_PI_IP:/opt/moltbot/.openclaw/workspace/projects/vericall ~/Desktop/
cd ~/Desktop/vericall

# Option C: Use USB drive
# Copy /opt/moltbot/.openclaw/workspace/projects/vericall from Pi to USB
# Plug into Mac Mini, copy to Desktop
```

---

## 📦 PART 1: Deploy Backend

### 1.1 Install Dependencies

```bash
cd vericall/backend

# Install Fly CLI
curl -L https://fly.io/install.sh | sh
export PATH="$HOME/.fly/bin:$PATH"

# Add to your shell profile
echo 'export PATH="$HOME/.fly/bin:$PATH"' >> ~/.zshrc
```

### 1.2 Login to Fly.io

```bash
fly auth login
# This opens browser - login with your Fly.io account
```

### 1.3 Create Database (PostgreSQL)

**Option A: Supabase (Free)**
1. Go to https://supabase.com
2. Create new project
3. Get connection string: Settings → Database → Connection string
4. Copy the URI

**Option B: Neon (Free)**
1. Go to https://neon.tech
2. Create project
3. Get connection string from dashboard

### 1.4 Create Redis (Upstash)

1. Go to https://upstash.com
2. Create Redis database
3. Get Redis URL

### 1.5 Deploy

```bash
# Set secrets
fly secrets set DATABASE_URL="postgresql://..."
fly secrets set REDIS_URL="redis://..."
fly secrets set JWT_SECRET="$(openssl rand -hex 32)"

# Deploy
fly deploy

# Check status
fly status
fly logs
```

### 1.6 Test Deployment

```bash
# Health check
curl https://vericall-api.fly.dev/health

# Should return: {"status":"ok"}
```

---

## 📱 PART 2: Build iOS App

### 2.1 Open in Xcode

```bash
open ios/VeriCall.xcodeproj
```

### 2.2 Configure Signing

1. In Xcode, click **"VeriCall"** in left sidebar
2. Go to **"Signing & Capabilities"** tab
3. Under **"Team"**, select your Apple Developer account
   - If none, click "Add Account" and sign in
4. **Bundle Identifier**: Change to something unique
   - Example: `com.reece.vericall`

### 2.3 Enable Capabilities

Make sure these are enabled (should already be set):
- ✅ Push Notifications
- ✅ Background Modes: Audio, VoIP, Fetch

### 2.4 Build & Run

1. Connect iPhone #1 via USB
2. Select your iPhone from device dropdown (top of Xcode window)
3. Press **Cmd+R** to build and run
4. Wait for app to install and launch

### 2.5 Install on Second iPhone

1. Connect iPhone #2
2. Select it from device dropdown
3. Press **Cmd+R**

---

## 🧪 PART 3: Test the Demo

### 3.1 Onboard Phone #1 (Alice)

1. Open VeriCall app
2. **Phone Number**: `+15550001111`
3. **OTP**: `123456` (auto-filled)
4. **Name**: "Alice"
5. **Voice Enrollment**: Record 5 phrases
   - "The quick brown fox jumps over the lazy dog"
   - "She sells seashells by the seashore"
   - "How much wood would a woodchuck chuck"
   - "Hello, this is my voice for verification"
   - "One two three four five six seven eight nine zero"

### 3.2 Onboard Phone #2 (Bob)

1. Open VeriCall app
2. **Phone Number**: `+15550002222`
3. **OTP**: `123456`
4. **Name**: "Bob"
5. **Voice Enrollment**: Record same 5 phrases

### 3.3 Sync Contacts

On both phones:
1. Go to Contacts tab
2. Pull to refresh
3. Should see the other person

### 3.4 Make Test Call

**From Alice's phone:**
1. Tap "Bob" in contacts
2. Tap call button
3. Bob's phone shows: **"Incoming from Alice - ✓ Device Verified"**

**On Bob's phone:**
1. See the green "✓ Device Verified" badge
2. Answer the call
3. During call, see **"Voice Match: 90%+"** when Alice speaks
4. Have someone else speak into Alice's phone
5. Watch match drop to **"Voice Mismatch: 30%"**

---

## 🎤 Demo Script (For Hackathon)

```
"AI can clone anyone's voice. VeriCall solves this with two layers."

[Show Alice's phone]
"First, cryptographic device verification."

[Alice taps call]
"When Alice calls Bob, her phone signs the request."

[Show Bob's incoming call]
"Bob sees this BEFORE answering - Alice's device is verified."

[Bob answers]
"But what if someone stole Alice's phone?"

[Alice speaks]
"Voice verification happens entirely on Bob's phone."

[Show match percentage]
"94% match - it's really Alice."

[Different person speaks]
"If someone else speaks..."

[Show mismatch alert]
"Immediately, Bob sees the warning."

"Two layers: Device + Voice. VeriCall."
```

---

## 🐛 Troubleshooting

### Build Errors

**"No signing team"**
→ Add Apple Developer account in Xcode → Preferences → Accounts

**"Could not find module"**
→ Clean build: Cmd+Shift+K, then rebuild

**"App installation failed"**
→ Trust developer: Settings → General → VPN & Device Management → Trust

### Backend Issues

**"Database connection failed"**
→ Check DATABASE_URL format

**"Redis connection failed"**
→ Check REDIS_URL

**"Port already in use"**
→ Kill process: `lsof -ti:3000 | xargs kill -9`

### Call Issues

**"WebSocket not connecting"**
→ Check firewall, ensure wss:// URL is correct

**"Voice match always 0%"**
→ Check microphone permissions
→ Ensure voice enrollment completed

**"Call not received"**
→ Check push notification permissions
→ Ensure both phones online

---

## 📊 Project Structure

```
vericall/
├── backend/              # FastAPI Python backend
│   ├── app/
│   │   ├── main.py       # API routes
│   │   ├── auth.py       # JWT/OTP
│   │   ├── crypto.py     # Signature verification
│   │   ├── models.py     # Database models
│   │   └── websocket.py  # Real-time signaling
│   ├── fly.toml          # Deployment config
│   └── deploy.sh         # Deploy script
│
├── ios/                  # SwiftUI iOS app
│   └── VeriCall/
│       ├── App/          # App entry, constants
│       ├── Views/        # SwiftUI screens
│       ├── Services/     # API, crypto, voice
│       └── Models/       # Data models
│
├── TECH_SPEC.md          # Full technical spec
└── README.md             # This guide
```

---

## 💰 Costs

| Service | Cost |
|---------|------|
| Fly.io (backend) | ~$5/month |
| Supabase (database) | Free tier |
| Upstash (Redis) | Free tier |
| Apple Developer | $99/year |
| **Total** | **~$5/month + $99/year** |

---

## 🎯 Quick Commands

```bash
# Deploy backend
cd backend
fly deploy

# View logs
fly logs

# Restart
fly restart

# Scale up (for hackathon demo)
fly scale count 2
```

---

## ✅ Pre-Hackathon Checklist

- [ ] Backend deployed to Fly.io
- [ ] iOS app builds on Mac Mini
- [ ] 2 iPhones with app installed
- [ ] Both users enrolled with voice
- [ ] Test call works (device + voice verification)
- [ ] Demo script practiced
- [ ] Backup: Screen recording of working demo

---

**Questions? Check TECH_SPEC.md for full API documentation.**

**Good luck at the hackathon! 🚀**
