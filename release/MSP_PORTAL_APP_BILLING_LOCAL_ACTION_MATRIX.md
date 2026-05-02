# MSP Portal/App/Billing Local Action Matrix

Purpose: prove the local MSP portal, app onboarding, minute tracking, billing, and logging chain before live production smoke testing.

Run the gate:

```sh
cd "/Users/reeceway/Desktop/vericall voiceprints/vericall"
twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_msp_portal_app_billing_logging_matrix.py --cycles 4
```

This is a local contract gate. It uses local databases plus fake SMS and fake Stripe transport so it can run repeatedly without touching real customers, real OTPs, or real cards. It does not replace a live production smoke for carrier delivery, Stripe test/live mode, APNs, or iPhone device behavior.

## MSP Actions

| Action | Expected proof |
| --- | --- |
| Vicall provisions the MSP owner, Stripe customer link, non-billable MSP firm, and first access code | Admin/provision flow succeeds, firm is billing-exempt, setup link is one-time, secrets are not printed |
| MSP owner signs in | Email/password, phone confirmation, SMS OTP, and staging OTP retrieval all work; login is audited |
| MSP opens dashboard | Company cards, billing totals, payment status, seat totals, and minute totals render |
| MSP opens billing center | Invoice timeline, company rollup, and user usage render |
| MSP opens Stripe billing portal | Stripe portal session is created and audited |
| MSP invites team members | Operator and read-only users can be created, set passwords, and sign in |
| MSP role checks writes | Read-only can view dashboard/billing/audit, but cannot create companies |
| MSP tries customer company before payment | Customer company creation is blocked until payment readiness exists |
| MSP creates a customer company | Company is billable, gets seat limit, gets an access code, and is audited |
| MSP updates company settings | External ref and provisioned seats persist and are audited |
| MSP creates access codes | New codes can have labels and seat caps and are audited |
| MSP disables access codes | Disabled codes fail closed for new app onboarding and are audited |
| MSP exports data | Companies, users, and usage CSV exports return CSV and each export is audited |
| MSP reviews audit log | Audit page and action filter render required actions |
| MSP offboards one seat | Membership is deactivated, active seat total drops, device/token access fails closed, action is audited |
| MSP offboards a company | Company codes and voice tokens fail closed while period billing remains historically correct |
| MSP enters pending review | Provisioning and access-code issuance are blocked, billing remains reachable |
| MSP is suspended after payment failure | Company creation and app/voice access are blocked, billing remains reachable |
| MSP logs out | Session is cleared and logout is audited |

## User/App Actions

| Action | Expected proof |
| --- | --- |
| User validates access code | App receives organization context and grant token |
| User requests OTP | Main auth OTP path is called through the portal service contract |
| User verifies OTP | Public key is required, app membership activates, response returns billing status |
| User joins the MSP firm | Seat is active but non-billable |
| User joins customer company | Seat is active and immediate seat invoice is created |
| User repeats signup under same company | Membership remains a single billable seat; duplicate billing is prevented |
| User hits seat cap | Company seat cap returns conflict |
| User hits access-code cap | Access-code seat cap returns conflict |
| User registers device binding | Active membership can bind a device; inactive membership is denied |
| User requests Twilio token | Active membership receives token; inactive/offboarded/suspended membership is denied |
| User places a call | Twilio webhook returns client TwiML and records call events |
| User minutes exceed included allowance | Billing snapshot applies 450 included minutes per billable seat and `$0.001/min` overage |
| User deletes account | Membership and device binding are removed and deletion is audited |
| User is reprovisioned | Admin reprovisioning restores active membership and portal counts |

## Billing And Logging Surfaces

The local gate checks these tracked surfaces:

| Surface | Expected proof |
| --- | --- |
| MSP audit events | Login, logout, company create/update, access-code create/deactivate, membership/company deactivate, team invite, export, billing portal |
| System audit events | Billing run, invoice status update, seat invoice status update, payment-failure suspension, account deletion |
| Call events | Direct and conference-style events dedupe into user/company monthly minutes |
| Seat billing events | Immediate customer seat invoice and monthly catch-up invoice records exist and update status |
| Billing snapshots | Firm seats are exempt, customer seats are billable, included minutes and overage are correct |
| Monthly billing runs | Explicit run and first-day automatic run are idempotent |
| Usage storage | Company and user monthly usage tables are populated during export and billing runs |
| Stripe webhooks | `invoice.finalized`, `invoice.paid`, and `invoice.payment_failed` update local state |
| Portal views | Dashboard, billing center, company detail, audit, and CSV export routes render |
| Scale sanity | Ten independent MSPs render grouped dashboards with totals inside the configured render budget |

## Current Local Test Suite

| Suite | Repeated | Coverage |
| --- | ---: | --- |
| `test_portal_msp_sms_lifecycle.py` | 4x | Portal -> app onboarding -> portal summary -> billing -> Stripe webhook -> audit/logging lifecycle |
| `test_call_usage_tracking.py` | 4x | Call-session dedupe, user/company minute rollups, included minutes, overage, and usage storage |
| `test_msp_100_dashboard_readiness.py --msps 10` | 4x | Ten-MSP grouped dashboard, company totals, payment readiness, and render performance |

## Production Proof Still Required

Before saying the first 10 MSPs are fully production-ready, run a separate live smoke that uses:

- Real production portal login with SMS OTP.
- Real Stripe test/live customer with default payment method.
- Real app onboarding on iPhone with a portal-created access code.
- Real Twilio call event through the iOS app.
- Real portal billing preview after call usage.
- Real audit-log review in production.
