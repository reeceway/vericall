# Vicall MSP Operations Runbook

Last updated: April 26, 2026

## Purpose

This runbook is for Vicall operators and, where noted, MSP owners.

It answers the practical question: once the product is live, how do we run it without improvising every time?

## Environments

### Development

Use for:

- local engineering
- feature verification
- non-billable smoke tests

### Staging or Test MSP Environment

Use for:

- full onboarding rehearsals
- Stripe test-mode billing validation
- regression testing before release

### Production

Use for:

- real MSP provisioning
- real billing
- incident response

## Preflight Checklist for Production

Before onboarding a real MSP, confirm:

- admin key is present
- Stripe live secrets are present
- Stripe webhook secret is present
- portal auth hardening changes are deployed
- smoke tests are green
- audit logging is working

## Vicall Admin Workflow

### 1. Provision a New MSP

Required data:

- MSP legal or display name
- billing email
- owner full name
- owner email
- owner phone
- seat price
- first company name
- optional external reference

Expected result:

- MSP record created
- Stripe customer created or attached
- owner user created
- first organization created
- first access code created

After provisioning:

- confirm owner can sign in through the normal portal flow
- confirm the Stripe customer id is persisted
- confirm first company appears in MSP dashboard
- confirm the MSP status is correct for rollout (`active` vs `pending_review`)

### 2. Activate or Suspend an MSP

Use cases:

- onboarding review
- delinquency
- abuse
- contract termination

Rules:

- `pending_review`: can complete setup but cannot issue production access codes
- `active`: full MSP operation
- `suspended`: read access to billing and history, no new provisioning
- `closed`: retained for records, no new activity

Portal role model:

- `owner`: full portal access, user management, billing, provisioning
- `billing_admin`: billing portal and reporting access, no provisioning or team management
- `operator`: company, seat, and access-code operations, no billing portal or team management
- `read_only`: dashboard and export access only

Audit expectation:

- operator-visible actions should appear in the MSP audit log without manual database inspection

### 3. Create Additional Companies

Required data:

- MSP id
- company name
- optional external reference

Expected result:

- organization created under the correct MSP
- company visible immediately to MSP owner/operators

### 4. Issue or Rotate Access Codes

Use cases:

- new office rollout
- new hire wave
- replace compromised or stale code

Rules:

- code count does not create billing by itself
- billing is based on active and billable seats, not number of codes
- each company includes 450 minutes per billable seat each billing period
- usage above that company allowance is billed at $0.01 per minute

### 5. Support Employee Onboarding Issues

Common checks:

- was the code valid
- did the code belong to the intended company
- did OTP verify successfully
- was the membership created or refreshed
- did the seat invoice create or reuse the existing invoice for this period
- is the company active
- is the MSP active

Preferred outcome:

- solve through product state, not database edits

## MSP Owner Workflow

### 1. Complete Billing Setup

Expected action:

- sign in
- open billing center
- open Stripe billing portal
- add payment method

Expected result:

- billing center shows payment-method presence
- billing center shows current period, immediate seat invoices, invoice history, company rollups, and top user usage
- future invoice collection is possible

### 2. Add a Company

Expected action:

- create company from the portal

Expected result:

- company workspace exists
- initial access code or code creation path is available

### 3. Invite Employees

Expected action:

- send access code or invite link to employee

Employee then:

- installs the app
- enters code or opens link
- requests OTP
- verifies OTP
- completes profile setup

### 4. Remove or Restore an Employee

Expected result of removal:

- access ends immediately
- billing treatment follows the current billing policy

Expected result of restore:

- employee rejoins through normal onboarding path
- membership is reactivated intentionally

### 5. Review Billing

Expected views:

- active seats now
- billable seats this period
- immediate seat invoices and payment-required seats
- included minutes, overage minutes, and overage charges
- company-level rollup
- invoice status
- payment-method state

## Support Runbooks

### Owner Cannot Sign In

Check:

- MSP status
- owner user active flag
- phone number normalization
- OTP delivery
- recent login failures

Do not:

- send shared portal keys
- expose live login links in browser responses

Use:

- approved recovery workflow only

### Employee Joined Wrong Company

Check:

- access code used
- grant token context
- membership organization id

Fix path:

- deactivate the incorrect membership
- have user re-onboard with the correct code

### Billing Dispute

Gather:

- MSP id
- billing run id
- Stripe invoice id
- local seat snapshot
- company-level line items
- audit trail of seat changes during the period

Goal:

- answer from product records first

### Payment Failure

Check:

- Stripe invoice status
- payment-method presence
- recent webhook events
- MSP lifecycle state

Actions:

- notify MSP owner
- direct them to billing portal
- suspend new provisioning only if policy requires it

## Incident Classes

### P1

- auth bypass
- cross-company membership corruption
- incorrect invoice creation
- live onboarding outage

### P2

- portal action broken for a non-destructive workflow
- incorrect dashboard numbers with correct billing underneath
- delayed webhook reconciliation

### P3

- export formatting issue
- copy or UI friction
- stale non-critical reporting view

## Operational Principles

- do not fix customer issues with direct database edits unless there is a declared incident and an approved repair procedure
- do not bypass the normal portal login model for convenience
- if Stripe and local records disagree, pause and reconcile before sending finance guidance
- if portal numbers and invoice numbers disagree, trust neither until the billing run snapshot is checked

## Handoff Requirements

When handing an MSP issue between engineering, support, or finance, include:

- MSP id
- organization id if relevant
- phone number or user id if relevant
- billing period if relevant
- invoice id if relevant
- exact symptom
- last known successful action
