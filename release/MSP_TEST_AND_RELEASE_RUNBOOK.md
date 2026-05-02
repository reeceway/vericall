# Vicall MSP Test and Release Runbook

Last updated: May 1, 2026

## Purpose

This runbook defines how to test and release changes that affect the MSP product.

The goal is to keep provisioning, onboarding, seat tracking, and billing from breaking quietly between releases.

## Runtime Baseline

Use one explicit runtime everywhere:

- Python 3.11 for the Twilio/Fly service and local test execution

Do not rely on the default macOS `python3` if it points somewhere older.

## Required Test Environments

### Local

Used for:

- unit tests
- API tests
- fast portal iteration

### Staging or Dedicated Test MSP

Used for:

- Stripe test mode
- full portal flow
- end-to-end onboarding

### Device Validation

Used for:

- clean-install onboarding
- update-install onboarding
- invite-link handling
- OTP flow on real devices

## Test Categories

### 1. Unit Tests

Cover:

- phone normalization
- access-code normalization
- membership state transitions
- billing snapshot math
- webhook status mapping
- OTP challenge lockout logic

### 2. API Tests

Cover:

- admin MSP creation
- organization creation
- access-code creation
- access-code validation
- OTP proxy request and verify
- membership activation
- membership deactivation
- company deactivation
- billing preview
- billing run
- webhook reconciliation

### 3. Browser Tests

Cover:

- portal login
- portal logout
- company creation
- access-code issue
- employee removal
- billing portal launch
- team invite
- role-restricted actions
- billing center timeline and hosted invoice links
- audit-log filters and destructive-action visibility
- browser handoff for account deletion

### 4. App Integration Tests

Cover:

- access-code entry
- invite-link entry
- OTP request
- OTP verify
- expired grant retry
- wrong code
- successful onboarding into correct company
- rejoin after offboarding

### 5. Stripe Test-Mode Flows

Cover:

- create MSP with Stripe customer
- attach payment method
- run invoice
- replay webhook
- payment failure

## Required End-to-End Scenarios

These scenarios must pass before launch readiness.

### Scenario A: Fresh MSP Provisioning

1. Vicall provisions MSP
2. first company and code are created
3. owner signs in
4. owner opens billing portal and adds payment method

### Scenario B: Two-Company Rollout

1. MSP creates a second company
2. company 1 employee joins through app
3. company 2 employee joins through app
4. portal shows both companies and correct seat counts

### Scenario C: Employee Offboard and Rejoin

1. remove active employee
2. confirm access ends
3. confirm seat treatment for current billing period
4. re-onboard same employee with valid code
5. confirm membership is reactivated intentionally

### Scenario D: Billing Run and Reconciliation

1. generate billing preview
2. run invoice in Stripe test mode
3. receive `invoice.finalized`
4. receive `invoice.paid` or `invoice.payment_failed`
5. confirm local billing run reflects Stripe state
6. confirm billing center shows invoice id, hosted invoice link, and company rollups

### Scenario E: Recovery and Edge Cases

1. invalid access code
2. expired access grant
3. repeated OTP failure
4. read-only portal user blocked from mutations
5. pending-review MSP blocked from production access codes but allowed into billing
6. suspended MSP
7. suspended company
8. audit log contains the matching portal and billing events

## Regression Rules

Any change touching one of these areas requires MSP regression coverage:

- login flow
- portal session logic
- onboarding flow
- membership state logic
- billing preview or invoice logic
- Stripe webhook handling
- portal RBAC

## Billing and Seat Policy

- App OTP onboarding activates exactly one membership per `(company, phone_number)`.
- The first provisioned organization for an MSP is the MSP's own firm and is non-billable.
- The first successful app signup for a customer-company membership in a billing period creates an immediate Stripe seat invoice for the MSP customer.
- A repeated signup by the same phone under the same company reuses the existing membership and the existing seat invoice for that period.
- Monthly billing is a catch-up job only: it invoices billable seats that do not already have a seat invoice for the period.
- Manual admin billing runs must pass an explicit `period_start` or use the admin dashboard month picker.
- New customer-company seats default to `$20.00` each.
- Each company includes `450 minutes * billable seats` per billing period.
- Company usage over that allowance accrues at `$0.001` per overage minute and is rounded at the company invoice line.
- Offboarding ends access immediately, but the membership remains billable through the current period.
- User-level minutes are tracked from call session participants and appear in the Billing Center user usage table plus `/portal/export/usage.csv`.

