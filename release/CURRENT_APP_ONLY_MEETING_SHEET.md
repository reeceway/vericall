# Vicall Current App Only Meeting Sheet

As of April 10, 2026.

This sheet is intentionally strict:
- only describe what exists in the app you are using now
- do not describe repo-only, future, or sidecar ML paths as if they are live

## 1. What Vicall Is

Vicall is an iPhone VoIP calling app that uses Twilio Voice for call transport, PushKit + CallKit for real incoming-call behavior, and on-device synthetic-voice detection during live calls.

## 2. What The User Actually Experiences Today

1. User opens the app and enters a company access code on first install.
2. User logs in with phone OTP.
3. User can place and receive Vicall calls.
4. Incoming calls ring through native Apple CallKit, including when the app is backgrounded or the phone is locked.
5. Once the call is active, the Vicall app shows live trust status for the remote speaker:
- `Human Voice`
- `Voice Not Confirmed`
- `Synthetic Voice Alert`
6. If the app becomes confident the remote voice is synthetic, it can trigger a stronger alert/buzz pattern.
7. If the app hears audio but still cannot confirm the voice, it can trigger a lighter caution alert.

## 3. Calling Stack In The Current App

Transport and call setup:
- Twilio Voice iOS SDK
- Twilio client-to-client calling

iPhone call behavior:
- PushKit for VoIP wake
- CallKit for native incoming-call screen
- native answer / decline flow

Current reality:
- background and locked-screen incoming ringing is working
- the lock-screen incoming UI is the native Apple CallKit UI
- the custom Vicall trust chip lives inside the app during the active call, not inside the Apple lock-screen call UI

## 4. Backend Stack In The Current App

The current app depends on 2 server planes.

### Main app backend

Base URL:
- `https://vericall-api.fly.dev`

What the current app calls it for:
- `POST /auth/request-otp`
- `POST /auth/verify-otp`
- `POST /auth/refresh`
- `PATCH /users/me`
- `POST /contacts/sync`
- `POST /users/lookup`

What it owns in the current product:
- phone OTP authentication
- access token / refresh token auth flow
- user profile updates
- contact sync for identifying known Vicall users
- user lookup by phone number

### Twilio voice service

Base URL:
- `https://vericall-twilio-voice.fly.dev`

Implementation:
- FastAPI on Fly.io

What the current app calls it for:
- `POST /calls/twilio-token`
- `POST /calls/device-binding`
- `POST /access/validate`

What it owns in the current product:
- Twilio access token minting
- choosing the correct Twilio Push Credential based on push environment and bundle ID
- saving device VoIP token bindings by identity
- validating company access codes
- device debug event logging
- privacy-policy hosting

Important current backend truth:
- Twilio Verify / OTP is part of the live login flow
- the Twilio account is a full account, not a trial account
- end users do not need to be manually preconfigured one-by-one in Twilio

## 5. Current ML Stack In The App

The live app currently uses the classic spoof detector only.

Current production analysis loop:
- remote audio only
- rolling 3-second windows
- 16 kHz target analysis rate
- mono PCM analysis
- classic speech features:
  - 40 filterbank energies
  - 20 LFCC coefficients
  - delta and delta-delta features
- summary statistics
- 240-dimensional feature vector
- XGBoost model exported to Core ML

Exact current technical shape:
- analysis loop runs every `0.5s`
- each decision window uses `3.0s` of audio
- target sample rate is `16 kHz`
- remote Twilio audio arrives at `48 kHz` and is analyzed on the 3-second rolling window
- Core ML compute target is `CPU + Neural Engine`

Important truth:
- this is the shipping detector path in the app you are using right now
- do not describe the current app as being powered by WavLM, Whisper, or a large transformer-based detector

### Why the current app uses this ML path

This is the right honest explanation:
- the product problem is not "use the fanciest model"
- the product problem is "catch sophisticated synthetic audio inside a live iPhone call with as little latency, battery cost, and infrastructure dependency as possible"
- the current classic Core ML spoof detector is the most computationally efficient path we have running reliably in the live app today
- it is small enough, fast enough, and stable enough to run continuously during real calls on-device
- it avoids cloud inference for the detection decision

Good founder wording:
- "We optimized for the most computationally effective way to catch sophisticated synthetic audio during a live call, not for the largest or trendiest model."

Do not say:
- "classic features are inherently better than neural models"
- "we proved this is globally the best detector architecture"

## 6. Current Detection Behavior

The live call detector is intentionally smoothed:
- analysis runs on rolling windows
- verdicts warm up over multiple windows
- the app tries to hold onto stable human results through short pauses
- it treats audible-but-unconfirmed audio differently from silence

Current verdict language in the app:
- `Human Voice`
- `Voice Not Confirmed`
- `Synthetic Voice Alert`

Important current runtime thresholds:
- human threshold: `0.90`
- uncertainty margin: `0.05`
- extreme fake threshold: `0.98`
- warmup windows before stable verdicts: `4`
- history windows used for smoothing: `5`
- audible RMS threshold used by the caution path: `0.003`

This is the strongest honest product claim:
- Vicall performs on-device synthetic-voice detection during a live iPhone call

## 7. Onboarding / Access In The Current App

Current flow:
1. Welcome
2. Company access code
3. Phone number
4. OTP verification
5. Profile setup

Important current behavior:
- access code is required on first install
- access code is validated before continuing into login
- once validated, the code is stored locally so the user does not need to re-enter it every time the app opens
- stale invalid saved codes are cleared and the user is forced back to the access-code screen

## 8. Data / Privacy Claims We Can Safely Make

Safe version:
- the synthetic-voice analysis runs on-device
- locally stored onboarding/access state is kept on-device

Be careful:
- the call itself still rides Twilio Voice infrastructure
- do not say the entire call path never leaves the device
- do not say Vicall has carrier-level or telecom-network-level attestation

## 9. Caller Identity / Contacts

Current app behavior:
- app-level caller identities are mapped to phone-style identities
- the app can resolve local contacts for friendlier caller naming
- incoming call naming can reflect Vicall branding plus a resolved contact name when available

Safe wording:
- "we enrich the call experience with local contact context"

Do not say:
- "we integrate directly with carrier caller ID systems"

## 10. What Not To Talk About As If It Is Live

Do not present these as current-app facts:
- WavLM as the shipping detector
- transformer-first spoof detection as the live decision loop
- speaker verification as the core current product story
- cloud-based clone scoring
- carrier-layer spoof detection
- fully local call transport

## 11. Best Honest Technical Pitch

"The app in use today is an iPhone VoIP calling app built on Twilio Voice, PushKit, and CallKit. It reliably rings in the background, connects the call through native iPhone call UX, and runs an on-device synthetic-voice detector over the remote call audio in real time. The live shipping detector is a lightweight Core ML spoof model built from classic speech features, not a cloud model and not a large transformer running in production."

## 12. Best Honest Short Pitch

"Vicall is a working iPhone calling app that rings like a normal phone call and performs on-device synthetic-voice detection during the call."
