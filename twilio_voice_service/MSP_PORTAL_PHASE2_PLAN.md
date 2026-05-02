# Vicall MSP Portal Phase 2 Plan

This document defines the next product and backend layer on top of the live MSP portal now running on `vericall-twilio-voice`.

For the prioritized hardening and readiness backlog that came out of the production audit, see `MSP_PORTAL_INSTITUTIONAL_HARDENING_PLAN.md`.

The current production baseline is:

- MSP login is live as a 3-step flow:
  1. email + password
  2. phone confirmation
  3. SMS code
- MSP dashboard already supports:
  - grouped companies
  - access code creation
  - seat onboarding and offboarding through company memberships
  - grouped monthly billing
  - Stripe customer portal access
- Apple account deletion is already hosted through the same Fly app

The next stage is to make this feel like an institutional-grade MSP control plane instead of an admin-assisted portal.

## Goals

- Let new MSPs sign up without a Vicall operator touching the database first.
- Keep billing and reseller activation controlled so random signups do not immediately become active distributors.
- Support multiple operator roles inside one MSP.
- Add a real audit trail for sign-in, provisioning, company changes, seat changes, and billing actions.
- Keep the iOS app decoupled from these portal changes.

## Product Model

The portal should support two MSP entry paths.

### 1. Admin-Provisioned MSP

Use this for direct sales, pilots, referrals, and strategic channel partners.

Flow:

1. Vicall admin provisions the MSP.
2. Vicall sets:
   - MSP name
   - billing email
   - owner email
   - owner phone
   - initial password
   - initial company
   - first access code
3. MSP owner logs in through the 3-step flow.
4. MSP manages client companies and seats immediately.

This is the fastest path for onboarding real revenue accounts.

### 2. Self-Serve MSP Signup

Use this for inbound MSP interest and lighter-touch onboarding.

Flow:

1. MSP visits `/portal/signup`.
2. MSP submits:
   - legal company name
   - display name
   - billing email
   - owner full name
   - owner email
   - owner phone
   - password
   - optional website / PSA reference
3. System verifies:
   - owner email
   - owner phone
4. System creates Stripe customer and collects a payment method.
5. Account is created in `pending_review` or `trial`.
6. Vicall reviews and activates the MSP.
7. Only active MSPs can create client companies and issue production access codes.

Recommendation:

- Default self-serve accounts to `pending_review`.
- Only allow full reseller actions after review or after a clear automated approval policy.

## Required New MSP States

Add an MSP lifecycle status field. Suggested values:

- `pending_review`
- `active`
- `suspended`
- `closed`

Behavior:

- `pending_review`: can finish onboarding, billing setup, and owner login, but cannot issue production client access codes yet.
- `active`: full portal rights.
- `suspended`: read access to billing and history, but no new provisioning actions.
- `closed`: no new activity; retained for records.

## Role Model

Current `msp_users.role` is too simple for a larger MSP operation. Suggested role set:

- `owner`
  - full control
  - can manage billing
  - can create and deactivate companies
  - can create and deactivate team users
  - can export data
- `billing_admin`
  - billing portal
  - invoices
  - seat and usage visibility
  - cannot delete MSP or remove owner
- `operator`
  - create companies
  - issue access codes
  - onboard and offboard seats
  - cannot manage Stripe or ownership
- `read_only`
  - dashboard and reporting only
  - no mutations
- `vicall_support`
  - optional internal support role if support access is ever exposed through the same portal

Recommendation:

- Every MSP must have exactly one active `owner`.
- First self-serve or admin-provisioned user becomes `owner`.
- Later invites can choose `billing_admin`, `operator`, or `read_only`.

## Audit Log Plan

Add an append-only `msp_audit_events` table.

Suggested schema:

- `id`
- `msp_id`
- `actor_type`
  - `msp_user`
  - `vicall_admin`
  - `system`
- `actor_id`
- `actor_email`
- `action`
- `target_type`
  - `msp`
  - `organization`
  - `access_code`
  - `membership`
  - `billing_run`
  - `msp_user`
  - `auth_session`
- `target_id`
- `ip_address`
- `user_agent`
- `metadata_json`
- `created_at`

High-value events to log:

- MSP signup started
- MSP signup email verified
- MSP signup phone verified
- MSP activated
- MSP suspended
- owner login success
- login failure
- OTP send
- OTP verify failure
- company created
- company deactivated
- access code created
- membership activated
- membership deactivated
- team user invited
- team user role changed
- billing run created
- Stripe customer linked
- billing portal opened

