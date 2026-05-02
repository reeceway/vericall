# Vicall MSP Channel Technical Plan

Last updated: April 10, 2026

## 1. Goal

Build Vicall so it can be sold to MSPs, then rolled out by those MSPs to their client companies, without manual per-user provisioning.

The system should support:

- MSP-level billing
- company-level rollout
- user self-onboarding with a link + code
- company-level reporting
- MSP-level invoice rollups
- admin-level monitoring across the whole channel

This document is the technical execution plan for getting from the current working app to a sellable MSP channel product.

For the full cross-system finish plan covering the portal, app, backend, seat ledger, Stripe, testing, and launch gates, see `MSP_E2E_FINISH_PLAN.md`.

For the complete MSP documentation set, see `MSP_DOCUMENTATION_INDEX.md`.

## 2. Channel Product Model

The product model is:

- one MSP = one billing entity
- one MSP = one Stripe customer
- one company = one `organization`
- one company code / link = one `organization_access_code`
- one installed and verified user = one `organization_membership`
- one active membership = one billable seat

This is the right commercial shape because:

- MSPs want one vendor relationship, not hundreds
- client companies want simple rollout, not custom setup
- end users want instant install + verify + use
- Vicall needs rollup billing and support visibility

## 3. Current Stack Baseline

### App

- iOS SwiftUI app
- Twilio Voice for media/signaling
- PushKit + CallKit for real incoming call behavior
- on-device classic spoof detector during live calls

### Main backend

- `https://vericall-api.fly.dev`
- handles OTP auth, users, contacts, and general app data

### Twilio/Fly service

- `https://vericall-twilio-voice.fly.dev`
- handles Twilio Voice token issuance
- handles device bindings
- now also handles MSP/company access-code control plane

### Newly implemented control plane

Already added to the Twilio/Fly service:

- `msps`
- `organizations`
- `organization_access_codes`
- `access_grants`
- `organization_memberships`
- `organization_usage_monthly`
- `billing_runs`

Already live:

- org-aware `POST /access/validate`
- `POST /access/request-otp`
- `POST /access/verify-otp`
- admin endpoints
- MSP portal summary endpoint
- billing snapshot logic
- Stripe invoice scaffolding

## 4. What “Sellable to MSPs” Means

For the product to be sellable to MSPs, these flows must all work cleanly:

1. Vicall creates an MSP account.
2. Vicall creates one or more client companies under that MSP.
3. Each company gets a code and invite link.
4. MSP distributes the code/link to client users.
5. Users install Vicall and self-onboard immediately.
6. Users are attached to the correct company and MSP automatically.
7. MSP can see company seat counts and recent joins.
8. Vicall can bill the MSP monthly with company-level line items.

If any of those steps are manual or fragile, the channel will not scale.

## 5. Product Surfaces We Need

There are four product surfaces that matter.

### A. End-user app

Used by the client-company user.

Needs to do:

- accept company link/code
- verify access
- complete OTP
- attach user to organization
- begin using calling features

### B. Vicall admin console

Used internally by Vicall.

Needs to do:

- create MSPs
- create companies
- create/revoke codes
- inspect active seats
- inspect billing state
- trigger invoicing
- inspect support/anomaly issues

### C. MSP portal

Used by the MSP.

Needs to do:

- see all their companies
- see active seats per company
- see recent joins
- download CSVs
- see billing totals and invoice status
- manage payment method via Stripe portal

### D. Billing engine

Internal system layer.

Needs to do:

- count active seats
- snapshot monthly usage
- create one invoice per MSP
- group invoice lines by company
- update local billing state from Stripe webhooks

## 6. Technical Phases

## Phase 1: 0 to 1,000 seats

Target:

- prove that MSP rollout works operationally
- keep support low-touch
- keep billing readable

### Must-have deliverables

1. Org-backed access-code onboarding
2. Membership creation after OTP verify
3. Admin provisioning endpoints
4. Admin summary dashboard
5. MSP summary dashboard
6. Stripe customer attachment
7. Monthly billing preview
8. Monthly invoice run
9. CSV export by company and by user

### What is already done

- org/MSP-aware access validation
- grant-token onboarding bridge
- membership activation
- admin overview endpoint
- MSP summary endpoint
- monthly billing snapshot logic
- company-level invoice line model

### What still needs to be built for Phase 1

#### 1. Stripe live secrets and webhooks

