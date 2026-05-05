# Vicall AI Audio / Spoof Detection Senior Dev Context

Last updated: 2026-05-04

This file is a senior-engineer handoff for the Vicall iOS live-call AI path, the current spoof model contract, the training/calibration/harness assets in this repo, and the specific bug under investigation: different iPhones are producing different human/synthetic verdict behavior on the same real caller.

No secrets, OTPs, production keys, Stripe keys, Twilio auth tokens, or portal passwords are included here.

## Current Situation

The product target is:

- Real human speech should go green within the first few seconds of a call.
- Synthetic / voice clone / replay should flag within the first few seconds when speech is present.
- Silence should not downgrade a good call and should not create a synthetic warning by itself.
- Once a call has gone green for a real human, keep the UI green for a low-friction phone experience.
- Yellow means likely synthetic / do not trust.
- Red means highly likely or definitely synthetic.
- Notification + buzz need to work when the SwiftUI call UI is closed and the user is in CallKit.

Most recent observed behavior:

- After equalizing the device cadence, Reece tested the first two direction tests with the same real human speaker.
- Old phone was correct.
- New phone was wrong.
- That means the next likely issue is not "the model is different per device"; it is probably that the phones are scoring different mirrored streams, different source audio quality, or different remote/local track timing.

Known paired devices used in testing:

- Newer phone: "Reece's Phone" / iPhone 15
  - devicectl identifier: `D2C94512-1168-5A20-8E62-5A9EA82C8897`
  - xcodebuild hardware id: `00008120-0006681A3401A01E`
- Older phone: "iPhone (3)" / iPhone 13
  - devicectl identifier: `C74CF6F4-46A0-5821-8D07-E269C42120BE`
  - xcodebuild hardware id: `00008110-001129AA0A8B801E`

## Repo / Workspace

Current working repo in this session:

```sh
cd /Users/reeceway/vicall-build-working
```

Canonical Vicall repo path used in older runbooks/skills:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
```

Check which one is active before editing:

```sh
pwd
git status --short
git remote -v
```

Current dirty files at the time this context file was written:

```text
ios/VeriCall/App/PerformanceProfile.swift
ios/VeriCall/Models/VoiceModels.swift
ios/VeriCall/Services/AIAnalysisService.swift
ios/VeriCall/Services/CallTransportService.swift
ios/VeriCall/Services/VoIPCallService.swift
```

## Live Product Audio Path

The live AI path is not direct microphone capture.

Current production path:

```text
Twilio Voice call
  -> backend Twilio Media Stream mirror
  -> backend expands 8 kHz mu-law to 16 kHz PCM16
  -> iOS app polls audio mirror endpoint
  -> TwilioCallService decodes PCM16 to Float32
  -> remote/local rolling buffers
  -> CallTransportService snapshots buffers
  -> AIAnalysisService analyzes 3s / 16 kHz windows
  -> ClassicSpoofDetector predicts clone probability
  -> VoIPCallService maps model output to green/yellow/red + notifications + CallKit display
```

Important files:

```text
twilio_voice_service/app.py
ios/VeriCall/Services/APIService.swift
ios/VeriCall/Services/TwilioCallService.swift
ios/VeriCall/Services/CallTransportService.swift
ios/VeriCall/Services/AIAnalysisService.swift
ios/VeriCall/Models/ClassicSpoofDetector.swift
ios/VeriCall/Models/VoiceModels.swift
ios/VeriCall/Services/VoIPCallService.swift
ios/VeriCall/Services/NotificationService.swift
ios/VeriCall/Services/CallKitManager.swift
ios/VeriCall/App/PerformanceProfile.swift
ios/VeriCall/Views/Calling/VoIPActiveCallView.swift
```

## Backend Media Mirror

Backend file:

```text
twilio_voice_service/app.py
```

Key backend constants/functions:

```text
MEDIA_MIRROR_SAMPLE_RATE = 16_000
media_mirror_start_twiml()
media_mirror_stream_side()
mulaw_8k_to_pcm16le_16k()
media_mirror_append_pcm()
media_mirror_latest_audio()
GET /twilio/ai-audio/latest
```

Current backend track mapping:

```python
def media_mirror_stream_side(track: str | None) -> str:
    normalized = (track or "").strip().lower()
    if normalized in {"inbound", "inbound_track"}:
        return "local"
    if normalized in {"outbound", "outbound_track"}:
        return "remote"
    return "remote"
