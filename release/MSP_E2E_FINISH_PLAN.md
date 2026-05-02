# Vicall MSP End-to-End Finish Plan

Last updated: April 25, 2026

## Purpose

This is the execution plan to finish the MSP product across:

- the Vicall admin surface
- the MSP portal
- the Twilio/Fly control plane
- the main Vicall backend
- the iOS app
- Stripe billing and invoice state

The target outcome is simple:

Vicall can provision MSPs, MSPs can provision client companies, employees can self-onboard through the app, seats can be tracked correctly, and both Vicall and the MSP can manage billing from a single source of truth.

## Current Baseline

The current system already has important pieces in place:

- the Twilio/Fly service owns MSP, organization, access-code, membership, usage, and billing-run tables
- the iOS app already validates company access codes and can proxy OTP through the Twilio/Fly service with an access grant token
- the MSP portal already supports login, company creation, access-code issuance, offboarding, billing preview, and Stripe customer-portal launch
- Stripe invoice scaffolding and webhook handling already exist

Primary references:

- [MSP Documentation Index](</Users/reeceway/Desktop/vericall voiceprints/vericall/release/MSP_DOCUMENTATION_INDEX.md>)
- [MSP Channel Technical Plan](</Users/reeceway/Desktop/vericall voiceprints/vericall/release/MSP_CHANNEL_TECHNICAL_PLAN.md>)
- [MSP Billing Production Setup](</Users/reeceway/Desktop/vericall voiceprints/vericall/MSP_BILLING_PRODUCTION_SETUP.md>)
- [MSP Portal Phase 2 Plan](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/MSP_PORTAL_PHASE2_PLAN.md>)
- [MSP Portal Institutional Hardening Plan](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/MSP_PORTAL_INSTITUTIONAL_HARDENING_PLAN.md>)
- [Twilio control-plane app](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py>)
- [Control-plane persistence layer](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/control_plane.py>)
- [iOS AuthService](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/AuthService.swift>)
- [iOS APIService](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/APIService.swift>)

## Final System Shape

Before building more features, the team needs one unambiguous truth model.

### System of Record

- identity, refresh tokens, contacts, and device-auth basics stay in the main Vicall backend
- MSPs, companies, access codes, memberships, seat state, usage rollups, and billing runs stay in the Twilio/Fly control plane
- Stripe remains the external billing ledger, but local billing state must still be persisted for reporting, support, and dispute resolution

### Canonical Business Objects

- one MSP = one billing customer
- one MSP = one Stripe customer
- one company = one `organization`
- one onboarding code/link = one `organization_access_code`
- one installed and verified employee under a company = one `organization_membership`
- one active or billable membership = one seat recordable for billing

### Canonical Journeys

1. Vicall provisions an MSP
2. MSP owner signs in and completes billing setup
3. MSP creates one or more client companies
4. MSP issues access code or invite link
5. employee installs the app, validates code, completes OTP, and joins the correct company
6. membership becomes active and visible in the MSP portal and Vicall admin views
7. monthly billing rolls all company seats into one MSP invoice with local snapshots
8. offboarding, company shutdown, payment failure, and support actions remain auditable

## Non-Negotiable Release Gates

These gates must be closed before broad MSP launch.

### Gate A: Trust and Security

- no shared MSP portal key used as human login
- no secrets or live login links rendered into HTML
- OTP and magic-link flows enforce rate limits, cooldowns, and expiry
- portal actions are tied to normal sessions and RBAC

### Gate B: Correct Seat Tracking

- onboarding creates or refreshes the right membership
- offboarding only affects the selected company
- rejoin works intentionally
- seat counts, active seats, and billable seats mean the same thing in portal, export, preview, and invoice logic

### Gate C: Billing Credibility

- Stripe customer creation, payment-method capture, invoice creation, and webhook reconciliation all work in production
- payment state is visible to Vicall and to the MSP
- support can explain every invoice from local records

### Gate D: Release Confidence

- end-to-end tests cover the real onboarding and portal flow
- the same supported Python version is used locally and in CI
- there is a repeatable staging or test-account flow for MSP provisioning, onboarding, and billing

## Delivery Method

Every workstream below follows the same loop:

1. Understand
2. Research
3. Code
4. Test
5. Fix
6. Re-test
7. Move to the next dependency

That sounds obvious, but it matters here because this system crosses app, backend, portal, and Stripe boundaries. We do not want "backend done" while app onboarding still points at the old flow or while Stripe events do not reconcile back into local state.

## Workstream 0: Architecture Freeze and Truth Model

### Goal

Lock the system boundaries before changing behavior.

### Understand

- map every auth, onboarding, membership, and billing call across the app, main backend, Twilio/Fly service, and Stripe
- confirm which routes are live and which are legacy fallback