Why this matters:

- operator accountability
- support debugging
- billing dispute investigation
- channel partner compliance

## Self-Serve Signup Flow

The cleanest production-grade signup is a staged flow.

### Step 1: Company Basics

Route:

- `GET /portal/signup`
- `POST /portal/signup/start`

Fields:

- MSP legal name
- MSP display name
- billing email
- website
- optional PSA / CRM reference

### Step 2: Owner Identity

Route:

- `GET /portal/signup/owner`
- `POST /portal/signup/owner`

Fields:

- owner full name
- owner email
- owner phone
- password

### Step 3: Verify Email

Route:

- `GET /portal/signup/verify-email`
- `POST /portal/signup/verify-email`

### Step 4: Verify Phone

Route:

- `GET /portal/signup/verify-phone`
- `POST /portal/signup/verify-phone`

### Step 5: Billing Setup

Route:

- `GET /portal/signup/billing`
- `POST /portal/signup/billing`

Actions:

- create Stripe customer
- collect default payment method
- optionally show seat price and terms

### Step 6: Review / Activation

Route:

- `GET /portal/signup/complete`

Behavior:

- if auto-approved, activate immediately
- if manual review, show:
  - account received
  - billing is attached
  - Vicall will activate reseller access shortly

## Data Model Changes Recommended

### `msps`

Add:

- `status TEXT NOT NULL DEFAULT 'active'`
- `website TEXT`
- `external_ref TEXT`
- `billing_contact_name TEXT`
- `activated_at TEXT`
- `suspended_at TEXT`
- `closed_at TEXT`

### `msp_users`

Keep current table and expand role usage.

Possible additions:

- `invited_at TEXT`
- `accepted_at TEXT`
- `last_mfa_verified_at TEXT`

### New `msp_signup_requests`

Use this if you want a clean staging area before the real MSP record is activated.

Suggested fields:

- `id`
- `status`
- `msp_name`
- `billing_email`
- `website`
- `owner_full_name`
- `owner_email`
- `owner_phone`
- `password_hash`
- `stripe_customer_id`
- `email_verified_at`
- `phone_verified_at`
- `submitted_at`
- `reviewed_at`
- `reviewed_by`

This keeps incomplete signups out of the live MSP tables.

## Access and Billing Rules

These should stay true in both admin-provisioned and self-serve flows.

- Seats are derived from active employee memberships.
- When a company adds a seat through onboarding, that seat becomes billable to the MSP.
- When a company deletes a seat, the seat stops being active immediately.
- The seat remains billable through the current billing period if that is the pricing rule already in force.
- The MSP receives one grouped monthly invoice across all active client companies.
- The MSP must have a Stripe customer and default payment method for auto-collection to work.

## Live MSP Test Account Plan

For the first live production MSP test, do not use self-serve yet. Use admin provisioning first.

Recommended flow:

1. Provision one real MSP via `/admin/provision-msp`.
2. Set:
   - MSP name
   - billing email
   - owner full name
   - owner email
   - owner phone
   - temporary password
   - first company
3. Confirm Stripe customer exists.
4. Confirm login works on:
   - `/portal/login`
   - `/portal/login/phone`
   - `/portal/login/code`
5. Inside the live dashboard:
   - create a second company
   - create another access code
   - onboard at least one seat in each company
   - remove one seat
   - verify grouped billing preview
   - open Stripe billing portal

This gives the fastest real-world proof without waiting on the self-serve build.

## Recommended Implementation Order

### Phase 2A

- add MSP status model
- add role enforcement helpers
- add audit log table and write hooks
- add audit views to admin and MSP portal

### Phase 2B

- add self-serve signup request table
- add email verification flow
- add phone verification flow
- add Stripe billing attach step
- add activation review workflow

### Phase 2C

- polish UI for client-facing MSPs
- add invite acceptance flow for MSP team users
- add session management and device/session history
- add operator lockout and rate limiting around sign-in events

## Recommendation For Right Now

Do the next live test this way:

1. admin-provision one real MSP
2. validate the live 3-step login
3. validate grouped company and seat billing behavior
4. only then build self-serve signup on top of that proven path

That keeps revenue onboarding stable while we build the more polished self-serve layer.
