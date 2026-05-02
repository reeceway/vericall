# Michael Cham Technical Stack Notes

As of April 10, 2026.

This is the exact stack as it exists in the current Vicall codebase, with a hard line between:
- what is shipping/live today
- what exists in the repo but is not the current live decision loop

## 1. Product In One Technical Sentence

Vicall is an iPhone VoIP app built around Twilio Voice + PushKit + CallKit, with on-device voice authenticity analysis running in parallel during live calls and local voiceprint enrollment stored in Keychain.

## 2. User-Facing Product Layers

There are really 4 product layers:

1. Identity and onboarding
- Company access code gate
- Phone OTP login
- Local user/auth persistence

2. Calling
- Twilio Voice SDK for client-to-client calling
- PushKit for background incoming wake
- CallKit for native incoming-call UI and answer/decline flow

3. Trust / authenticity
- On-device clone/spoof analysis during calls
- Local voiceprint enrollment + match support

4. Caller context
- Contacts lookup and local caller-name resolution
- App-level caller identity mapping

## 3. Client App Stack

Platform:
- iOS app
- Swift / SwiftUI
- iPhone-only App Store target right now

Bundle IDs:
- Debug/dev: `com.reeceway.vericall.dev`
- Release/App Store: `com.vicall.app`

Core iOS frameworks:
- `SwiftUI`
- `PushKit`
- `CallKit`
- `UserNotifications`
- `AVFoundation`
- `Contacts`
- `Security`
- `CoreML`
- `Accelerate`

Important app files:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/App/AppDelegate.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/App/AppDelegate.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/TwilioCallService.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/TwilioCallService.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/VoIPCallService.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/VoIPCallService.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/CallKitManager.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/CallKitManager.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/APIService.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/APIService.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/App/Constants.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/App/Constants.swift)

## 4. Calling Stack

### Media / transport

Current live call transport:
- Twilio Voice SDK
- Twilio client-to-client calling via TwiML App routing

Twilio responsibilities:
- invite delivery
- ringing
- connection setup
- voice media
- NAT traversal / TURN / jitter handling

App responsibilities:
- PushKit wake
- CallKit incoming call reporting
- identity selection
- UI state
- local analysis over tapped audio

### Incoming call wake path

Exact flow:

1. App launches and creates `PKPushRegistry` on the main queue.
2. App registers VoIP token.
3. App requests Twilio access token from the token service.
4. App registers with `TwilioVoiceSDK.register(...)`.
5. On incoming call, Twilio sends VoIP push.
6. `AppDelegate.pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` receives it.
7. That path synchronously reports the incoming call to CallKit.
8. Native Apple incoming call UI appears.
9. When user answers, the pending Twilio invite is accepted.
10. Audio connects and AI analysis starts in parallel.

Important note:
- This synchronous PushKit -> CallKit path was a major bugfix. It is now working.

### Current call UX reality

Background/locked ringing:
- Working

CallKit lock-screen UI:
- Native Apple call UI
- The custom spoof chip is not embedded in the lock-screen CallKit UI

In-call trust UI:
- Lives in the Vicall app
- Updates once the call is active and the app is open/in foreground

## 5. Backend / Service Stack

There are 2 distinct server planes:

### A. Main app backend

Base URL:
- `https://vericall-api.fly.dev`

Consumed from the iOS app for:
- `/auth/request-otp`
- `/auth/verify-otp`
- `/auth/refresh`
- `/users/me`
- `/contacts/sync`
- `/users/lookup`

What it appears to own:
- auth
- users
- contacts
- websocket signaling / app messaging
- app data

### B. Twilio voice control-plane service

Base URL:
- `https://vericall-twilio-voice.fly.dev`

Implementation:
- FastAPI
- Python

Main file:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/twilio_voice_service/app.py)

Responsibilities:
- Twilio access token minting
- push credential selection by environment + bundle id
- client-call routing / invite control
- device binding persistence
- access code validation endpoint
- privacy policy endpoint
- debug event logging

Important endpoints:
- `/calls/twilio-token`
- `/calls/device-binding`
- `/calls/client-notification` (custom fallback path, currently disabled)
- `/access/validate`
- `/debug/device-event`
- `/debug/bindings`
- `/privacy`

### Deployment

