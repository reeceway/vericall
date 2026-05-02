# Vicall MSP API and Data Contracts

Last updated: April 25, 2026

## Purpose

This document defines the contracts that the portal, app, backend, and billing logic should all agree on.

If implementation diverges from these contracts, fix the implementation or update this document intentionally. Do not let the contracts become folklore.

## Core Business Objects

### MSP

Minimum fields:

- `id`
- `name`
- `billing_email`
- `status`
- `seat_price_cents`
- `stripe_customer_id`
- `created_at`
- `updated_at`

Required `status` values:

- `pending_review`
- `active`
- `suspended`
- `closed`

### MSP User

Minimum fields:

- `id`
- `msp_id`
- `email`
- `phone_number`
- `full_name`
- `role`
- `active`
- `last_login_at`
- `created_at`
- `updated_at`

Required `role` values:

- `owner`
- `billing_admin`
- `operator`
- `read_only`

### Organization

Minimum fields:

- `id`
- `msp_id`
- `name`
- `external_ref`
- `active`
- `created_at`
- `updated_at`

### Organization Access Code

Minimum fields:

- `id`
- `organization_id`
- `code`
- `label`
- `active`
- `max_activations`
- `created_at`
- `updated_at`

### Access Grant

Purpose:

- short-lived bridge between access-code validation and OTP verification

Minimum fields:

- `token`
- `organization_id`
- `access_code_id`
- `msp_id`
- `phone_number`
- `expires_at`
- `consumed_at`

### Organization Membership

Purpose:

- authoritative record that a user/phone belongs to a company

Minimum fields:

- `id`
- `organization_id`
- `msp_id`
- `phone_number`
- `user_id`
- `status`
- `first_verified_at`
- `last_verified_at`
- `deactivated_at`
- `deactivation_reason`
- `created_at`
- `updated_at`

Required `status` values:

- `active`
- `inactive`

### Billing Run

Minimum fields:

- `id`
- `msp_id`
- `period_start`
- `period_end`
- `status`
- `stripe_invoice_id`
- `stripe_invoice_url`
- `currency`
- `seat_total_cents`
- `usage_total_cents`
- `grand_total_cents`
- `created_at`
- `updated_at`

Recommended `status` values:

- `draft`
- `finalized`
- `paid`
- `payment_failed`
- `void`

## Seat Contract

### What Counts as a Seat

- a seat is created or refreshed only after successful OTP verification through a valid organization-backed flow
- a valid access code alone is not a seat
- a removed employee can become a seat again by rejoining intentionally

### Required Seat Metrics

The portal, exports, and billing logic must all expose the same meanings:

- `active_seats_now`: memberships currently active at this moment
- `new_seats_this_period`: memberships first activated during the current billing window
- `billable_seats_this_period`: seats that should appear on the current invoice based on policy
- `removed_seats_this_period`: seats deactivated during the current billing window

## Endpoint Contracts

### Employee Onboarding

#### `POST /access/validate`

Owned by:

- Twilio/Fly control plane

Request:

- `code`
- `phone_number` optional

Success response:

- `valid`
- `message`
- `organization_id`
- `organization_name`
- `msp_id`
- `msp_name`
- `access_code_id`
- `grant_token`
- `seat_price_cents` optional

Failure classes:

- `400` missing or malformed code
- `403` invalid code
- `409` capacity limit or code rule conflict
- `503` validation not configured

#### `POST /access/request-otp`

Owned by:

- Twilio/Fly control plane

Request:

- `phone_number`
- `access_grant_token`

Success response:

- proxy success payload from the main Vicall backend

Failure classes:

- `403` invalid or expired grant
- `429` rate limited

#### `POST /access/verify-otp`

Owned by:

- Twilio/Fly control plane

Request:

- `phone_number`
- `otp`
- `public_key`
- `access_grant_token`

Success response:

- main auth payload
- `organization_id`
- `organization_name`
- `msp_id`
- `msp_name`

Side effects:

- create or refresh `organization_membership`
- consume access grant

Failure classes:

- `400` invalid payload
- `403` invalid or expired grant
- `409` membership activation conflict

### Admin Provisioning

#### `POST /admin/msps`

Creates:

- MSP
- optional owner linkage data

Follow-on behavior:

- Stripe customer creation or attachment

#### `POST /admin/organizations`

Creates:

- organization under existing MSP

#### `POST /admin/access-codes`

Creates:

- organization-backed access code

### Portal Billing

#### `POST /portal/customer-portal-session`

Purpose:

- launch Stripe customer portal for payment-method and invoice operations

#### `POST /stripe/webhook`

Purpose:

- reconcile Stripe invoice state into local `billing_runs`

Minimum handled events:

- `invoice.finalized`
- `invoice.paid`
- `invoice.payment_failed`

Recommended expansion:

- `invoice.voided`
- `customer.subscription.updated` only if subscriptions are introduced later

## RBAC Contract

### Owner

Can:

- manage billing
- manage MSP team
- manage companies
- export data
- suspend or close internal access where allowed

### Billing Admin

Can:

- manage billing center
- inspect seat and usage data
- export billing-related data

Cannot:

- remove owner
- rotate security-sensitive settings
- deactivate MSP team arbitrarily unless explicitly allowed

### Operator

Can:

- create companies
- issue access codes
- onboard and offboard seats
- inspect operational reporting

Cannot:

- manage Stripe
- change ownership
- perform account recovery for owners

### Read Only

Can:

- view portal data
- export if explicitly allowed

Cannot:

- mutate customer, billing, or team state

## Audit Contract

Every one of these actions must create an audit event:

- MSP created
- MSP activated
- MSP suspended
- login success
- login failure
- OTP send
- OTP failure
- company created
- company deactivated
- access code created
- access code deactivated
- membership activated
- membership deactivated
- team user invited
- team role changed
- billing run created
- billing portal opened
- invoice status updated from webhook

## Idempotency Rules

- Stripe customer attachment must be idempotent per MSP
- invoice creation must not create duplicates for the same MSP and billing window
- webhook replay must not create new billing runs
- membership activation should refresh the existing record when the same user rejoins the same company intentionally

## Error-Handling Rules

- do not leak raw secrets or magic links in user-visible error pages
- return actionable errors for:
  - suspended MSP
  - suspended company
  - capacity reached
  - expired access grant
  - payment failure blocking provisioning if policy requires it

## Contract Change Process

Whenever an endpoint payload, seat-state rule, or billing status model changes:

1. update this document
2. update the app/client models
3. update tests
4. update portal/operator docs if the change is user-visible
