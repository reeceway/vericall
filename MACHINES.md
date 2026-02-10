# VeriCall - WHERE TO RUN WHAT

## 🖥️ MACHINE BREAKDOWN

| Task | Machine | Why |
|------|---------|-----|
| **Backend Deploy** | Any computer (Mac/PC/Pi) | Just needs `fly` CLI installed |
| **iOS App Build** | **Mac with Xcode ONLY** | Xcode is macOS-only |
| **Testing** | 2 iPhones | The actual app runs here |

---

## 🔧 OPTION A: Deploy from Your Mac (Easiest)

Since you need a Mac for Xcode anyway, do EVERYTHING from there:

### 1. Copy Project to Mac
```bash
# On your Mac, open Terminal
# Copy the project from Pi to Mac:
scp -r moltbot@YOUR_PI_IP:/opt/moltbot/.openclaw/workspace/projects/vericall ~/Desktop/

# Or use Finder > Go > Connect to Server
# smb://YOUR_PI_IP/share
```

### 2. Deploy Backend from Mac
```bash
cd ~/Desktop/vericall/backend

# Install Fly CLI (one-time)
curl -L https://fly.io/install.sh | sh
export PATH="$HOME/.fly/bin:$PATH"

# Login to Fly (one-time)
fly auth login

# Deploy
./deploy.sh
```

### 3. Build iOS App (Mac only)
```bash
open ~/Desktop/vericall/ios/VeriCall.xcodeproj
```
- Set your Team in Signing & Capabilities
- Connect iPhone, press Cmd+R

---

## 🔧 OPTION B: Deploy from Pi, Build on Mac

### 1. Deploy Backend from Pi
```bash
# SSH into your Pi
ssh moltbot@your-pi-ip

# Navigate to project
cd /opt/moltbot/.openclaw/workspace/projects/vericall/backend

# Deploy
./deploy.sh
```

### 2. Copy iOS Project to Mac
```bash
# On Mac
scp -r moltbot@YOUR_PI_IP:/opt/moltbot/.openclaw/workspace/projects/vericall/ios ~/Desktop/vericall-ios
```

### 3. Build on Mac
```bash
open ~/Desktop/vericall-ios/VeriCall.xcodeproj
```

---

## 🔧 OPTION C: Local Backend (No Deploy)

Don't deploy to Fly.io - run backend on your Mac locally:

### 1. On Mac
```bash
# Copy project from Pi
scp -r moltbot@YOUR_PI_IP:/opt/moltbot/.openclaw/workspace/projects/vericall/backend ~/Desktop/vericall-backend

# Install dependencies
cd ~/Desktop/vericall-backend
pip3 install -r requirements.txt

# Run locally
uvicorn app.main:app --host 0.0.0.0 --port 3000
```

### 2. Update iOS to Point to Mac
```swift
// In Constants.swift, change:
static let apiBaseURL = "http://YOUR_MAC_IP:3000/api/v1"
static let wsBaseURL = "ws://YOUR_MAC_IP:3000/ws"
```

### 3. Build & Test
Same as before - both phones connect to your Mac on local network.

---

## 📋 QUICK DECISION TREE

```
Do you have a Mac with Xcode?
│
├─ YES → Do everything on Mac (Option A)
│        Copy project from Pi once, then work on Mac
│
└─ NO  → You CANNOT build iOS app
         iOS apps REQUIRE Xcode which is Mac-only
         
         Alternatives:
         - Borrow a Mac
         - Use MacinCloud (cloud Mac)
         - Find a teammate with a Mac
```

---

## 🎯 RECOMMENDED: All on Mac

1. **Copy project from Pi to Mac** (one time)
2. **Deploy backend** from Mac terminal
3. **Build iOS app** in Xcode on Mac
4. **Test** on 2 iPhones

All the code is already written - you just need to:
- Deploy the backend (5 min)
- Build in Xcode (10 min)
- Test (5 min)

---

## ❓ FAQ

**Q: Can I build iOS app on Pi?**
A: No. Xcode only runs on macOS.

**Q: Can I deploy backend from Windows?**
A: Yes. Install Fly CLI for Windows, run `deploy.bat` instead.

**Q: Do I need Apple Developer account?**
A: Yes ($99/year) to run on physical iPhone. Or use simulator (limited testing).

**Q: Can I test with 2 simulators instead of real phones?**
A: Partially - device verification works, but voice matching needs real microphone.

---

## 🚀 COMMANDS SUMMARY (Mac)

```bash
# 1. Get project from Pi
scp -r moltbot@PI_IP:/opt/moltbot/.openclaw/workspace/projects/vericall ~/Desktop/

# 2. Deploy backend
cd ~/Desktop/vericall/backend
./deploy.sh

# 3. Build iOS app
open ~/Desktop/vericall/ios/VeriCall.xcodeproj
# In Xcode: Set team, connect iPhone, Cmd+R
```
