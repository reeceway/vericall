# VeriCall P2P - Zero Backend Architecture

## 🎯 Vision
No cloud. No servers. No databases. Just two phones verifying each other directly.

## 🏗️ P2P Architecture

```
Phone A (Alice)                           Phone B (Bob)
├─ Generates device keypair               ├─ Generates device keypair
├─ Records voice signature                ├─ Records voice signature
├─ Stores in Keychain                     ├─ Stores in Keychain
│                                         │
│  1. PAIRING (QR Code Exchange)          │
│  ┌─────────────────────────────┐        │
│  │ Alice shows QR:             │        │
│  │ - Public key                │        │
│  │ - Phone number              │        │
│  │ - Name                      │        │
│  └──────────▲──────────────────┘        │
│             │                           │
│             │  Bob scans                │
│             │                           │
│  ┌──────────┴──────────────────┐        │
│  │ Bob shows QR:               │        │
│  │ - Public key                │────────┼─► Both store contact
│  │ - Phone number              │        │   with each other's keys
│  │ - Name                      │        │
│  └─────────────────────────────┘        │
│                                         │
│  2. CALLING (Direct P2P)                │
│  ┌─────────────────────────────┐        │
│  │ Alice calls Bob             │        │
│  │ ├─ Creates call payload     │        │
│  │ ├─ Signs with private key   │        │
│  │ ├─ Sends via local network  │────────┼─► Bob receives
│  │ └─ OR via Push Notification │        │
│  └─────────────────────────────┘        │
│                                         │
│  3. VERIFICATION (Local)                │
│  Bob verifies:                          │
│  ├─ Signature valid? (using stored key) │
│  ├─ Timestamp recent?                   │
│  ├─ Shows "✓ Device Verified"           │
│  └─ Answers call                        │
│                                         │
│  4. VOICE MATCH (Local)                 │
│  During call:                           │
│  ├─ Alice speaks                        │
│  ├─ Bob captures audio                  │
│  ├─ Compares to stored voice signature  │
│  └─ Shows "Voice Match: 89%"            │
```

---

## 📱 Data Storage (Local Only)

### Keychain (Secure)
```swift
struct MyIdentity {
    let privateKey: SecKey           // Device private key (never leaves)
    let publicKey: SecKey            // Device public key
    let publicKeyData: Data          // For sharing
    let phoneNumber: String
    let name: String
    let voiceSignature: [Float]      // 192-dim voice print
}
```

### UserDefaults (Contacts)
```swift
struct Contact: Codable {
    let phoneNumber: String
    let name: String
    let publicKeyData: Data          // Their public key
    let publicKeyFingerprint: String // For display
    let voiceSignature: [Float]?     // Their voice print (if shared)
    let dateAdded: Date
}
```

---

## 🔐 Pairing Flow (QR Code Exchange)

```swift
// PairingView.swift
struct PairingView: View {
    @State private var showQR = false
    @State private var showScanner = false
    
    var body: some View {
        VStack {
            Button("Show My QR Code") {
                showQR = true
            }
            
            Button("Scan Contact's QR") {
                showScanner = true
            }
        }
    }
}

// QR Code contains:
struct QRPayload: Codable {
    let publicKey: String        // Base64 encoded
    let phoneNumber: String
    let name: String
    let timestamp: Int           // Prevent replay attacks
    let signature: String        // Sign QR payload with private key
}
```

**Security:**
- QR is signed by sender's private key
- Receiver verifies signature before storing
- Timestamp prevents old QR codes from being reused

---

## 📞 Calling Flow (Direct P2P)

### Option A: Local Network (Same WiFi)

```swift
// LocalNetworkCallManager.swift
import Network

class P2PCallManager {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    
    // Advertise service via Bonjour/mDNS
    func startAdvertising() {
        listener = try? NWListener(using: .tcp)
        listener?.service = NWEndpoint.Service(
            name: myPhoneNumber,
            type: "_vericall._tcp"
        )
        listener?.start(queue: .main)
    }
    
    // Browse for contacts on local network
    func browseForContact(_ phoneNumber: String) {
        let browser = NWBrowser(
            for: .bonjour(type: "_vericall._tcp", domain: nil),
            using: .tcp
        )
        browser.start(queue: .main)
    }
    
    // Send call request directly
    func initiateCall(to contact: Contact) {
        // 1. Create signed call payload
        let payload = CallPayload(
            callId: UUID().uuidString,
            callerPhone: myPhoneNumber,
            callerName: myName,
            timestamp: Int(Date().timeIntervalSince1970),
            nonce: UUID().uuidString
        )
        let signature = sign(payload, with: myPrivateKey)
        
        // 2. Send via local network connection
        let message = EncryptedCallRequest(
            payload: payload,
            signature: signature,
            encryptedFor: contact.publicKey  // Encrypt so only they can read
        )
        
        connection?.send(message)
    }
}
```