### Research

- trace the app flow from [Constants.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/App/Constants.swift>) through [APIService.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/APIService.swift>) and [AuthService.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/AuthService.swift>)
- trace the org-aware onboarding flow in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py:1551>)
- trace billing-run and webhook state in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py:3248>)

### Code

- none until the architecture notes are agreed

### Test

- write a single flow diagram and payload table for:
  - admin provisioning
  - company creation
  - app onboarding
  - membership activation
  - invoice run
  - webhook reconciliation

### Fix

- close any mismatched field names or duplicate responsibilities before feature work continues

### Re-test

- team walkthrough: app, backend, portal, billing

### Exit Criteria

- one agreed source of truth for identity, membership, seat state, and billing state

### Next

- Workstream 1

## Workstream 1: Trust Hardening and Portal Access Model

### Goal

Make the portal safe enough to be the real MSP control plane.

### Understand

- inventory every route that still accepts portal keys or other bypass paths

### Research

- review auth entry points in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py>)
- use the existing institutional hardening plan as the checklist

### Code

- remove portal-key login fallback
- remove session creation from query-string key paths
- replace recovery with one-time recovery links or Vicall-admin recovery
- stop rendering portal keys and magic links in HTML
- add OTP attempt ceilings, resend cooldowns, challenge expiry, and explicit lockout states
- canonicalize public auth URL generation

### Test

- unit-test login challenge behavior
- browser-test login, logout, recovery, resend, and lockout flows
- negative-test expired grants, wrong codes, repeated OTP attempts, and cross-device sign-in

### Fix

- resolve any auth loops, session persistence bugs, or confusing operator messaging

### Re-test

- rerun browser and API tests with production-like cookie settings

### Exit Criteria

- no bypass auth paths remain
- owners and operators use only the intended session-based login model

### Next

- Workstream 2

## Workstream 2: Provisioning Model for Vicall and MSPs

### Goal

Finish the provisioning chain from Vicall admin -> MSP -> company -> access code.

### Understand

- identify what provisioning is already supported and what still assumes Vicall operator help

### Research

- admin provisioning flow in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py:1939>)
- MSP operator flow in [MSP_OPERATOR_FLOW.md](</Users/reeceway/Desktop/vericall voiceprints/vericall/MSP_OPERATOR_FLOW.md>)
- phase-2 self-serve direction in [MSP_PORTAL_PHASE2_PLAN.md](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/MSP_PORTAL_PHASE2_PLAN.md>)

### Code

- finish Vicall-admin provisioning so it reliably creates:
  - MSP
  - Stripe customer
  - owner user
  - first company
  - first access code
- add lifecycle state to MSPs: `pending_review`, `active`, `suspended`, `closed`
- add role model enforcement: `owner`, `billing_admin`, `operator`, `read_only`
- make company creation, access-code creation, code rotation, company deactivation, and company restore all first-class flows
- separate "future self-serve MSP signup" from "admin-provisioned MSP" so the current product is stable even before self-serve launches

### Test

- API tests for admin provisioning and company creation
- portal tests for new company, new code, deactivate company, restore company
- duplicate-email, duplicate-phone, duplicate-code, and suspended-MSP cases

### Fix

- remove any remaining flows that require raw database knowledge or hidden admin intervention

### Re-test

- run a fresh MSP creation end to end from zero state

### Exit Criteria

- Vicall can provision MSPs without touching the database manually
- MSP owners can provision companies and codes without Vicall help

### Next

- Workstream 3

## Workstream 3: App Onboarding and Membership Activation

### Goal

Make employee onboarding deterministic and company-aware every time.

### Understand

- confirm exactly when the app calls the main backend versus the Twilio/Fly proxy
- confirm how pending and active organization contexts are stored on device

### Research

- onboarding UI in [OnboardingContainerView.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Views/Onboarding/OnboardingContainerView.swift>)
- phone step in [PhoneInputView.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Views/Onboarding/PhoneInputView.swift>)
- verification step in [VerificationCodeView.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Views/Onboarding/VerificationCodeView.swift>)
- access validation and OTP proxying in [APIService.swift](</Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Services/APIService.swift>)

### Code

- make org-aware onboarding the default production path for MSP/company codes
- define the legacy-code fallback policy explicitly
- normalize phone numbers consistently across app, main backend, and control plane
- persist active organization context only after successful OTP verify
- surface clearer operator-grade app errors for:
  - invalid code
  - expired grant
  - max capacity reached
  - removed seat
  - suspended company
  - suspended MSP
- ensure invite-link handling cleanly stores company code before onboarding starts

### Test