Primary hosting:
- Fly.io

Observed apps:
- main backend on `vericall-api.fly.dev`
- Twilio voice service on `vericall-twilio-voice.fly.dev`

## 6. Access / Onboarding Stack

Current onboarding order:

1. Welcome
2. Company access code
3. Phone number
4. OTP verification
5. Profile setup
6. Voice enrollment

Important current behavior:
- access code is validated before phone-number submission
- valid code is stored locally
- user should not need to re-enter the access code every app launch
- stale/invalid saved codes are cleared and force the user back to the code screen

Live access-code validation:
- server-side at `/access/validate`
- server stores allowed hashes
- validation is rate limited

## 7. On-Device ML Stack

This is the most important architecture distinction in the whole meeting:

### Shipping live call detector today

The current live call loop uses:
- `VeriCallClassicSpoof`
- classic feature extraction
- XGBoost exported to Core ML

Source:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/ClassicSpoofDetector.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Models/ClassicSpoofDetector.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/AIAnalysisService.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/AIAnalysisService.swift)

Exact live spoof pipeline:
- 3-second mono PCM
- 16 kHz target analysis rate
- power spectrum with:
  - `n_fft = 512`
  - `hop = 160`
  - `win = 400`
- 40 linear filterbank energies
- 20 LFCC coefficients
- delta + delta-delta
- mean / std / p10 / p90 stats
- 240-dim feature vector
- XGBoost model exported to Core ML

This is the actual production decision loop right now.

### Neural path that exists in repo

There is also a neural path:
- `VoiceEmbedder`
- `VeriCallSpoofHead`

Source:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/EmbedderWrapper.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Models/EmbedderWrapper.swift)
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/SpoofDetector.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Models/SpoofDetector.swift)

Exact neural path:
- 3-second audio window
- 80-band log-Mel fbank
- `[1, 300, 80]` tensor
- `VoiceEmbedder` outputs 192-dim embedding
- `VeriCallSpoofHead` maps embedding -> spoof logit -> clone probability

Important nuance:
- this neural path exists
- it is not the current live production call verdict loop
- the live call path currently drives off the classic spoof model

### Speaker / voiceprint path

Speaker embedding model:
- ECAPA-TDNN style 192-dim embedder

Model metadata:
- `voice-embedder-stage1-epoch1-best-20260401`

Voiceprint storage:
- local only
- iOS Keychain
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

Enrollment flow:
- user records roughly 5–10 seconds
- app breaks into 3-second windows
- computes per-window embeddings
- averages them
- stores a single 192-dim voice signature locally

Source:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/VoiceEnrollmentService.swift](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/ios/VeriCall/Services/VoiceEnrollmentService.swift)

## 8. Model Sizes / Runtime Targets

Observed model sizes:
- `VoiceEmbedder.mlmodelc`: about `40 MB`
- `VeriCallClassicSpoof.mlmodel`: about `406 KB`
- `VeriCallSpoofHead.mlmodel`: about `130 KB`
- `VeriCallSpoofDetector.mlpackage`: about `181 MB`

Core ML compute units:
- `cpuAndNeuralEngine`

That is explicitly configured in both:
- embedder wrapper
- spoof detector
- classic spoof detector

### Precision

Observed in `VoiceEmbedder` metadata:
- Core ML ML Program
- mixed precision
- Float16 storage
- converted with `coremltools`
- source dialect: TorchScript

## 9. Runtime Decision Logic

Current analysis window:
- 3 seconds

Analysis cadence:
- every 0.5 seconds

Current live spoof thresholds:
- `spoofHumanThresholdCall = 0.90`
- `spoofUncertaintyMarginCall = 0.05`
- `spoofExtremeFakeThresholdCall = 0.98`
- `spoofWarmupWindowsCall = 4`
- `spoofHistoryWindowsCall = 5`
- `spoofAudibleRMSCall = 0.003`

Speaker threshold:
- `speakerMatchThresholdCall = 0.90`

Important nuance:
- offline calibration artifacts still show a spoof best threshold of `0.4`
- the shipping UI/call loop uses a much stricter call-time thresholding + smoothing policy to reduce false positives in real calls

## 10. What The Benchmarks Actually Say

