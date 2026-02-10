# VeriCall - Hybrid Architecture
## Cloud Verification + Local Voice

## 🎯 Final Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLOUD BACKEND                           │
│                      (Fly.io / AWS / etc)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ Auth API     │  │ Device Verify│  │ Call Signal  │          │
│  │ POST /auth   │  │ POST /verify │  │ WebSocket    │          │
│  │ - Phone/OTP  │  │ - Check sig  │  │ - Call start │          │
│  │ - Issue JWT  │  │ - Store keys │  │ - Call end   │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│  Database:                                                      │
│  ├─ users (id, phone, name)                                    │
│  ├─ devices (user_id, public_key, fingerprint)                 │
│  ├─ calls (caller, recipient, timestamps)                      │
│  └─ contacts (user_id, contact_phone, verified)                │
│                                                                 │
│  NO voice_embeddings table ❌                                   │
│  NO voice ML inference ❌                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ HTTPS + WebSocket
                              │
┌─────────────────────────────┴───────────────────────────────────┐
│                         iPHONE APP                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ENROLLMENT:                                                    │
│  ├─ Phone number → OTP (cloud)                                  │
│  ├─ Generate device keypair (SecureEnclave)                     │
│  ├─ Send public key to cloud (register device)                  │
│  └─ Record voice → extract signature (LOCAL)                    │
│      ├─ 192-dim spectral features                               │
│      ├─ Store in Keychain (NEVER goes to cloud)                 │
│      └─ Takes 2 seconds, ~500ms                                 │
│                                                                 │
│  DURING CALL:                                                   │
│  ├─ Caller signs call request (local)                           │
│  ├─ Send to cloud → cloud verifies signature                    │
│  ├─ Push notification to recipient                              │
│  ├─ Recipient sees "✓ Device Verified" (from cloud)             │
│  └─ ANSWER CALL                                                 │
│                                                                 │
│  VOICE VERIFICATION (LOCAL ONLY):                               │
│  ├─ Capture 3-second audio chunk                                │
│  ├─ Extract 192-dim signature (local)                           │
│  ├─ Compare to caller's stored signature (local)                │
│  ├─ Compute cosine similarity (local math)                      │
│  └─ Display "Voice Match: 89%"                                  │
│                                                                 │
│  Keychain Storage:                                              │
│  ├─ private_key (device)                                       │
│  ├─ voice_signature (192 floats)                               │
│  ├─ access_token (JWT)                                         │
│  └─ contacts (with their voice signatures)                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📊 What Goes Where

| Task | Location | Data Flow |
|------|----------|-----------|
| **Auth/OTP** | Cloud | Phone → Cloud → SMS → Phone |
| **Device registration** | Cloud | Public key → Cloud DB |
| **Device verification** | Cloud | Call request → Cloud verifies signature |
| **Call signaling** | Cloud | WebSocket through backend |
| **Voice enrollment** | **Local** | Record → Extract → Store in Keychain |
| **Voice verification** | **Local** | Capture → Extract → Compare locally |

---

## 🔐 Data Flow Examples

### Enrollment Flow
```
User opens app
    ↓
Enter phone → POST /auth/request-otp (cloud sends SMS)
    ↓
Enter OTP 123456 → POST /auth/verify-otp
    ↓
Generate device keypair (SecureEnclave)
    ↓
Send public_key to cloud (stored in DB)
    ↓
Record 5 voice phrases
    ↓
Extract 192-dim signature (LOCAL math)
    ↓
Store in Keychain (NEVER sent to cloud)
    ↓
Done! User enrolled
```

### Call Flow
```
Alice taps "Call Bob"
    ↓
Alice's phone signs call request with private key (local)
    ↓
POST /calls/initiate {recipient: Bob, signature: xyz} → Cloud
    ↓
Cloud verifies signature using Alice's stored public key
    ↓
Cloud sends push notification to Bob's phone
    ↓
Bob's phone shows: "Incoming from Alice - ✓ Device Verified"
    ↓
Bob answers
    ↓
DURING CALL:
    ├─ Alice speaks
    ├─ Bob's phone captures audio
    ├─ Bob's phone extracts signature (local)
    ├─ Bob's phone compares to Alice's stored signature (local)
    └─ Bob's screen shows: "Voice Match: 87%"
```

---

## 🗄️ Database Schema (Simplified)

