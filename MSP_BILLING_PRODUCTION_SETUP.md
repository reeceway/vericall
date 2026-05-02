# Vicall MSP Billing Production Setup

This is the production v1 control-plane model now wired into the codebase.

## Model

- One MSP = one Stripe customer
- One company = one `organization`
- The first provisioned organization for an MSP is the MSP's own firm and is marked non-billable
- One company code / invite link = one `organization_access_code`
- A successful code validation can return:
  - `organization_id`
  - `organization_name`
  - `msp_id`
  - `msp_name`
  - `access_code_id`
  - `grant_token`
- OTP request/verify can now be proxied through the Twilio/Fly service with `access_grant_token`
- Successful OTP verification activates or refreshes an `organization_membership`
- Monthly billing rolls up to the MSP with one invoice line per organization
- Twilio lifecycle callbacks now create one canonical `call_session`, preserve each Twilio leg, and roll billable minutes up by user and company

## New Durable Tables

Stored in SQLite on the Twilio/Fly persistent volume:

- `msps`
- `organizations`
- `organization_access_codes`
- `access_grants`
- `organization_memberships`
- `call_sessions`
- `call_session_legs`
- `call_participants`
- `user_usage_monthly`
- `organization_usage_monthly`
- `seat_billing_events`
- `billing_runs`
- `msp_audit_events`

Default DB path:

- `/data/vericall_control.db`

## New Live App Flow

1. User enters company access code.
2. `POST /access/validate` returns valid/invalid.
3. If the code is organization-backed, it also returns org/MSP context and a short-lived `grant_token`.
4. The iOS app stores the validated code plus the pending access context.
5. OTP request goes through `POST /access/request-otp` when a grant token exists.
6. OTP verify goes through `POST /access/verify-otp` when a grant token exists.
7. On successful verify, the service upserts an active membership for the user under that organization.

Legacy codes still work:

- If a code only exists in the old `VICALL_ACCESS_CODE_HASHES` / `VICALL_ACCESS_CODES` env config, validation still returns `valid: true`, but no org/MSP context.
- In that case, the app falls back to the legacy direct OTP flow.

That gives us a safe migration path.

## Required Fly Secrets

### Required for admin + org routing

- `VICALL_ADMIN_API_KEY`

### Required for Stripe billing

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`

### Optional

- `MAIN_API_BASE_URL`
  - defaults to `https://vericall-api.fly.dev`
- `VICALL_CONTROL_DB_PATH`
  - defaults to `/data/vericall_control.db`

## Admin Endpoints

All admin endpoints require:

- header: `x-admin-key: <VICALL_ADMIN_API_KEY>`

Endpoints:

- `POST /admin/msps`
- `POST /admin/organizations`
- `POST /admin/access-codes`
- `GET /admin/overview`
- `GET /admin/msps/{msp_id}`
- `GET /admin/msps/{msp_id}/export/usage.csv`
- `GET /admin/msps/{msp_id}/billing/preview`
- `POST /admin/msps/{msp_id}/stripe/customer`
- `POST /admin/msps/{msp_id}/billing/run`
- `POST /admin/billing/run-all`

Manual billing runs accept an explicit `period_start` value as `YYYY-MM`, `YYYY-MM-DD`, or ISO date. The admin dashboard uses a month picker and defaults to the last completed month.

## MSP Portal Endpoints

Each MSP gets one or more MSP portal users for the normal session-based sign-in flow.

Human entry points:

- `GET /portal/login`
- `GET /portal/setup-password`
- `POST /portal/setup-password`
- `GET /portal/dashboard`

Endpoints:

- `GET /portal/summary`
- `POST /portal/login`
- `POST /portal/login/request`
- `GET /portal/login/verify`
- `POST /portal/team/invite`
- `GET /portal/export/usage.csv`
- `POST /portal/customer-portal-session`
- `GET /portal/billing/manage`
- `POST /portal/billing/manage`

## Stripe Behavior

This v1 uses invoice items, not Connect and not metered billing.

Monthly flow:

1. Count active memberships per organization under the MSP.
2. Roll up completed call sessions for the period by organization and user.
3. Create one Stripe invoice item per organization.
4. Create one Stripe invoice for the MSP customer.
5. Record the invoice, per-org seat/minute snapshot, and per-user minute snapshot locally.

