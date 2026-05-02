# Vicall Sell/Demo Readiness Gate

Last updated: 2026-05-01

This file answers one question: is this the Vicall version we can confidently sell first and demo to MSPs?

## Current Verdict

Status: **Yellow - production portal proof is green, but the exact sell/demo phone build is not yet proven on the paired devices.**

The current local Release build identity is:

- Bundle ID: `com.vicall.app`
- Version: `1.0.2`
- Build: `11`
- Team: `96294C9WZU`
- Device family: iPhone only
- APS environment: production
- Production backend: `https://vericall-twilio-voice.fly.dev`

Both paired phones currently report the dev bundle instead:

- `com.reeceway.vericall.dev`
- Version `1.0.1`
- Build `9`

That means the connected phones are not yet proving the current sell/demo build. Before a paid MSP demo, install/sign the current build `1.0.2 (11)` on both phones, then run the two-phone smoke.

## Go / No-Go Rule

Green means demo/sell pilot:

- production portal login works with email/password, phone confirmation, and SMS OTP
- dashboard, billing, and audit load for the MSP account
- current iOS Release build compiles
- current iOS build is installed on both test phones
- one real two-phone call connects quickly
- AI trust state appears during the call
- real human speech turns green within the first few seconds
- synthetic/speaker playback can trigger yellow/red behavior
- notification and buzz work when CallKit is active and the app UI is not open
- billing preview shows seats, included minutes, overage, payment readiness, and projected total

Yellow means high-touch pilot only:

- harness and build pass, but production OTP, real app call, Stripe payment method, or device install is not verified
- portal is usable with Vicall assisting onboarding

Red means do not demo:

- production login fails
- app cannot complete access-code/OTP onboarding
- calls do not connect or audio is missing
- AI model fails to load
- billing preview cannot explain seats/minutes/overage
- Release build does not compile

## Commands

Production portal audit:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
node twilio_voice_service/scripts/audit_production_msp_portal.mjs
```

The script reads the portal password from the macOS clipboard or `VICALL_PORTAL_PASSWORD`, then prompts for the production SMS OTP. It captures dashboard, billing, and audit screenshots/text under `/tmp/vicall-portal-audit` and writes:

```text
/tmp/vicall-portal-audit/portal-audit-result.json
```

Non-mutating local portal/billing gates:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
twilio_voice_service/.venv-codex-msp/bin/python -m py_compile twilio_voice_service/app.py twilio_voice_service/control_plane.py twilio_voice_service/scripts/test_msp_100_dashboard_readiness.py
python3 twilio_voice_service/scripts/test_msp_100_dashboard_readiness.py --msps 100 --render-threshold-seconds 12
twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_call_usage_tracking.py
twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_msp_10000_user_scale.py --companies 100 --users-per-company 100 --call-users 10000 --snapshot-threshold-seconds 12 --billing-run-threshold-seconds 20
cd twilio_voice_service/browser_tests && npm test -- --reporter=list
```

iOS Release identity:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall/ios"
xcodebuild -workspace VeriCall.xcworkspace -scheme VeriCall -configuration Release -showBuildSettings \
  | rg "MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|APS_ENVIRONMENT|TARGETED_DEVICE_FAMILY"
```

iOS no-sign Release build:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall/ios"
xcodebuild -workspace VeriCall.xcworkspace \
  -scheme VeriCall \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/vicall-demo-readiness-nosign \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Connected-device check:

```sh
xcrun devicectl list devices
xcrun devicectl device info apps --device <device-id> | rg "com\\.vicall\\.app|com\\.reeceway\\.vericall\\.dev|Vicall"
```

## Evidence From 2026-05-01

Passed:

- Fly app `vericall-twilio-voice` is running.
- Production portal `/health` returned HTTP 200 after the portal redeploy.
- Backend `/auth/check-otp` is live and returns fast instead of hanging.
- Production portal email/password and phone-confirmation steps reached the SMS OTP screen.
- Production portal audit completed successfully against the live backend: login, dashboard, billing, and audit all loaded for `reece@vicallapp.com`.
- Dashboard shows Vericall as the active MSP firm with zero billable seats and payment setup required before customer-company provisioning.
- Billing center shows May 2026 preview with one company, zero billable seats, zero usage, and Stripe readiness blocked by missing default payment method.
- Audit log shows the successful SMS login event and prior billing/provisioning events.
- Release settings show `com.vicall.app`, `1.0.2 (11)`, team `96294C9WZU`, production APS, iPhone only.
- Production backend URL in the app is `https://vericall-twilio-voice.fly.dev`.
- No-sign Release build succeeded.
- 100-MSP dashboard readiness gate passed in `3.901s`.
- Call usage tracking test passed.
- 10,000-user scale billing test passed: `10,000` customer users, `30,000` tracked minutes, `10,000` billable seats, no post-billing unbilled seats.
- Browser portal harness passed on desktop and tablet.

Pending:

- Production usage reporting was repaired and reconciled: April now shows 14 real calls, 1,340 seconds, and 30 rounded minutes in cached company/user usage rows. See `VICALL_PRODUCTION_USAGE_AUDIT_2026-05-01.md`.
- Live customer-company billing proof is still blocked by missing default Stripe payment method and no current billable customer company.
- Current `1.0.2 (11)` build is not installed on the two paired phones yet.
- Real two-phone call smoke still needs to be run on the installed current build.

## Demo Script Once Green

1. Open production MSP portal.
2. Show top metrics: customer companies, billable seats, used/included minutes, overage, projected monthly bill, payment readiness.
3. Open a company card and show its seats and top usage.
4. Open billing and show monthly rollup.
5. Open audit and show traceability of admin/MSP actions.
6. On iPhone A, open Vicall with the current build.
7. On iPhone B, answer through CallKit.
8. Talk normally and verify green human state.
9. Play synthetic/speaker audio and verify yellow/red warning behavior.
10. Return to the portal and show seat/minute readiness for billing.
