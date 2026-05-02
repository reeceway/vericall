# Vicall Admin Senior Engineer Notes

This file is the durable project note for future Vicall admin, AI/calling, portal, billing, testing, and backup work. It intentionally contains no live passwords, OTPs, setup links, Twilio tokens, Stripe secrets, admin keys, or raw portal keys.

The matching local Codex skill is installed at:

- `/Users/reeceway/.codex/skills/vicall-senior-engineer/SKILL.md`

Use `$vicall-senior-engineer` in future Codex sessions when working on Vicall production admin operations, iOS AI/call fixes, MSP portal readiness, billing/minutes, real production testing, or backups.

## Canonical System Map

- Repo: `/Users/reeceway/Desktop/vericall voiceprints/vericall`
- iOS workspace: `/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall.xcworkspace`
- iOS source: `/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall`
- Fly/Twilio service: `/Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service`
- Portal/backend: `/Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py`
- Control plane/billing store: `/Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/control_plane.py`
- Production Fly app: `vericall-twilio-voice`
- Production URL: `https://vericall-twilio-voice.fly.dev`
- MSP portal login: `https://vericall-twilio-voice.fly.dev/portal/login`

Distribution details live in the existing Codex skill:

- `/Users/reeceway/.codex/skills/vicall-distribution/SKILL.md`

## Production Admin Rules

- Do not print secrets, passwords, OTPs, API keys, one-time setup links, Stripe keys, Twilio auth tokens, JWTs, or raw access-code hashes into chat.
- If the user asks for a production-only test, do not present synthetic harness results as production proof.
- If a live operation creates users, seats, Stripe customers, invoices, charges, or production access codes, make the mutation explicit and auditable.
- Use `flyctl auth whoami` and `flyctl status -a vericall-twilio-voice` before live Fly admin work.
- For MSP password recovery, prefer a one-time setup link. If the user authorizes a permanent reset, generate a password on the Fly VM, set it through `ControlPlaneStore.set_msp_user_password`, revoke sessions, consume setup tokens, audit the reset, and copy the password to the local clipboard instead of printing it.

## MSP Portal Flow To Prove

1. Vicall provisions an MSP and a first non-billable MSP firm.
2. MSP owner signs in with email/password, phone confirmation, and SMS OTP.
3. MSP adds a Stripe default payment method before creating billable customer companies.
4. MSP creates a customer company.
5. MSP issues an access code for that company.
6. iOS app validates the access code, requests OTP, verifies the phone, and activates the membership.
7. The phone appears in the portal as a seat under the right company.
8. Twilio call lifecycle callbacks record call events and minutes.
9. Billing preview shows billable seats, included minutes, overage, invoice/payment status, and projected total.

## Billing Model

- One MSP equals one Stripe customer.
- The MSP's own firm is non-billable.
- Customer-company active memberships become billable seats.
- Default customer-company seat price is `$20.00` per seat per month.
- Each billable customer-company seat includes `450` minutes.
- Overage is `$0.001` per minute after `450 * billable_seats`, calculated at the customer-company level.
- Internally, overage accrues in decicents so the `$0.001` rate is preserved.
- Stripe invoices are whole cents, so overage is rounded only after company-level monthly aggregation.
- Monthly first-of-month billing should run the previous completed month idempotently and charge automatically when a default payment method exists.

Important functions/tables are in `twilio_voice_service/control_plane.py`:

- `record_call_event`
- `call_usage_rollup`
- `billing_snapshot`
- `record_billing_run`
- `included_minutes_for_seats`
- `overage_minutes_for_usage`
- `overage_amount_decicents_for_minutes`
- `seat_billing_events`
- `organization_usage_monthly`
- `user_usage_monthly`
- `call_sessions`
- `call_participants`

## iOS AI And Calling Truth

The live AI path is:

`Twilio call -> backend media mirror -> 8 kHz mu-law expansion to 16 kHz PCM16 -> app audio mirror polling -> remote/local rolling buffers -> AIAnalysisService -> classic spoof model -> VoIPCallService trust state -> UI, CallKit display, notification, buzz`

Do not change the model's expected input format casually:

- `AudioConfiguration.sampleRate = 16_000`
- `AudioConfiguration.analysisWindowSeconds = 3.0`
- `AudioConfiguration.analysisWindowSamples = 48_000`
- `SpoofDetector` expects 48,000 normalized float samples, 3 seconds at 16 kHz.
- `ClassicSpoofDetector` is the live product spoof detector path.
- Bluetooth, AirPods, CarPlay, and speaker routing belong to Twilio/CallKit audio session handling. The AI should receive a separately mirrored and transformed 16 kHz stream.