```

The TwiML stream is configured with:

```xml
<Stream track="both_tracks">
```

The backend returns:

```json
{
  "sample_rate": 16000,
  "remote_cursor": 0,
  "local_cursor": 0,
  "remote_pcm16_base64": "...",
  "local_pcm16_base64": "...",
  "remote_samples": 0,
  "local_samples": 0,
  "active": true
}
```

## iOS Audio Mirror Polling

File:

```text
ios/VeriCall/Services/TwilioCallService.swift
```

Important methods:

```text
startMirroredAudioPolling(sessionKey:mirrorToken:appAccessToken:)
startMirroredAudioPollingForCurrentCallContext(appAccessToken:)
startMirroredAudioPollingForPendingInvite(appAccessToken:)
decodePCM16Base64()
appendSamples(_:source:)
```

The app fetches the mirror through:

```text
ios/VeriCall/Services/APIService.swift
fetchTwilioAIAudioMirror(...)
```

The model buffers are:

```text
TwilioCallService.remoteAudioBuffer
TwilioCallService.localAudioBuffer
```

Both are Float32, mono, 16 kHz, rolling up to 10 seconds.

## Model Contract

Do not casually change this contract.

File:

```text
ios/VeriCall/Models/VoiceModels.swift
```

Current live spoof input:

```text
sampleRate = 16_000
analysisWindowSeconds = 3.0
analysisWindowSamples = 48_000
```

Current live model:

```text
ios/VeriCall/Models/VeriCallClassicSpoof.mlmodel
ios/VeriCall/Models/ClassicSpoofDetector.swift
```

The live product verdict path currently uses the classic spoof detector, not WavLM, Whisper, or the neural spoof head.

Classic detector feature pipeline from `ClassicSpoofDetector.swift`:

```text
3-second mono PCM at 16 kHz
power spectrum
n_fft = 512
hop = 160
win = 400
40 linear filterbank energies
20 LFCC coefficients
delta + delta-delta
mean / std / p10 / p90 stats
240-dimensional feature vector
XGBoost model exported to Core ML
```

The Core ML export has a fixed positive margin bias removed in Swift:

```swift
private let coreMLMarginBias: Double = 0.5196850381
let calibratedMargin = raw - coreMLMarginBias
let prob = 1.0 / (1.0 + exp(-calibratedMargin))
```

Thresholds currently in `VoiceModels.swift`:

```text
spoofHumanThresholdCall = 0.90
spoofUncertaintyMarginCall = 0.05
spoofSyntheticCandidateThresholdCall = 0.95
spoofExtremeFakeThresholdCall = 0.98
spoofImmediateFakeThresholdCall = 0.995
spoofWarmupWindowsCall = 4
spoofHistoryWindowsCall = 5
spoofAudibleRMSCall = 0.003
spoofDecisionSpeechActivityCall = 0.18
speakerMatchThresholdCall = 0.90
```

Verdict semantics in `SpoofResult`:

```text
cloneProbability <= threshold - margin -> human
low confidence -> uncertain
cloneProbability >= immediate fake threshold -> likelyFake
supportingWindows below warmup -> uncertain
cloneProbability >= upper margin and >= extreme fake threshold -> likelyFake
otherwise -> uncertain
```

## Current iOS Analysis Loop

File:

```text
ios/VeriCall/Services/AIAnalysisService.swift
```

Current loop after recent edits:

- Uses latest 3-second / 16 kHz remote window and latest 3-second / 16 kHz local window.
- No 10-second best-window product decision right now.
- Runs at `AppPerformanceProfile` cadence.
- Calls `ClassicSpoofDetector.shared.predict(samples:)`.
- Publishes:
  - `latestSpoof` for remote stream
  - `latestLocalSpoof` for local stream
- Diagnostics look like:

```text
3s rSpoof=0.123(v=human,w=4,c=H) lSpoof=0.982(v=likelyFake,w=4,c=H) rC=0.123 lC=0.982
```

Speech gating in `AIAnalysisService.swift`:

```text
speechFrameSamples = 1_600  # 100ms at 16k
minimumSpeechActivityRatio = 0.06
minimumDecisionSpeechActivityRatio = AudioConfiguration.spoofDecisionSpeechActivityCall
minimumSpoofAnalysisRMS = spoofAudibleRMSCall * 0.35
minimumSyntheticActivityRatio = 0.03
```

If a window is too silent, the model can be skipped or marked low confidence. Be careful here: silence at the start of a call should not push yellow/red and should not lock in a bad product decision.

## Current UI / Product Policy

File:

```text
ios/VeriCall/Services/VoIPCallService.swift
```

Important methods:

```text
observeAIResults()
refreshDisplayedSpoofResult()
otherPartySpoofResultForCurrentCall()
applyRemoteTrustPolicy(to:)
sendLikelySyntheticAlertIfNeeded(result:)
sendFlaggedSyntheticAlertIfNeeded(result:)
sendLiveSpoofAlert(severity:result:)
updateCallKitTrustDisplay(_:result:)
```

Current stream selection:

```swift
private func otherPartySpoofResultForCurrentCall() -> SpoofResult? {
    guard let currentCall else {
        return latestRawRemoteSpoofResult
    }

    switch currentCall.direction {
    case .outgoing:
        return latestRawRemoteSpoofResult
    case .incoming:
        // The Twilio media stream is started on the originating call leg:
        // outbound track = audio sent back to caller, inbound track = caller audio.
        // For the receiving device, the caller's voice is therefore the mirrored local track.
        return latestRawLocalSpoofResult
    }
}
```

This is the highest-value place to inspect for the "new phone wrong / old phone right" issue.

If one phone is correct and the other is wrong on the same human, do not immediately threshold-chase. First prove which stream each phone is actually scoring:

- Is the "wrong" phone scoring the other person's speech, its own microphone path, a mixed path, or silence/noise?
- Does `remote` or `local` have higher RMS and speech activity?
- Are the two devices analyzing different sides of the same Twilio stream because the call direction mapping is wrong?
- Is the source audio itself different because one phone is acting as caller/receiver with different codec/mic/route behavior?

Current product behavior:

- Human result resets suspicious speech and turns normal/green.
- If a high synthetic alert was already sent, human should not erase that.
- Likely fake can trigger notification/buzz.
- If green was already reached, the visual state may remain green for low-friction UX even if a later yellow candidate arrives.
- Alert events still get logged through `CallDebugReporter`.

## Recent Changes To Know About

Recent edits made while debugging iPhone consistency:

1. `AIAnalysisService.swift`
   - Removed 10-second chunk/best-window logic.
   - Restored trained model usage: latest 3-second / 16 kHz window into the model.

2. `PerformanceProfile.swift`
   - Made AI analysis cadence identical across `modern`, `balanced`, and `legacy` device tiers.
   - Previously older phones used slower first-run, interval, immediate-analysis, and mirror-poll settings.

3. `CallTransportService.swift`
   - Changed buffer refresh from async assignment to sync assignment.
   - Goal: avoid AI reading stale/partial remote/local snapshots, especially on older-device timing.

4. `VoIPCallService.swift`
   - Green is sticky for product UX.
   - Yellow/likely synthetic should still trigger notification/buzz.
   - Red/highly synthetic should trigger stronger notification/buzz.

5. `VoiceModels.swift`
   - `spoofDecisionSpeechActivityCall` is currently `0.18`.

## Training / Calibration / Retraining Assets

Primary institutional workflow:

```text
voice-ml/institutional/README.md
voice-ml/institutional/WORKBACK_PLAN.md
```

Core scripts:

```text
voice-ml/institutional/build_manifest.py
voice-ml/institutional/calibrate_thresholds.py
voice-ml/institutional/evaluate_config.py
voice-ml/institutional/prepare_retraining_dataset.py
voice-ml/institutional/retrain_clone_detector.py
voice-ml/institutional/retrain_clone_detector_mps.py
voice-ml/institutional/build_supervised_audio_corpus.py
voice-ml/institutional/build_virtual_pipeline_manifest.py
voice-ml/institutional/generate_tts_fake_dataset.py
```

Important workflow from `voice-ml/institutional/README.md`:

1. Capture production-path chunks from iPhone.
2. Pull device datasets with `devicectl`.
3. Build labeling manifest.
4. Calibrate thresholds from real data.
5. Evaluate recommended config.
6. Prepare retraining manifests if thresholds are not enough.
7. Deploy tuning only after holdout/canary validation.

The README references:

```text
Documents/VerificationDataset/session_<timestamp>_<callid>/
```

Current live code also has a debug capture exporter in `AIAnalysisService.swift`:

```text
AIAnalysisService.debugCaptureEnabledKey = "vericall.debugCaptureEnabled"
ModelCaptureExportService.rootURL = Documents/ModelCaptures
```

`ModelCaptureExportService` writes:

```text
raw.wav
speaker_input.wav
spoof_input.wav
metadata.json
capture_manifest.csv
```

Each metadata row includes:

```text
stream_source
input_sample_rate_hz
post_resample_rate_hz
window_seconds
window_samples
rms_pre_gain
rms_post_gain
clone_probability
spoof_threshold
spoof_is_human
spoof_confidence
route
device_model
call_stack
```

Senior dev note: verify whether the active app build is using `ModelCaptures`, `VerificationDataset`, or both before relying on a capture path. The current code path seen in `AIAnalysisService.swift` definitely has `ModelCaptures`.

## Harness / Benchmark Assets

Current harness files:

```text
ios/scripts/benchmark_webrtc_models.py
ios/scripts/benchmark_webrtc_models.swift
ios/scripts/stage_on_device_eval_set.py
voice-test/Package.swift
voice-test/Sources/VoiceTest/main.swift
voice-test/batch_test.sh
model-eval/model_eval.py
```

Note:

```text
ios/tools/build_lab_benchmark_manifest.py
ios/tools/run_desktop_lab_benchmark.py
```

exist as empty placeholders in the current workspace.

The Python/Swift benchmark scripts use:

```text
ANALYSIS_WINDOW_SAMPLES = 48_000
target 16 kHz mono windows
speaker threshold around 0.90
older spoof bench threshold around 0.665 for the neural/path benchmark
```

Do not confuse old neural/path benchmark thresholds with the current live classic call-loop thresholds in `VoiceModels.swift`.

## Debug Capture Commands

Enable debug capture in-app via a temporary debug toggle or by setting:

```text
UserDefaults key: vericall.debugCaptureEnabled = true
```

Then run the four-call matrix:

```text
1. old phone -> new phone, real human
2. new phone -> old phone, real human
3. old phone -> new phone, same voice clone / replay
4. new phone -> old phone, same voice clone / replay
```

Pull captures from each device:

```sh
mkdir -p ./debug-captures/new-phone ./debug-captures/old-phone