This keeps invoices readable:

- `Acme Dental — 14 active seats`
- `Northside Law — 6 active seats`

Minute reporting is intentionally session-based instead of raw Twilio-leg-based. Direct client calls and conference wakes can emit multiple Twilio `CallSid` values, so `call_session_legs` stores the leg detail while `call_sessions` keeps the single billable duration used for company and user rollups.

MSP onboarding and billing setup now work like this:

1. Vicall provisions the MSP from the admin dashboard.
2. The service creates a Stripe customer for that MSP immediately.
3. Provisioning creates the first company, the first access code, the first MSP portal owner, and a one-time password setup link.
4. The MSP sets a portal password through the setup link, then signs in with email/password at `/portal/login`.
5. The MSP is sent into the Stripe billing portal to add a payment method.
6. The MSP's own firm can use Vicall without being charged.
7. Customer-company creation, customer access-code issuance, and customer employee activation require a default Stripe payment method.
8. Every employee phone number activated under a customer company becomes a billable seat for that company.
9. Monthly billing rolls customer companies and all billable customer seats into one MSP invoice.

## Webhook

Stripe webhook endpoint:

- `POST /stripe/webhook`

Handled statuses:

- `invoice.finalized`
- `invoice.paid`
- `invoice.payment_failed`

Production billing hold behavior:

- `invoice.payment_failed` updates the local billing/seat invoice status and writes the event into the MSP audit log.
- By default, `invoice.payment_failed` also moves an active MSP to `suspended` through `VICALL_SUSPEND_MSP_ON_PAYMENT_FAILED=true`.
- Suspended MSPs can still sign in and open Stripe billing, but cannot provision companies, issue access codes, validate new app access, register device bindings, receive new Twilio tokens, or route new calls.
- The hold is access-only. Companies, memberships, billing history, audit history, and usage remain retained so Vicall can collect, reconcile, or reactivate deliberately.
- Set `VICALL_SUSPEND_MSP_ON_PAYMENT_FAILED=false` only for a deliberate non-production test or a temporary support exception.

Pricing and overage behavior:

- Customer-company seats default to `$20.00` per seat per month.
- Each customer company receives `450` included minutes per billable seat by default.
- The MSP's own firm is non-billable and does not generate seat charges or overage.
- Overage is calculated per customer company after `450 × billable company seats`.
- Overage bills at `$0.001` per minute by default.
- Internally, overage accrues in decicents so `$0.001/minute` is preserved. Stripe lines are whole cents, so overage is rounded up only after company-level monthly aggregation.
- The defaults are controlled by `DEFAULT_MSP_SEAT_PRICE_CENTS`, `VICALL_INCLUDED_MINUTES_PER_SEAT`, and `VICALL_OVERAGE_DECICENTS_PER_MINUTE`.

Automatic first-of-month billing:

- `VICALL_AUTO_BILLING_ENABLED=true` is enabled by default.
- On the 1st of each month, the Fly service runs monthly billing for the previous completed month.
- Billing is idempotent by MSP and billing period, so restarts on the 1st do not double-bill the same seats.
- Stripe invoices use `collection_method=charge_automatically` and finalization with `auto_advance=true`, so a default payment method is charged automatically.
- If an MSP has customer charges but no default payment method, the billing run is skipped, audited, and the MSP is suspended until billing is fixed.

## Company 1 Rollout

Planned current company mapping:

- access code: `VICALL-COMPANY-8N3Q`

Non-billing/test codes stay legacy unless explicitly migrated:

- `VICALL-FAMILY-6K2R`
- `VICALL-REVIEW-4P7M`

## Suggested Live Rollout Order

1. Deploy the Twilio/Fly service changes.
2. Set `VICALL_ADMIN_API_KEY` on Fly.
3. Create MSP 1.
4. Create Company 1 organization under MSP 1.
5. Create access code `VICALL-COMPANY-8N3Q` for Company 1.
6. Verify `/access/validate` returns org/MSP context for that code.
7. Set `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`.
8. Attach or create Stripe customer for the MSP.
9. Use `/admin/msps/{msp_id}/billing/run` for the monthly invoice.

## Current Remaining Manual Step

Stripe secrets are still required to make real monthly invoices live. The app/org assignment flow is implemented; the live billing execution depends on those Stripe secrets being present on Fly.