## Suggested Test Order Per Change

1. unit tests
2. targeted API tests
3. browser flow for changed portal paths
4. app onboarding test if onboarding payloads changed
5. Stripe test-mode flow if billing logic changed

## Primary Commands

### Local portal browser matrix

Run the self-contained harness plus browser suite:

```bash
cd /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/browser_tests
npm install
npx playwright install chromium
npx playwright test
```

This suite boots `scripts/msp_browser_test_harness.py`, provisions a fresh MSP in-browser, completes portal sign-in, drives company creation, exercises app-style access-code onboarding and OTP verification, verifies immediate seat invoicing, runs the monthly catch-up billing path, replays a Stripe webhook, opens the billing portal, and completes the account-deletion browser handoff.

### Live smoke path

Run the release-grade smoke flow against staging or a dedicated test MSP target:

```bash
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/smoke_test_msp_lifecycle.py \
  --base-url https://vericall-twilio-voice.fly.dev \
  --admin-key "$VICALL_ADMIN_API_KEY" \
  --owner-phone "+15555550123"
```

This smoke path now checks the real three-step MSP login flow, billing center, audit log, team invite, company creation, app-side access validation, seat rollup, usage export, and offboarding behavior over live HTTP. When `--otp-code` is omitted, the smoke script polls the staging-only OTP endpoint at `/_ops/staging/otp/latest` and uses the returned code automatically.

### 10-MSP acceptance gate

Before a partner-portal release, the portal must pass ten independent MSP lifecycle runs with zero failures:

```bash
VICALL_ADMIN_API_KEY="test-admin-key" \
VICALL_BROWSER_TEST_OTP="111111" \
VICALL_STAGING_SMOKE_ENABLED="true" \
VICALL_STAGING_SMOKE_SECRET="staging-ops-secret" \
PORT="8091" \
HOST="127.0.0.1" \
PUBLIC_BASE_URL="http://127.0.0.1:8091" \
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/msp_browser_test_harness.py
```

Then in a second terminal:

```bash
VICALL_MSP_SMOKE_BASE_URL="http://127.0.0.1:8091" \
VICALL_MSP_SMOKE_ADMIN_KEY="test-admin-key" \
VICALL_MSP_SMOKE_OTP_CODE="111111" \
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/smoke_test_10_msps.py \
  --msps 10 \
  --concurrency 5
```

Each MSP run provisions a fresh tenant, completes portal OTP login, validates billing-center access, invites a team member, creates companies, provisions app seats with access codes, confirms the MSP firm is non-billable, confirms the customer company is billable and duplicate-safe, checks seat rollups and CSV exports, offboards/rejoins an employee, offboards a company, and verifies audit coverage. The release gate is `passed_msps = 10` and `failed_msps = 0`.

### 10,000-user scale gate

Run:

```bash
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/test_msp_10000_user_scale.py
```

The required result is `ok: true` with `customer_users = 10000`, `total_billable_seats = 10000`, and the MSP firm users excluded from billable seats.

You can also run the same smoke flow by environment variable instead of long CLI flags:

```bash
export VICALL_MSP_SMOKE_BASE_URL="https://vericall-twilio-voice.fly.dev"
export VICALL_MSP_SMOKE_ADMIN_KEY="$VICALL_ADMIN_API_KEY"
export VICALL_MSP_SMOKE_OWNER_PHONE="+15555550123"
export VICALL_MSP_SMOKE_OTP_SECRET="$VICALL_STAGING_MSP_OTP_SECRET"
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/smoke_test_msp_lifecycle.py
```

Manual OTP entry still works for one-off checks:

```bash
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/.venv-codex-msp/bin/python \
  /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/smoke_test_msp_lifecycle.py \
  --base-url https://vericall-twilio-voice.fly.dev \
  --admin-key "$VICALL_ADMIN_API_KEY" \
  --owner-phone "+15555550123" \
  --otp-code "123456"
```

### Staging OTP Contract

The unattended staging flow expects the portal service to expose:

- `GET /_ops/staging/otp/latest?phone_number=+15555550123`
- header: `X-Vicall-Staging-Ops-Secret: <shared secret>`

That endpoint must remain disabled unless all of these are true:

- `VICALL_STAGING_SMOKE_ENABLED=true`
- a dedicated `VICALL_STAGING_SMOKE_SECRET` is configured
- the service is not running in a production environment
- the proxied auth backend is not the default production API unless an explicit override is set

The portal service forwards the same request to the main auth backend path configured by `VICALL_STAGING_SMOKE_OTP_PATH` (default: `/auth/staging/otp/latest`).

The Python auth backend now exposes that route directly and keeps it gated by:

- `VICALL_STAGING_SMOKE_ENABLED=true`
- `VICALL_STAGING_SMOKE_SECRET`
- non-production environment values only
- optional phone allowlist in `VICALL_STAGING_SMOKE_PHONE_NUMBERS`
- optional `VICALL_STAGING_SMOKE_OTP_WINDOW_SECONDS` to tune the default 5-minute code window

When that gate is enabled, OTP requests for the allowed staging phone numbers use a short-window staging-only code derived from the shared secret. The backend also records the latest request timestamp, so the smoke flow can fetch the active code without depending on a real SMS inbox or a single in-memory backend instance.

## GitHub Actions Wiring

The repository now has a dedicated workflow at `.github/workflows/msp-portal-release-validation.yml`.

### Automatic job

`Portal Regression` runs on:

- pushes that touch `twilio_voice_service/**`
- pull requests that touch `twilio_voice_service/**`
- daily schedule

It covers:

- `scripts/test_portal_msp_sms_lifecycle.py`
- `scripts/test_account_deletion_flow.py`
- `scripts/test_call_usage_tracking.py`
- `scripts/test_msp_10000_user_scale.py`
- `scripts/smoke_test_10_msps.py --msps 10 --concurrency 5`
- the Playwright browser matrix in `twilio_voice_service/browser_tests`

### Manual staging job

`Staging Smoke` runs from `workflow_dispatch` after the local regression job succeeds.

Dispatch it with:

- `run_staging_smoke = true`
- `owner_phone =` the MSP owner phone for the dedicated staging tenant

Back it with these environment or repository secrets:

- `VICALL_STAGING_MSP_BASE_URL`
- `VICALL_STAGING_ADMIN_API_KEY`
- `VICALL_STAGING_MSP_OTP_SECRET`
- `VICALL_STAGING_MSP_SEAT_PRICE_CENTS` (optional; defaults inside the smoke script if omitted)

Use a dedicated GitHub Environment such as `msp-staging` so only release operators can run the live staging smoke and access the staging secrets.

## Release Checklist

Before release:

- review changed files for MSP-impacting paths
- run updated smoke suite
- run targeted API and browser tests
- verify Python runtime consistency
- verify required secrets in target environment
- verify Stripe mode is correct for environment

If auth, onboarding, or billing changed:

- run at least one full end-to-end test MSP scenario

## Post-Deploy Checklist

After deploy:

- confirm portal login works
- confirm new MSP provisioning works
- confirm access-code validation works
- confirm OTP proxy works
- confirm billing preview loads
- confirm Stripe webhook endpoint is healthy

## Rollback Triggers

Rollback immediately if any of these are true:

- owners cannot log in
- employees cannot complete org-backed onboarding
- memberships are being written to the wrong organization
- invoice runs are duplicated
- webhook processing corrupts billing status

## Evidence to Save for Each Release

- commit or build identifier
- environment deployed
- tests executed
- key scenarios passed
- known limitations
- rollback owner

## Definition of Release Readiness

A release is ready when:

- core MSP scenarios pass from a clean state
- no known P1 issues remain in auth, membership, or billing
- support knows what changed
- finance-impacting behavior is explained and verified