xcrun devicectl device copy from \
  --device D2C94512-1168-5A20-8E62-5A9EA82C8897 \
  --domain-type appDataContainer \
  --domain-identifier com.vicall.app \
  --source Documents/ModelCaptures \
  --destination ./debug-captures/new-phone

xcrun devicectl device copy from \
  --device C74CF6F4-46A0-5821-8D07-E269C42120BE \
  --domain-type appDataContainer \
  --domain-identifier com.vicall.app \
  --source Documents/ModelCaptures \
  --destination ./debug-captures/old-phone
```

If using the older institutional capture path:

```sh
xcrun devicectl device copy from \
  --device <DEVICE_ID> \
  --domain-type appDataContainer \
  --domain-identifier com.vicall.app \
  --source Documents/VerificationDataset \
  --destination ./debug-captures/<phone-name>
```

## What To Compare In Captures

For each call direction and each phone:

- Which stream was scored for the product verdict: `remote` or `local`?
- What are `rSpoof`, `lSpoof`, `rC`, `lC` in `aiDiagnosticsText`?
- What is RMS for each stream?
- What is speech activity for each stream?
- Does playback of `remote/raw.wav` sound like the other person, self, a mix, or silence?
- Does playback of `local/raw.wav` sound like the other person, self, a mix, or silence?
- Does the false result happen only when one specific phone is the audio source?
- Does the false result happen only when one specific phone is the receiver/scorer?
- Is Bluetooth/AirPods/CarPlay involved?
- Is Low Power Mode or thermal state active?

If the new phone is wrong while listening to the old phone's real human audio, the older phone's transmitted/mirrored speech may be more telephony-compressed, clipped, quiet, or sparse. That is an audio-distribution problem, not necessarily a model-core problem.

## Most Likely Root Causes To Investigate

1. Wrong stream selected for the other party
   - Current app assumes outgoing uses `remote`, incoming uses `local`.
   - Backend maps Twilio `inbound` to `local`, `outbound` to `remote`.
   - Verify this with actual captured audio playback, not comments.

2. Source-device audio quality mismatch
   - The "wrong" new phone may simply be scoring audio produced by the older phone.
   - Older phone microphone / route / Twilio codec conditions may resemble replay/clone features.

3. Silence or low-speech windows
   - If a 3-second window contains too much silence, speech activity can be low and the model result can become uncertain or suspicious.
   - Product logic should not turn silence into synthetic.

4. Buffer timing or stale windows
   - `CallTransportService` was patched to sync refresh snapshots.
   - Still verify `TwilioCallService.appendSamples` and `requestImmediateAnalysis` are not causing repeated stale windows.

5. Calibration mismatch
   - Training/calibration pipeline used 3s / 16 kHz LFCC/XGBoost.
   - Live path must feed exactly that shape.
   - Do not add gain/normalization unless it matches training or is validated on human + clone captures.

## Suggested Next Engineering Move

Do not lower thresholds blindly.

First, add or use diagnostics that log the selected stream on each product decision:

```text
direction
selected_stream
remote clone probability
local clone probability
remote RMS
local RMS
remote speech activity
local speech activity
result verdict
device model / hardware identifier
call state
audio route
```

Then run the four-call matrix and pull captures.

If playback proves stream selection is wrong:

- Fix `otherPartySpoofResultForCurrentCall()` or backend `media_mirror_stream_side()` so both phones score the true other-party stream.
- Do not select streams by "which one is more human", because that can mask synthetic audio.
- Select streams by call-leg truth or explicit backend metadata.

If playback proves stream selection is correct but one source phone's real human audio is misclassified:

- Build a small labeled capture set from the bad source phone.
- Run `voice-ml/institutional/calibrate_thresholds.py` first.
- If threshold calibration cannot fix it without losing clone detection, use `prepare_retraining_dataset.py` and `retrain_clone_detector.py` on pipeline-conditioned audio.

## Build / Install Commands

No-sign release build:

```sh
rm -rf /tmp/vicall-device-equalize-build
xcodebuild -workspace ios/VeriCall.xcworkspace \
  -scheme VeriCall \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/vicall-device-equalize-build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Signed device build for Reece's phone:

```sh
rm -rf /tmp/vicall-device-equalize-install
xcodebuild -workspace ios/VeriCall.xcworkspace \
  -scheme VeriCall \
  -configuration Release \
  -destination 'platform=iOS,id=00008120-0006681A3401A01E' \
  -derivedDataPath /tmp/vicall-device-equalize-install \
  -allowProvisioningUpdates \
  build
```

Install same built app to both phones:

```sh
xcrun devicectl device install app \
  --device D2C94512-1168-5A20-8E62-5A9EA82C8897 \
  /tmp/vicall-device-equalize-install/Build/Products/Release-iphoneos/VeriCall.app

xcrun devicectl device install app \
  --device C74CF6F4-46A0-5821-8D07-E269C42120BE \
  /tmp/vicall-device-equalize-install/Build/Products/Release-iphoneos/VeriCall.app
```

## Quick Senior Dev Checklist

Start here:

```sh
cd /Users/reeceway/vicall-build-working
git status --short
rg -n "otherPartySpoofResult|latestRawRemoteSpoofResult|latestRawLocalSpoofResult|remoteAudioBuffer|localAudioBuffer|media_mirror_stream_side|track=\\\"both_tracks\\\"|spoofDecisionSpeechActivityCall|spoofHumanThresholdCall" ios/VeriCall twilio_voice_service/app.py
```

Then inspect:

```text
ios/VeriCall/Services/VoIPCallService.swift
ios/VeriCall/Services/AIAnalysisService.swift
ios/VeriCall/Services/TwilioCallService.swift
ios/VeriCall/Services/CallTransportService.swift
twilio_voice_service/app.py
ios/VeriCall/Models/ClassicSpoofDetector.swift
ios/VeriCall/Models/VoiceModels.swift
```

Key question:

```text
Are both devices scoring the same semantic audio source: "the other person's voice"?
```

Until that is proven by captured WAV playback and per-stream diagnostics, threshold changes are premature.