- app integration tests for:
  - valid code + valid OTP
  - invalid code
  - expired grant
  - retry after expired grant
  - rejoin after offboarding
  - wrong-company code
- test from a clean install and from an app update

### Fix

- close any stale-context, duplicate-request, or app-state bugs

### Re-test

- physical-device test on supported iPhone and iPad targets

### Exit Criteria

- an employee can onboard into the right MSP/company without hidden operator intervention
- successful OTP always yields the correct membership state

### Next

- Workstream 4

## Workstream 4: Membership Ledger and Seat State

### Goal

Make seat state authoritative, explainable, and billable.

### Understand

- define the exact difference between:
  - validated code
  - pending grant
  - active membership
  - inactive membership
  - billable seat this month
  - active seat now

### Research

- membership activation flow in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py:1620>)
- data model and membership helpers in [control_plane.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/control_plane.py>)
- current billing language in [MSP_BILLING_PRODUCTION_SETUP.md](</Users/reeceway/Desktop/vericall voiceprints/vericall/MSP_BILLING_PRODUCTION_SETUP.md>)

### Code

- fix tenant scoping for offboarding and destructive membership actions
- define formal seat states and transitions
- store first-verified, last-verified, deactivated-at, and reactivated-at consistently
- make company deactivation expire active codes, pending grants, and active memberships correctly
- add restore/reactivate paths where needed
- align export columns and billing preview with the same seat-state definitions

### Test

- multi-company MSP tests
- offboard / rejoin tests
- company shutdown tests
- same phone in multiple companies edge-case tests if supported

### Fix

- remove any hidden coupling between membership state and UI assumptions

### Re-test

- recompute billing preview after each state transition and compare expected values

### Exit Criteria

- seat counts and billable counts are stable and explainable

### Next

- Workstream 5

## Workstream 5: Stripe Billing and Financial Reconciliation

### Goal

Finish billing so Vicall and the MSP both trust it.

### Understand

- identify what is already scaffolded versus what is still operationally manual

### Research

- Stripe setup and monthly flow in [MSP_BILLING_PRODUCTION_SETUP.md](</Users/reeceway/Desktop/vericall voiceprints/vericall/MSP_BILLING_PRODUCTION_SETUP.md>)
- invoice run and webhook handling in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py>)

### Code

- ensure production Stripe secrets are present and validated on boot
- finish Stripe customer creation and idempotent attachment
- finish customer-portal launch flow for MSP billing setup
- create reliable billing preview and monthly billing run commands
- persist richer billing-run detail locally:
  - period boundaries
  - per-company seat count
  - per-company projected amount
  - invoice id
  - invoice url if available
  - Stripe status history
- extend webhook handling beyond the minimum status map where needed
- add payment-failure and delinquency handling into MSP lifecycle state or portal warnings

### Test

- Stripe test-mode MSP walkthrough
- add payment method -> preview invoice -> run invoice -> webhook reconciliation
- payment-failure scenario
- duplicate webhook replay scenario
- billing rerun/idempotency scenario

### Fix

- remove invoice duplication risk and mismatched local-versus-Stripe status

### Re-test

- full billing dry run with at least:
  - one MSP
  - two companies
  - active seats
  - deactivated seats still billable for current month

### Exit Criteria

- monthly billing is predictable, supportable, and readable
- Vicall can answer invoice disputes from local records

### Next

- Workstream 6

## Workstream 6: MSP Portal Product Completion

### Goal

Make the portal feel like real MSP software, not an internal admin page.

### Understand

- identify all workflows still driven by raw IDs or thin forms

### Research

- dashboard and company-management rendering in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py>)
- institutional hardening and phase-2 docs

### Code

- replace raw `organization_id` entry with company pickers, search, and direct company actions
- build real company pages with:
  - access codes
  - memberships
  - recent joins
  - recent removals
  - seat summary
  - billing snapshot
  - notes or audit trail
- build real team-management pages with:
  - role editor
  - invite status
  - deactivate/reactivate
  - password reset or re-invite
  - active-session controls
- add audit-log view
- improve billing center with invoice list, payment-method status, current period, and failure notices
- standardize CSV exports for operations and finance

### Test

- browser tests across desktop and tablet widths
- task-based operator tests:
  - create company
  - issue code
  - remove employee
  - recover employee
  - review billing
  - export usage

### Fix

- clean up awkward copy, broken states, and multi-step UX friction

### Re-test

- complete a full MSP operator workflow without using any raw IDs or hidden URLs

### Exit Criteria

- a serious MSP operator can use the portal daily without Vicall hand-holding

### Next

- Workstream 7

## Workstream 7: Vicall Admin Ops and Support Surface

### Goal

Give Vicall the tooling to run the channel business safely.

