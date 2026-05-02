# MSP Production Extensive Smoke

Purpose: prove the real production system at `https://vericall-twilio-voice.fly.dev` before selling/demoing MSP onboarding.

This is different from the local action matrix. These checks hit the live Fly app, live control-plane database, live Stripe configuration, live portal login, and live Twilio Voice endpoints.

## Production Runner

Safe public/security preflight only:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
twilio_voice_service/.venv-codex-msp/bin/python \
  twilio_voice_service/scripts/production_extensive_msp_smoke.py \
  --out /tmp/vicall-production-smoke-safe.json
```

Isolated production mutation smoke:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
twilio_voice_service/.venv-codex-msp/bin/python \
  twilio_voice_service/scripts/production_extensive_msp_smoke.py \
  --admin-key-from-fly \
  --allow-production-mutations \
  --out /tmp/vicall-production-smoke-mutating.json
```

Browser portal audit with real SMS:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
VICALL_PORTAL_AUDIT_DIR=/tmp/vicall-portal-audit-prod-$(date +%Y%m%d-%H%M%S) \
node twilio_voice_service/scripts/audit_production_msp_portal.mjs
```

## Latest Production Result

Date: May 1, 2026, 11:03 PM ET.

Backend production smoke:

- `23/23` live checks passed.
- Created isolated production smoke MSP.
- Created real Stripe customer for that smoke MSP.
- Proved non-billable MSP firm behavior.
- Proved customer-company access is blocked without a default payment method.
- Activated an isolated customer membership for usage probing.
- Proved access-code seat cap enforcement.
- Proved production device binding, Twilio token, TwiML, and client-status minute tracking path.
- Proved billing preview showed `1` billable seat, `4` billable minutes, and `$20.00`.
- Proved admin companies/users/usage CSV exports.
- Proved billing run fails closed without default payment method and restores MSP status.
- Proved suspended MSP blocks voice token issuance.
- Proved deactivated company access code fails closed.

Portal browser production audit:

- Real `reece@vicallapp.com` email/password login passed.
- Real phone confirmation for phone ending `8887` passed.
- Real SMS OTP passed.
- Dashboard page rendered.
- Billing center rendered.
- Audit log rendered.

Artifacts:

- `/tmp/vicall-production-smoke-mutating.json`
- `/tmp/vicall-portal-audit-prod-interactive-20260501-230243/portal-audit-result.json`

## What This Proves

| Area | Production proof |
| --- | --- |
| Fly service | Live health and portal routes are reachable |
| Portal auth | Email/password, phone confirmation, SMS OTP, and session dashboard access work |
| Portal UI | Dashboard, billing center, and audit log render in production |
| Admin protection | Admin storage endpoint rejects unauthenticated access |
| Provisioning | Production can provision an MSP, firm, owner, Stripe customer, customer company, access code, and membership |
| Payment gate | Customer-company access is blocked until default Stripe payment method exists |
| Billing math | `$20` per billable customer seat, firm exemption, minute rollup, and preview totals work |
| Minutes | Production call status callback writes billable minutes into preview/export surfaces |
| Voice | Active membership can bind device, receive token, and get TwiML; inactive/suspended identities fail closed |
| Exports | Admin companies, users, and usage CSV exports work |
| Lifecycle | Suspended MSP and deactivated company behavior fail closed |
| Logging | Portal audit page shows login, billing, provisioning, and reset events |

## Not Claimed By This Runner

- It does not place a physical iPhone-to-iPhone call through APNs/CallKit.
- It does not prove Bluetooth, CarPlay, or on-device AI audio behavior.
- It does not run a live paid Stripe charge. The test intentionally proves missing-payment blocking instead of charging a real card.
- It does not activate a billable customer company through the app OTP path because production correctly blocks that until a default payment method exists.

Final sales/demo readiness still needs one device smoke after a payment method is intentionally attached:

1. Add a default payment method for the MSP that will demo customer-company onboarding.
2. Create a real customer company and access code in the portal.
3. On an iPhone, enter that access code and phone number.
4. Confirm SMS OTP.
5. Verify the phone appears as a billable seat in the portal.
6. Place a real Vicall call.
7. Verify minutes appear in the billing center.
