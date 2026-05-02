# Vicall MSP Operator Flow

This is the simplest supported operator path for provisioning and offboarding.

## 1. Admin Provision a New MSP

Use the admin dashboard:

- `https://vericall-twilio-voice.fly.dev/admin/dashboard?key=<admin-key>`

Fill in:

- MSP name
- MSP status (`active` for live rollout, `pending_review` for setup-first onboarding)
- Billing email
- Portal owner name
- Portal owner email
- Portal owner phone
- Optional initial portal owner password
- First company name
- Optional external reference
- Seat price

That one action creates:

- the MSP
- the first company
- the first company access code
- the Stripe customer for monthly billing
- the first MSP portal owner login and a one-time password setup link

Passwords are not displayed after provisioning. If an initial password is submitted, it is stored but not shown. If no password is submitted, send the one-time setup link to the MSP owner.

## MSP Login

MSPs sign in at:

- `https://vericall-twilio-voice.fly.dev/portal/login`

Supported login paths:

- one-time setup link for new MSP portal users
- direct email/password login for an existing MSP portal user

Once signed in, the portal stores a secure session cookie in the browser.

## 2. Add a New Company

Use the MSP portal:

- `https://vericall-twilio-voice.fly.dev/portal/dashboard`

Use `Add Company`.

The result page gives the MSP:

- organization ID
- access code
- a ready-to-send employee invite message

Lifecycle rule:

- `pending_review` MSPs can add and edit company records, but cannot issue production access codes until Vicall activates the MSP

## Billing Center

Use:

- `https://vericall-twilio-voice.fly.dev/portal/billing`

What it shows:

- current-period projected bill
- invoice timeline by period
- company-level billing rollup
- user-level usage rollup
- Stripe payment-method readiness

Role rules:

- `owner`, `billing_admin`, and `read_only` can view the billing center
- only `owner` and `billing_admin` can open the Stripe billing portal

## 3. Issue Another Access Code for an Existing Company

Use `Issue Access Code` in the MSP portal.

Use this when:

- a second office needs its own onboarding code
- a team lead needs a fresh code for a new hire wave
- you want a replacement code without changing the company record

Creating more access codes does not change billing by itself. Billing is based on active and billable seats, not on number of codes.

## 4. MSP Team Access

Use `Create MSP User` in the MSP portal.

That creates another MSP portal user under the same MSP and returns a one-time password setup link. Optional initial passwords are accepted for controlled rollout, but are never displayed in the portal response.

All team members share the same MSP-level billing rollup and company management view.

Supported roles:

- `owner`: full portal access, team management, billing, provisioning
- `billing_admin`: billing and reporting access, no provisioning or team management
- `operator`: company, seat, and access-code management, no Stripe billing or team management
- `read_only`: dashboard and reporting access only

## 5. Add a New Employee

The employee opens the app and enters the company access code.

Then they:

- request OTP
- verify OTP
- finish onboarding

If the employee was previously removed, onboarding again with a valid company code reactivates access.

## 6. Remove an Employee

Use `Offboard Employee` in the MSP portal.

Effect:

- access ends immediately
- the seat remains billable through the current month only
- the employee can rejoin later with a valid company access code

## 7. Remove a Company

Use `Offboard Company` in the MSP portal.

Effect:

- the company is disabled
- active access codes are disabled
- pending access grants are expired
- employee access ends immediately
- seats already used this month remain billable through the current month only

## Billing Behavior

- Seat price is stored on the MSP
- New MSPs default to `$20.00` per customer-company seat
- Billing is monthly to the MSP's Stripe customer
- All companies under the MSP roll into one MSP invoice
- The MSP's own firm is non-billable
- The dashboard shows both company-level seat counts and the one MSP-level projected total
- Each employee phone number activated under a customer company becomes a billable seat for that company
- Customer-company seats and active access-code cohorts roll up into the MSP invoice
- Each customer company includes `450` minutes per billable seat
- Overage is `$0.001` per minute after the company allowance, rounded at the company invoice line because Stripe bills whole cents
- Billing preview tracks both:
  - active seats now
  - billable seats this month
- Offboarded employees and companies still appear in the current-month billing preview if they generated billable usage earlier in the month
- MSPs should add a payment method in Stripe before the first month closes so invoice collection can run automatically
- only `owner` and `billing_admin` users can open the Stripe billing portal
- Vicall admins run manual monthly billing by selecting an explicit billing period in the admin dashboard

## Lifecycle Behavior

- `active`: full MSP operation
- `pending_review`: setup and billing allowed, production access-code use blocked
- `suspended`: dashboard, exports, and billing remain visible, but provisioning and seat changes are blocked

## Audit Log

Use:

- `https://vericall-twilio-voice.fly.dev/portal/audit`

The audit log records:

- sign-in and logout events
- company and access-code changes
- employee and company offboarding
- MSP team-user changes
- exports
- billing portal launches and local billing runs

## Repeatable Smoke Test

Run:

```bash
python3.11 /Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/scripts/smoke_test_msp_lifecycle.py \
  --admin-key '<admin-key>' \
  --owner-phone '+14155550123' \
  --otp-code '123456'
```

That script verifies:

- new MSP provisioning
- real 3-step MSP portal login
- Stripe customer attachment
- new company creation
- additional access code creation for an existing company
- employee onboarding activation
- employee offboarding
- employee rejoin
- company offboarding
- billing preview behavior before and after offboarding