### Understand

- list the support actions Vicall still performs manually

### Research

- current admin routes and dashboard in [app.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/app.py>)
- current support gaps from the audit and billing docs

### Code

- strengthen the Vicall admin dashboard for:
  - MSP provisioning
  - company creation
  - access-code management
  - billing preview and invoice run
  - MSP status change
  - support notes
  - audit inspection
- decide whether support uses:
  - a separate admin-only console
  - or a scoped support role with audit logging
- add support-safe views for:
  - current memberships
  - billing runs
  - payment failures
  - company and seat anomalies

### Test

- support runbooks:
  - recover owner access
  - answer billing dispute
  - verify company membership
  - suspend delinquent MSP

### Fix

- remove any support action that still depends on shell access or direct DB edits

### Re-test

- have someone other than the original implementer execute the runbooks

### Exit Criteria

- Vicall operations can support the MSP channel through product workflows, not heroics

### Next

- Workstream 8

## Workstream 8: Verification, CI, and Release Discipline

### Goal

Make the system releasable without breaking the channel every other deploy.

### Understand

- identify which tests are stale, missing, or dependent on the wrong runtime

### Research

- current smoke scripts in:
  - [smoke_test_msp_lifecycle.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/scripts/smoke_test_msp_lifecycle.py>)
  - [test_portal_msp_sms_lifecycle.py](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/scripts/test_portal_msp_sms_lifecycle.py>)
- runtime baseline in [Dockerfile](</Users/reeceway/Desktop/vericall voiceprints/vericall/twilio_voice_service/Dockerfile>)

### Code

- rewrite the smoke suite to match the real login and invite flow
- add API tests for provisioning, membership lifecycle, and billing
- add browser-driven portal tests
- standardize on Python 3.11 in local setup and CI
- define one bootstrap path for local dev and one for staging verification

### Test

- run:
  - unit tests
  - API tests
  - browser tests
  - Stripe test-mode flow
  - clean-install app onboarding
  - app-update onboarding

### Fix

- close environment drift, flaky tests, and stale assumptions

### Re-test

- require green end-to-end checks before MSP-impacting release

### Exit Criteria

- the team can verify provisioning, onboarding, seat tracking, and billing before every release

### Next

- launch readiness

## Recommended Build Order

### Phase 1: Stabilize the core

- Workstream 0
- Workstream 1
- Workstream 4
- Workstream 8.1 for smoke-test rewrite

Why first:

- if auth is bypassable or seat state is wrong, everything else is theater

### Phase 2: Make provisioning real

- Workstream 2
- Workstream 7

Why next:

- Vicall needs a clean operational path to create and manage MSPs before scaling portal usage

### Phase 3: Make onboarding deterministic

- Workstream 3
- Workstream 4 completion

Why next:

- seats and billing only become trustworthy once the app consistently lands users in the right company

### Phase 4: Finish billing

- Workstream 5

Why next:

- once seats are trustworthy, invoice generation and reconciliation become meaningful

### Phase 5: Finish the MSP-facing product

- Workstream 6

Why last:

- portal polish should sit on top of stable auth, stable seat state, and stable billing

## Practical Milestones

### Milestone 1: Secure core control plane

- trust hardening complete
- seat-state definitions complete
- cross-company offboarding fixed
- smoke tests updated

### Milestone 2: Provisioning and onboarding complete

- Vicall can provision MSPs
- MSPs can provision companies and access codes
- employees can onboard through the app into the right organization

### Milestone 3: Billing complete

- Stripe customer setup works
- payment methods can be managed
- monthly preview and invoice run work
- webhooks reconcile back into local state

### Milestone 4: Institutional portal complete

- RBAC enforced
- audit logs live
- team management complete
- billing center complete
- company workspace complete

## Launch Checklist

Before saying "finished," verify all of these in one fresh environment:

1. provision MSP from Vicall admin
2. create first company and first access code
3. owner signs in and adds payment method
4. MSP creates second company
5. employee A joins company 1 through the app
6. employee B joins company 2 through the app
7. seat counts appear correctly in portal and admin views
8. offboard one employee and confirm billing treatment
9. rotate or issue a new access code
10. run billing preview
11. create invoice in Stripe test mode
12. receive webhook updates locally
13. export company and user reports
14. inspect audit trail for the major actions

## Definition of Done

This product is finished when:

- Vicall can onboard and support MSPs without direct database edits
- MSPs can manage companies, users, seats, and billing through the portal
- the app always lands employees in the right company and seat state
- Stripe billing matches local billing records
- support can explain every membership and invoice event
- the release process catches regressions before users do

Until then, the honest framing is that the MSP product is functional in parts, but not yet complete end to end.
