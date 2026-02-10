# VeriCall - Complete Deployment & Testing Guide

## 🚀 QUICK START (TL;DR)

### Step 1: Deploy Backend (5 minutes)
```bash
cd /projects/vericall/backend
./deploy.sh
```

You'll need:
- Fly.io account (free tier works)
- PostgreSQL database URL (Supabase or Neon)
- Redis URL (Upstash or Redis Cloud)

### Step 2: Build iOS App (10 minutes)
1. Open `/projects/vericall/ios/VeriCall.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Build to 2 iPhones

### Step 3: Test (5 minutes)
1. Onboard Phone 1 with number +15550001111
2. Onboard Phone 2 with number +15550002222  
3. Phone 1 calls Phone 2
4. Verify "✓ Device Verified" shows
5. Answer and verify voice matching works

---

## 📱 DETAILED iOS BUILD INSTRUCTIONS

### Prerequisites
- macOS with Xcode 15+
- 2 iPhones (iOS 17+)
- Apple Developer account (for device signing)

### Build Steps

1. **Open Project**
   ```
   open /projects/vericall/ios/VeriCall.xcodeproj
   ```

2. **Configure Signing**
   - Select "VeriCall" target
   - Go to "Signing & Capabilities"
   - Set Team to your Apple Developer account
   - Bundle Identifier: `com.vericall.app` (or your own)

3. **Enable Capabilities** (should already be set)
   - Push Notifications
   - Background Modes: Audio, VoIP
   - Keychain Sharing

4. **Build & Run**
   - Connect iPhone via USB
   - Select device in Xcode
   - Press Cmd+R to build and run
   - Repeat on second iPhone

---

## 🔧 BACKEND DEPLOYMENT OPTIONS

### Option A: Fly.io (Recommended)
```bash
cd /projects/vericall/backend
./deploy.sh
```

### Option B: Local Testing (No deploy needed)
```bash
cd /projects/vericall/backend
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 3000
```
Then update iOS `Constants.swift`:
```swift
static let apiBaseURL = "http://YOUR_MAC_IP:3000/api/v1"
static let wsBaseURL = "ws://YOUR_MAC_IP:3000/ws"
```

---

## 🧪 TESTING CHECKLIST

### Test 1: Onboarding Flow
- [ ] App launches to Welcome screen
- [ ] Enter phone number → OTP requested
- [ ] Enter 123456 → Keys generated
- [ ] Profile setup complete
- [ ] Voice enrollment (5 phrases) works
- [ ] "Voice ID Created" shows at end

### Test 2: Device Verification
- [ ] Phone 1 shows Phone 2 in contacts
- [ ] Tap call → "Calling..." with verification
- [ ] Phone 2 shows incoming call
- [ ] "✓ Device Verified" badge visible
- [ ] Different device shows "✗ Unverified"

### Test 3: Voice Matching
- [ ] Answer call on Phone 2
- [ ] Phone 1 speaks → match % increases
- [ ] ~85-95% match for enrolled voice
- [ ] Have different person speak → % drops
- [ ] Below 55% shows "⚠️ Voice Mismatch"

### Test 4: Call Controls
- [ ] Mute button works
- [ ] Speaker button works
- [ ] End call works on both sides
- [ ] Call history updates

---

## 🎤 DEMO SCRIPT (3 Minutes)

```
[SLIDE: Problem - AI voice cloning is real]
"Imagine getting a call from your mom asking for money. 
It sounds exactly like her. But it's not."

[SHOW PHONE 1]
"VeriCall verifies callers cryptographically."

[TAP CALL ON PHONE 1]
"When I call Bob, my phone signs the request."

[SHOW PHONE 2 - INCOMING]
"Bob sees my device is verified BEFORE answering."

[ANSWER ON PHONE 2]
"But what if someone stole my phone? Voice verification."

[SPEAK INTO PHONE 1]
"As I speak, my voice is compared to my enrolled voiceprint."

[SHOW PHONE 2 - 94% MATCH]
"94% match - it's really me."

[DIFFERENT PERSON SPEAKS]
"Now watch if someone else speaks..."

[SHOW PHONE 2 - 31% MISMATCH ALERT]
"Immediately, Bob sees the warning."

Two layers: Device + Voice. VeriCall."
```

---

## 🐛 COMMON ISSUES

### WebSocket Won't Connect
- Check firewall settings
- Verify `wsBaseURL` in Constants.swift
- Try local IP instead of localhost

### Voice Match Always 0%
- Check microphone permissions
- Verify voice enrollment completed
- Check audio session is active

### Build Errors
- Clean build folder (Cmd+Shift+K)
- Update Swift packages
- Check deployment target (iOS 17+)

### Signature Verification Fails
- Verify keys generated in SecureEnclave
- Check base64 encoding matches
- Verify timestamp is recent

---

## 📊 MONITORING (Once Deployed)

```bash
# Check backend health
curl https://vericall-api.fly.dev/health

# View logs
fly logs --app vericall-api

# Monitor connections
fly status --app vericall-api
```

---

**You're ready! 🚀**

Questions? Check `/projects/vericall/TECH_SPEC.md` for full API docs.