Primary iOS files:

- `ios/VeriCall/Services/TwilioCallService.swift`
- `ios/VeriCall/Services/AIAnalysisService.swift`
- `ios/VeriCall/Models/VoiceModels.swift`
- `ios/VeriCall/Models/SpoofDetector.swift`
- `ios/VeriCall/Models/ClassicSpoofDetector.swift`
- `ios/VeriCall/Services/VoIPCallService.swift`
- `ios/VeriCall/Services/NotificationService.swift`
- `ios/VeriCall/App/PerformanceProfile.swift`
- `ios/VeriCall/Views/Calling/VoIPActiveCallView.swift`

Product target:

- Real human speech should go green within the first few seconds.
- Silence should not downgrade green or create synthetic alerts by itself.
- If green has been reached, keep the call green unless the product policy is deliberately changed.
- Yellow means synthetic/likely synthetic.
- Red means definitely or highly likely synthetic.
- Notifications and buzz must work with SwiftUI open, SwiftUI closed, and CallKit active.
- If model quality suddenly worsens, inspect audio source, sample conversion, silence handling, rolling average, model warmup, and UI mapping before retraining or threshold chasing.

Bluetooth and route matrix:

- AirPods connected before call
- AirPods connected mid-call
- AirPods disconnected mid-call
- Regular Bluetooth headset
- Car Bluetooth connected before call
- Car Bluetooth route switch mid-call
- Wired CarPlay
- Wireless CarPlay
- Older iPhone locked and answered through CallKit

## Local Harness Tests

These are good regression gates but are not production proof:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
twilio_voice_service/.venv-codex-msp/bin/python -m py_compile twilio_voice_service/app.py twilio_voice_service/control_plane.py twilio_voice_service/scripts/test_msp_100_dashboard_readiness.py
python3 twilio_voice_service/scripts/test_msp_100_dashboard_readiness.py --msps 100 --render-threshold-seconds 12
twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_call_usage_tracking.py
twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_msp_10000_user_scale.py --companies 100 --users-per-company 100 --call-users 10000 --snapshot-threshold-seconds 12 --billing-run-threshold-seconds 20
cd twilio_voice_service/browser_tests && npm test -- --reporter=list
```

Real production proof requires the live portal, real SMS OTP, real app onboarding, real Twilio call lifecycle callbacks, real Stripe customer/payment state, and portal billing preview.

## File Lookup Patterns

iOS AI/call:

```sh
rg -n "spoof|synthetic|yellow|red|green|threshold|notification|buzz|CallKit|audio|sample|16000|silence|human|mirror" ios/VeriCall
```

MSP/billing:

```sh
rg -n "billing_snapshot|record_call_event|record_billing_run|seat_billing|included_minutes|overage|portal_summary|render_portal_dashboard|Stripe|webhook" twilio_voice_service
```

Release/App Store:

```sh
rg -n "CFBundleIdentifier|MARKETING_VERSION|CURRENT_PROJECT_VERSION|aps-environment|PRODUCT_BUNDLE_IDENTIFIER" ios
```

## Backup Procedure

Before risky changes:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
git status --short
git remote -v
```

Local archive:

```sh
mkdir -p "$HOME/Desktop/vicall-local-backups"
tar --exclude='.git' --exclude='ios/Pods' --exclude='ios/build' --exclude='DerivedData' \
  -czf "$HOME/Desktop/vicall-local-backups/vicall-$(date +%Y%m%d-%H%M%S).tgz" \
  -C "/Users/reeceway/Desktop/vericall voiceprints" vericall
```

GitHub backup:

- Inspect dirty state first.
- Do not revert user changes.
- Commit intentionally with a subsystem-specific message.
- Push to the configured Vicall remote only after confirming the remote is correct.

## Senior Engineer Checklist

- Read local code before relying on memory.
- Preserve working CallKit/PushKit/Twilio paths unless directly debugging them.
- Keep fake harness results clearly labeled.
- Keep production mutations auditable.
- Avoid threshold-only AI fixes until audio source and preprocessing are verified.
- For App Store/TestFlight, use the `vicall-distribution` skill.
- For browser work, use the in-app browser plugin when it is available; otherwise fall back to Playwright and state the fallback.