Accessible benchmark file:
- [/Users/reeceway/Desktop/vericall voiceprints/vericall/voice-ml/benchmark_100/benchmark_100_results.json](/Users/reeceway/Desktop/vericall%20voiceprints/vericall/voice-ml/benchmark_100/benchmark_100_results.json)

Summary:
- `num_speakers = 100`
- `genuine/impostor/fake pairs = 100 each`

Spoof benchmark best result:
- threshold `0.4`
- `fake_detect = 0.74`
- `real_accept = 0.86`
- balanced `0.80`

Speaker benchmark best result:
- threshold `0.75`
- genuine accept `1.00`
- impostor reject `0.105`
- balanced `0.535`

What this means in plain English:
- spoof detection is currently the stronger technical story
- speaker verification exists, but is not where the strongest benchmark story is today

## 11. Audio / Latency Reality

Do not blur together:

### Raw model compute latency

The embedder wrapper logs direct inference time in milliseconds:
- `print("[EmbedderWrapper] inference ... ms")`

### User-visible verdict latency

This is longer than raw model compute because it includes:
- 3-second windows
- rolling history
- warmup windows
- audible-signal confidence gating

So if someone asks “where does 300 ms come from?”:
- that is not the full live decision latency story
- the safe answer is:
  - raw model compute is sub-second on-device
  - user-visible trust verdict depends on windowing and smoothing, so it is measured over several seconds of usable speech

## 12. Security / Data Boundary Story

Safe, accurate claim:

"The voiceprint and clone/spoof inference run on-device. Enrollment stays in local Keychain. The call itself still travels over Twilio’s voice infrastructure."

What stays local:
- enrolled voice embedding
- live spoof inference
- contact-name resolution

What leaves the device:
- call media over Twilio
- auth / OTP requests
- access-code validation
- call routing metadata
- push registration / device binding metadata

## 13. Caller ID / Spoofing Claim

Be careful here.

What is implemented and verified:
- local Contacts lookup
- app identity mapping
- incoming call display-name resolution for Twilio identities / phone numbers

What I would not claim as implemented without qualification:
- carrier-grade STIR/SHAKEN verification
- privileged OS telephony attestation
- baseband-level spoof detection

Safe wording:
- "We combine caller context, contacts identity, and live voice authenticity analysis inside the app."

## 14. Current Production / Distribution Stack

Calling:
- Twilio Voice SDK
- PushKit
- CallKit

App distribution:
- App Store / TestFlight target bundle `com.vicall.app`
- iPhone-only target

Private access:
- company access code required
- code validated server-side

App Store / review support:
- privacy policy served from `vericall-twilio-voice.fly.dev/privacy`
- real App Store screenshots generated from simulator app UI

## 15. Exact Honest Positioning For The Meeting

If he asks "What is the stack?":

"On the client, it’s a SwiftUI iPhone app using PushKit, CallKit, Twilio Voice SDK, Core ML, and Keychain. On the backend, we split auth/app state and Twilio voice control into separate Fly services. For trust, the current live call loop uses a lightweight on-device classic spoof detector over 3-second speech windows, and we also have a neural ECAPA-based embedder path on-device for voiceprint and future deeper spoof modeling."

If he asks "What is shipping versus roadmap?":

"Shipping today is Twilio calling plus on-device classic spoof detection in the live loop. The ECAPA embedder and neural spoof-head path are in the codebase, but they’re not the current primary live call verdict path."

If he asks "What is your strongest technical asset right now?":

"Reliable background VoIP wake/ring on iPhone, plus a real on-device authenticity loop running during calls instead of a cloud-only demo."

## 16. Things Not To Overclaim

Do not say:
- "The product is powered by WavLM in production" unless you explicitly say that is part of the broader model strategy rather than the current live call loop.
- "All call data never leaves the device."
- "We have carrier-level caller ID spoof attestation."
- "Speaker verification is already best-in-class."

## 17. Best Short Version

Vicall today is:
- iPhone VoIP app
- Twilio Voice + PushKit + CallKit
- on-device spoof/clone detection during calls
- local ECAPA-style voiceprint enrollment in Keychain
- company-code gated onboarding
- Fly-hosted auth + Twilio token/control services

The strongest honest technical story is:
- reliable mobile call stack
- real background wake/ring
- real on-device inference
- practical consumer trust UX