### Option B: Apple PushKit (Any Network)

```swift
// PushKitCallManager.swift
import PushKit

// Uses Apple's PushKit for VoIP notifications
// No backend needed - Apple delivers pushes directly

// Caller sends push via Apple's APNS
// Recipient receives push, shows CallKit UI
// Both connect via WebRTC (STUN/TURN servers only, no app backend)
```

---

## ✅ Verification (100% Local)

```swift
// IncomingCallHandler.swift
func handleIncomingCall(_ request: CallRequest, from contact: Contact) {
    // 1. Verify signature
    let isValid = verifySignature(
        request.signature,
        payload: request.payload,
        publicKey: contact.publicKey
    )
    
    guard isValid else {
        showAlert("Invalid call signature - possible spoofing")
        return
    }
    
    // 2. Check timestamp (prevent replay)
    let age = Date().timeIntervalSince1970 - Double(request.payload.timestamp)
    guard age < 30 else {
        showAlert("Call request expired")
        return
    }
    
    // 3. Show CallKit UI with verification badge
    let callUpdate = CXCallUpdate()
    callUpdate.localizedCallerName = "✓ \(contact.name)"
    callUpdate.hasVideo = false
    
    callProvider.reportNewIncomingCall(with: request.payload.callId, update: callUpdate)
}
```

---

## 🎤 Voice Verification (Local)

Already described in LOCAL_VOICE.md - extracts 192 features locally, compares to stored contact's voice signature.

```swift
// During call
func processIncomingAudio(_ buffer: AVAudioPCMBuffer, from contact: Contact) {
    guard let storedVoice = contact.voiceSignature else { return }
    
    let liveSignature = extractSpectralFeatures(buffer)
    let similarity = cosineSimilarity(liveSignature, storedVoice)
    
    DispatchQueue.main.async {
        self.voiceMatchPercentage = Int(similarity * 100)
        self.verificationStatus = similarity > 0.75 ? .verified : .mismatch
    }
}
```

---

## 🔧 What We ELIMINATE

| Component | Before | After (P2P) |
|-----------|--------|-------------|
| Backend server | Fly.io | **None** ✅ |
| Database | PostgreSQL | **Local only** ✅ |
| Redis | Upstash | **None** ✅ |
| WebSocket server | Custom | **mDNS/Local** ✅ |
| OTP service | Twilio | **QR pairing** ✅ |
| ML inference | Cloud | **Local** ✅ |
| Monthly cost | ~$20-50 | **$0** ✅ |

---

## ⚠️ Limitations

1. **Contact Discovery**: Must pair in person (scan QR) - no "find user by phone number"
2. **Network**: Works best on same WiFi (low latency)
3. **Push notifications**: May need Apple Developer account for PushKit
4. **Offline**: Works 100% offline after initial pairing
5. **Backup**: No cloud backup - lose phone = lose contacts

---

## 🎯 Perfect for Hackathon

**Pros:**
- ✅ ZERO infrastructure costs
- ✅ Works offline
- ✅ Maximum privacy
- ✅ Fast (local network)
- ✅ Impressive tech demo

**Cons:**
- Must pair devices in person
- No global user discovery
- Lose phone = lose everything

---

## 📋 Implementation Plan

### Phase 1: Identity & Keys (2 hours)
- [ ] Generate device keypair in SecureEnclave
- [ ] Store in Keychain
- [ ] Display QR code with public key

### Phase 2: Pairing (2 hours)
- [ ] QR code scanner
- [ ] Verify QR signature
- [ ] Store contact locally
- [ ] Exchange voice signatures

### Phase 3: Calling (3 hours)
- [ ] mDNS/Bonjour service advertising
- [ ] Browse for contacts
- [ ] Send signed call requests
- [ ] CallKit integration

### Phase 4: Voice (2 hours)
- [ ] Local feature extraction
- [ ] Compare to stored signature
- [ ] Real-time match display

**Total: 9 hours** (doable in one night)

---

## 🚀 Let's Build It?

This is actually a cleaner, cooler demo:
- "No servers, no cloud, no databases"
- "Pure peer-to-peer verification"
- "Your keys, your voice, your phone"

Want me to rewrite everything for P2P?