```sql
-- Users
CREATE TABLE users (
    id UUID PRIMARY KEY,
    phone_number TEXT UNIQUE NOT NULL,
    name TEXT,
    created_at TIMESTAMP
);

-- Devices (public keys only)
CREATE TABLE devices (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    public_key TEXT NOT NULL,        -- ECDSA P-256 public key
    fingerprint TEXT UNIQUE,         -- SHA256 of public key
    device_name TEXT,
    created_at TIMESTAMP
);

-- Calls
CREATE TABLE calls (
    id UUID PRIMARY KEY,
    caller_id UUID REFERENCES users(id),
    recipient_id UUID REFERENCES users(id),
    device_verified BOOLEAN DEFAULT false,
    started_at TIMESTAMP,
    ended_at TIMESTAMP
);

-- Contacts
CREATE TABLE contacts (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    contact_phone TEXT NOT NULL,
    contact_name TEXT,
    verified BOOLEAN DEFAULT false
);

-- NO voiceprints table - stored locally on phones
```

---

## 🔧 API Endpoints (Final)

### Auth
```
POST /auth/request-otp
Body: { phone_number: "+15551234567" }

POST /auth/verify-otp
Body: { phone_number, code, public_key, device_name }
Response: { access_token, user_id, name }
```

### Users
```
GET /users/me
Headers: Authorization: Bearer {token}
Response: { id, phone, name }

PATCH /users/me
Body: { name: "New Name" }
```

### Contacts
```
POST /contacts/sync
Body: { phone_numbers: ["+15559876543", ...] }
Response: { contacts: [ { phone, name, user_id, verified }, ... ] }

GET /contacts
Response: { contacts: [...] }
```

### Calls
```
POST /calls/initiate
Body: { recipient_id, timestamp, nonce, signature }
Response: { call_id, verified: true }

POST /calls/answer
Body: { call_id }

POST /calls/end
Body: { call_id }
```

### NO Voice Endpoints ❌
- ~~POST /voice/enroll~~ (LOCAL)
- ~~POST /voice/verify~~ (LOCAL)
- ~~GET /voice/voiceprint/:id~~ (LOCAL)

---

## 📱 iOS Local Storage

### Keychain (Secure)
```swift
struct LocalStore {
    // My identity
    let myPrivateKey: SecKey           // Never leaves device
    let myPublicKey: SecKey
    let myVoiceSignature: [Float]      // 192-dim, local only
    
    // JWT for API calls
    let accessToken: String
    let refreshToken: String
}
```

### Contacts (UserDefaults/Keychain)
```swift
struct ContactWithVoice: Codable {
    let phoneNumber: String
    let name: String
    let publicKeyFingerprint: String
    let voiceSignature: [Float]        // Downloaded during contact sync
    let dateAdded: Date
}
```

---

## ✅ Final Checklist

### Cloud Backend Does:
- [x] Auth/OTP
- [x] Store user profiles
- [x] Store device public keys
- [x] Verify call signatures
- [x] Call signaling (WebSocket)
- [x] Push notifications

### Cloud Backend Does NOT:
- [ ] Store voice signatures ❌
- [ ] Run voice ML ❌
- [ ] Know anything about voice ❌

### iPhone Does:
- [x] Generate/store device keys
- [x] Sign call requests
- [x] Extract voice signatures (enrollment)
- [x] Store voice signatures (Keychain)
- [x] Compare voice signatures (during call)
- [x] Display match percentage

---

## 🎤 Demo Pitch

```
"VeriCall verifies callers with two layers:"

"First, device verification - cryptographic proof the call 
comes from their actual phone."
[Show device verified badge]

"Second, voice verification - happens entirely on your phone. 
Your voice signature never leaves your device."
[Show voice match percentage]

"Cloud handles the call setup, but verification is private."
```

---

## 💰 Costs

| Component | Cost |
|-----------|------|
| Fly.io (backend) | $0-5/month |
| PostgreSQL (Supabase free tier) | $0 |
| Push notifications (APN free) | $0 |
| Voice ML inference | **$0** (local) |
| **Total** | **~$5/month** |

---

## 🚀 Ready to Build?

This architecture:
- ✅ Uses cloud for auth/calls (as you wanted)
- ✅ Keeps voice local (privacy + speed)
- ✅ Device verification in cloud (can revoke compromised devices)
- ✅ Works at scale

Sound right?