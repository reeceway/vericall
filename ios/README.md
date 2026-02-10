# VeriCall iOS App

Cryptographically verified calling with voice authentication.

## Agent #2 Deliverables (COMPLETE - API Contract Updated)

### EXACT API Contract Implementation

All API calls follow the exact specifications from TECH_SPEC.md:

#### Constants (EXACT - DO NOT MODIFY)
```swift
static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
static let wsBaseURL = "wss://vericall-api.fly.dev"
static let voiceSampleRate: Double = 16000
static let voiceEmbeddingDimension = 192
static let voiceMatchThreshold: Float = 0.75
static let voiceWarningThreshold: Float = 0.55
static let signatureAlgorithm = "ECDSA-P256-SHA256"
```

#### Authentication Flow

**1. Request OTP**
```
POST /api/v1/auth/request-otp
Request: { "phoneNumber": "+15550001234" }
Response: { "success": true, "expiresIn": 300 }
```
- Implemented in: `PhoneInputView.swift`

**2. Verify OTP**
```
POST /api/v1/auth/verify-otp
Request: {
    "phoneNumber": "+15550001234",
    "code": "123456",
    "publicKey": "base64-encoded-p256-public-key",
    "deviceId": "uuid",
    "deviceName": "iPhone 15 Pro"
}
Response: {
    "success": true,
    "accessToken": "jwt-token",
    "refreshToken": "refresh-token",
    "user": { "id", "phoneNumber", "displayName", "voiceEnrolled" }
}
```
- Implemented in: `VerificationCodeView.swift`
- Generates P-256 key pair in Secure Enclave
- Stores: accessToken, refreshToken, userId in Keychain

**3. Voice Enrollment**
```
POST /api/v1/voice/enroll
Headers: Authorization: Bearer {accessToken}
Request: {
    "embedding": [0.123, -0.456, ...], // 192 floats
    "sampleCount": 3
}
Response: { "success": true, "quality": 0.92 }
```
- Implemented in: `VoiceEnrollmentView.swift`

### Onboarding Flow

The onboarding flow consists of 4 screens:

1. **WelcomeView** - App introduction with animated logo
2. **PhoneInputView** - Phone entry with country code picker → calls `request-otp`
3. **VerificationCodeView** - 6-digit SMS code entry → calls `verify-otp` with P-256 publicKey
4. **VoiceEnrollmentView** - Records 3 voice samples → calls `enroll` with 192-dim embedding

### Key Services

#### DeviceCryptoService
- Generates P-256 EC key pairs using Secure Enclave (or Keychain on simulator)
- Exports public keys in base64 format (as required by API)
- Signs data using ECDSA-P256-SHA256
- Creates call signatures with nonce/timestamp

#### APIService
- Handles all backend communication per exact API contract
- JWT token management (accessToken/refreshToken)
- Auto-refresh on 401 responses
- Mock mode enabled by default (`useMockData = true`)

Endpoints implemented:
- `POST /auth/request-otp`
- `POST /auth/verify-otp`
- `POST /auth/refresh`
- `GET /users/me`
- `PATCH /users/me`
- `POST /contacts/sync`
- `POST /voice/enroll`
- `GET /voice/voiceprint/{userId}`
- `POST /calls/initiate`
- `POST /calls/answer`
- `POST /calls/end`

#### KeychainService
- Secure storage for sensitive data
- Stores: accessToken, refreshToken, device keys, userId
- Uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

#### AudioRecorder
- AVAudioRecorder wrapper for voice capture
- 16kHz sample rate (as per API spec)
- AAC format
- Real-time audio level monitoring

### Configuration

Edit `Constants.swift` to configure:
```swift
static let apiBaseURL = "https://vericall-api.fly.dev/api/v1"
```

To disable mock mode, set in `APIService.swift`:
```swift
private let useMockData = false
```

### Mock Mode
When `useMockData = true`:
- Verification code is always `123456`
- Tokens are mock JWTs
- Voice embeddings are randomly generated (192 dimensions)
- Useful for development before backend is ready

### Integration Points for Agent #3 (Calling Flow)

Placeholder views provided:
- **ContactListView** - Shows contacts with verification badges
- **IncomingCallView** - Shows incoming call with device verification status
- **ActiveCallView** - Shows voice match percentage during call

Update `MainTabView` in `RootView.swift` with actual implementations.

### Push Notifications
The app registers for push notifications automatically after voice enrollment:
- `AppDelegate` handles token registration
- Token is stored in UserDefaults
- Sent to backend during `verify-otp` (deviceId)

## Building the Project

1. Open project folder in Xcode 15+
2. Create new project or add files to existing project
3. Set development team in Signing & Capabilities
4. Enable Push Notifications capability
5. Enable Background Modes: Remote Notifications, VoIP, Audio
6. Build and run on iOS 16+ device or simulator

## Security Notes

- Private keys never leave the Secure Enclave
- Access tokens stored in Keychain
- Voice samples recorded at 16kHz as per spec
- All API calls use HTTPS
- ECDSA-P256-SHA256 signatures for call authentication

## File Structure
```
VeriCall/
├── App/
│   ├── VeriCallApp.swift
│   ├── RootView.swift
│   └── Constants.swift
├── Views/
│   ├── Onboarding/
│   │   ├── OnboardingContainerView.swift
│   │   ├── WelcomeView.swift
│   │   ├── PhoneInputView.swift
│   │   ├── VerificationCodeView.swift
│   │   └── VoiceEnrollmentView.swift
│   ├── Contacts/
│   │   └── ContactListView.swift
│   └── Calling/
│       ├── IncomingCallView.swift
│       └── ActiveCallView.swift
├── Services/
│   ├── DeviceCrypto.swift
│   ├── APIService.swift
│   ├── KeychainService.swift
│   └── AudioRecorder.swift
├── Models/
│   ├── User.swift
│   ├── Call.swift
│   └── VoiceMatch.swift
└── Utils/
    └── Data+Extension.swift
```

## Next Steps

1. Agent #1: Backend API implementation (must match exact contract)
2. Agent #3: CallKit + WebRTC integration
3. Agent #4: Voice ML integration (generate 192-dim embeddings)
4. Integration testing between all components