Required Fly secrets:

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`

Needed so:

- Stripe customer creation works
- invoice creation works
- billing status sync works

#### 2. Active/inactive seat rules

We need a formal billable seat policy.

Recommended v1:

- seat becomes active at successful OTP verify
- seat remains active until explicitly deactivated
- optional future rule: deactivate if account removed or inactive for N days

For v1, do not overcomplicate.

Ship:

- `active`
- `inactive`
- manual deactivation support

#### 3. CSV exports

MSPs need:

- company seat export
- user seat export

CSV by company:

- organization name
- active seats
- new seats this month
- last activity
- projected monthly amount

CSV by user:

- organization
- phone number
- user_id
- status
- first verified
- last verified

#### 4. Minimal admin UI

At minimum, build a simple internal admin page or lightweight dashboard that can:

- create MSP
- create organization
- create access code
- view overview
- run billing preview
- run invoice

Can be ugly. Must be reliable.

#### 5. Minimal MSP portal

At minimum, build a simple portal that reads:

- `/portal/summary`
- Stripe customer portal session

v1 is fine as a thin authenticated web app.

### Phase 1 sellability checkpoint

Vicall is sellable to early MSPs when:

- an MSP can roll out 1 to 10 client companies
- each company can onboard users with only link + code
- seat counts are visible
- invoice is generated monthly and matches company rollups
- support requests are low enough that manual intervention is rare

## Phase 2: 1,000 to 10,000 seats

Target:

- make billing and support operationally efficient
- move humans up to company/MSP rollups instead of user-level management

### Must-have deliverables

1. Monthly seat snapshot job
2. Anomaly dashboard
3. Failed-payment handling
4. Bulk provisioning tools
5. Better MSP filters/search
6. Company lifecycle states
7. Code rotation / revocation tooling
8. Basic audit log

### Build next

#### 1. Monthly seat snapshot job

Purpose:

- freeze billable seat counts at invoice time
- avoid invoice drift if users churn mid-cycle

Recommended implementation:

- scheduled job on first day of month
- compute active seats per organization
- write `organization_usage_monthly`
- create invoice line candidates

#### 2. Failed-payment / anomaly dashboard

Vicall admin should be able to answer:

- which MSPs have failed invoices
- which companies had unusual seat spikes
- which orgs had sudden churn
- which codes are seeing abuse

Minimum anomaly rules:

- seat growth > threshold week-over-week
- repeated failed payment events
- too many code validation attempts from one source
- org with high signup but zero usage

#### 3. Bulk company provisioning

At scale, MSP onboarding should support:

- create 20 companies in one import
- bulk generate codes
- bulk export rollout kit

#### 4. Audit log

Need a durable record of:

- who created MSP
- who created org
- who created/revoked code
- who ran billing
- which invoice was created

### Phase 2 sellability checkpoint

Vicall is ready for sustained MSP channel growth when:

- one internal operator can manage dozens of MSPs
- one MSP can manage dozens of companies from one portal
- invoices no longer require manual reconciliation
- anomalies are surfaced automatically instead of discovered by support tickets

## 7. Exact System Flows

## A. MSP onboarding flow

1. Vicall creates MSP record.
2. Vicall creates Stripe customer for MSP.
3. Vicall gives MSP portal access.
4. Vicall creates company records for the MSP’s client list.
5. Vicall creates one code/link per company.

## B. Client rollout flow

1. MSP sends client users:
   - app link
   - company code
2. User installs app.
3. User enters code.
4. App validates code and receives org/MSP context.
5. User enters phone number.
6. OTP request is proxied through access-grant flow.
7. User verifies OTP.
8. Membership is activated under the right company.

## C. Billing flow

1. Count active seats by organization.
2. Group organizations by MSP.
3. Create one invoice item per organization.
4. Create one invoice per MSP.
5. Stripe webhook updates billing status.
6. MSP sees totals in portal.

## 8. What the First 10,000 Seats Should Look Like

Humans should not manage 10,000 seat rows directly.

Instead:

- raw truth lives at membership level
- MSPs manage companies
- Vicall manages MSP rollups

At 10,000 seats, the operating surface should look like:

- `50-150` MSPs
- `500-2,000` companies
- `10,000` memberships
- one invoice per MSP
- company-level invoice lines

### Rule

At scale:

- users are data
- companies are management units
- MSPs are billing units

That is the only sane way to run this.

## 9. Recommended Dashboard Fields

## Vicall admin dashboard

- MSP name
- number of companies
- active seats
- seats added this month
- seats removed this month
- invoice status
- total billed this month
- failed payment flag
- anomaly flag

## MSP dashboard

- company name
- active seats
- new joins
- last activity
- projected bill
- invoice history
- payment method status

## Company drill-down

- phone number
- user ID
- first verified
- last verified
- membership status
- access code used

## 10. Technical Priorities In Order

### Immediate

1. Set Stripe secrets on Fly
2. Attach Stripe customer to MSP 1
3. Add signed app build with new org-aware onboarding
4. Test real signup -> membership creation -> seat count increment

### Next

5. CSV export endpoints
6. minimal internal admin UI
7. minimal MSP portal UI
8. monthly billing run job

### After that

9. seat inactivity rules
10. anomaly dashboard
11. audit log
12. bulk MSP/company provisioning

## 11. Technical Risks

### Risk 1: Two auth paths

The access-grant org flow now exists in the Twilio/Fly service, but the main backend still has direct OTP endpoints.

Short-term:

- acceptable for rollout

Long-term:

- move org-aware access enforcement fully into the main backend

### Risk 2: Manual UI gap

The API/control plane is now ahead of the human-facing admin UX.

Meaning:

- operations are possible now
- but not yet friendly at scale

### Risk 3: Billing policy ambiguity

If “active seat” is not clearly defined, invoice disputes will happen.

Need one explicit policy before live billing begins.

## 12. Definition of Done for “Ready to Sell to MSPs”

Vicall is ready to sell through MSPs when:

- MSP can be provisioned in under 10 minutes
- a client company can be provisioned in under 2 minutes
- a user can self-onboard with link + code only
- seat count appears automatically
- monthly invoice is generated automatically
- MSP can see client company rollups without Vicall support
- Vicall can monitor payment failures and seat anomalies centrally

## 13. Short Version

To make Vicall a real channel product:

- use MSPs as billing units
- use companies as rollout units
- use memberships as the seat ledger
- use Stripe only for charging
- use Vicall’s control plane for org assignment, monitoring, and seat math

That is the path from “working app” to “sellable MSP product.”
