# Vicall MSP Portal Institutional Hardening Plan

Last updated: May 1, 2026

## Purpose

This document turns the MSP portal audit into an execution plan.

The goal is not just to make the portal "work." The goal is to make it trustworthy, supportable, and operationally credible for real MSPs that expect software to behave like a large-business platform.

Today, the portal is best understood as an admin-assisted control plane. Before broad MSP rollout, it needs stronger trust boundaries, safer tenant operations, clearer operator workflows, and better release confidence.

## What "Institutional" Means Here

For Vicall to feel institutional to an MSP, the portal must meet all of these standards:

- no shared-secret shortcuts that bypass the normal login model
- no ambiguous operator authority; billing, support, and provisioning permissions are separated
- all destructive and billing-relevant actions are auditable
- tenant actions are scoped correctly and cannot spill across customer companies
- billing, customer, and team workflows can be completed without copying internal IDs around
- support and engineering can reproduce, test, and release changes confidently

## Release Gates

Do not market this as a broad MSP-ready channel product until Gate 1 and Gate 2 are complete.

### Gate 1: Trust Gate

- portal API keys are no longer valid as human login credentials
- portal secrets are never rendered in browser pages
- OTP and magic-link flows have rate limits, attempt ceilings, and safe fallback behavior
- sign-in links are generated from a canonical public base URL

### Gate 2: Governance Gate

- MSP lifecycle states exist and are enforced
- role-based access control is enforced on all portal mutations
- audit logs exist for sign-in, provisioning, company changes, team actions, exports, and billing actions

### Gate 3: Operator Gate

- company and team actions are driven by customer objects, not raw IDs
- billing and reporting views are understandable without internal help
- common support workflows exist: invite, deactivate, restore, suspend, rotate, export

### Gate 4: Release Gate

- smoke and end-to-end tests match the real auth flow
- local and CI environments use the same supported Python version
- critical MSP flows are exercised before release

### Gate 5: First-100 MSP Dashboard Gate

- dashboard summary shows customer companies, billable seats, included minutes, overage, projected bill, and Stripe payment readiness
- expanded company cards show current-period minute usage and top seat-level usage, not only raw seat counts
- the MSP firm remains non-billable and the payment gate still appears even when the firm is filtered off the current dashboard page
- run `python3 twilio_voice_service/scripts/test_msp_100_dashboard_readiness.py --msps 100` before releases that touch portal billing, usage, or dashboard rendering
- run `twilio_voice_service/.venv-codex-msp/bin/python twilio_voice_service/scripts/test_msp_10000_user_scale.py --companies 100 --users-per-company 100 --call-users 10000` before broad MSP rollout or pricing changes

## Workstream 0: Trust Blockers

These are ship blockers for a serious MSP motion.

### 0.1 Remove portal-key auth as a user-facing fallback

Current hotspots:

- `app.py`: `require_portal_request`
- `app.py`: `/portal/login/key`
- `app.py`: `/portal/bootstrap`
- `app.py`: dashboard `?key=` session bootstrap

Actions:

- remove `key` and `x-msp-key` as valid authentication for normal portal pages and mutations
- keep portal API keys only for explicit service-to-service use if they are still needed
- replace recovery flows with one-time, expiring, auditable recovery links or Vicall-admin-assisted recovery

Acceptance criteria:

- no browser page or mutation route accepts a shared MSP key as an alternative to session auth
- recovery actions generate auditable events and expire automatically

### 0.2 Stop rendering secrets and live login links in HTML

Current hotspots:

- `app.py`: provisioning page rendering portal key
- `app.py`: `/portal/login/request` manual sign-in link fallback

Actions:

- remove raw portal key display from operator-facing pages
- never return a live magic link in the browser response
- replace with a safe status message and operator-facing diagnostics in logs only

Acceptance criteria:

- no raw portal keys shown in portal HTML
- no successful login token disclosed in browser responses under any mail-delivery state

### 0.3 Add real throttling and lockout to phone and OTP challenges

Current hotspots:

- `control_plane.py`: `msp_login_challenges`
- `app.py`: `/portal/login/phone`
- `app.py`: `/portal/login/code`

Actions:

- enforce resend cooldowns
- enforce max attempt counts per challenge and per IP/session window
- expire and rotate challenges after repeated failures
- log failures and temporary lockouts

Acceptance criteria:

- repeated OTP guessing is blocked
- repeated SMS sends are rate-limited
- support can distinguish expired, locked, and invalid challenges

### 0.4 Canonicalize externally generated auth URLs

Current hotspots:

- `app.py`: `public_absolute_url`

Actions:

- generate public auth links from a single configured canonical base URL
- do not trust arbitrary `Host` or `X-Forwarded-Host` headers for emailed sign-in URLs

Acceptance criteria:

- all login links resolve to the approved production hostname

## Workstream 1: Tenant Safety and Access Integrity

### 1.1 Scope offboarding and destructive actions to the selected company

Current hotspots:

- `app.py`: `/portal/memberships/deactivate`
- `control_plane.py`: `deactivate_memberships_for_msp`

Actions:

- require `organization_id` in the data-layer mutation
- make the backend reject ambiguous requests
- add tests covering multi-company membership scenarios

Acceptance criteria:

- removing a person from Company A cannot touch Company B under the same MSP

### 1.2 Normalize phone numbers consistently

Current hotspots:

- `control_plane.py`: `normalize_phone_number`
- `app.py`: password + phone confirmation flow

Actions:

- normalize all stored and entered numbers to E.164
- migrate existing MSP portal user phone values to normalized format
- use normalized comparisons for auth and membership lifecycle

Acceptance criteria:

- common formatting differences do not block valid operators from logging in

### 1.3 Make team invite and recovery flows explicit

Current hotspots:

- `app.py`: `/portal/team/invite`

Actions:

- split "invite new user" from "reset existing user"
- require higher privilege and stronger confirmation for credential resets
- surface whether an action creates, re-invites, or resets

Acceptance criteria:

- existing users are never silently reset by an invite path
- audit log shows exactly what happened

### 1.4 Add session inventory and revoke controls

Actions:

- allow owners to view active portal sessions
- add "sign out other sessions" and targeted revoke controls
- automatically revoke sessions after security-sensitive changes

Acceptance criteria:

- owners can contain account compromise without operator intervention from Vicall

## Workstream 2: Governance and Compliance

### 2.1 Add enforced MSP lifecycle states

Current hotspots:

- `control_plane.py`: `msps` table
- `MSP_PORTAL_PHASE2_PLAN.md`: lifecycle proposal

Actions:

- replace the simple `active` boolean with a real status field
- enforce state-based behavior in portal routing and mutation permissions
- preserve billing/history access for `suspended` and `closed` accounts as needed

Acceptance criteria:

- pending, active, suspended, and closed MSPs behave differently in clear and testable ways

### 2.2 Implement RBAC for all portal routes

Current hotspots:

- `control_plane.py`: `msp_users.role`
- `app.py`: all portal mutation routes

Actions:

- define route-by-route permission rules for `owner`, `billing_admin`, `operator`, and `read_only`
- add shared authorization helpers and apply them to every portal action
- hide or disable UI actions that the current role cannot use

Acceptance criteria:

- billing admins cannot perform ownership or security actions
- operators cannot manage Stripe or ownership
- read-only users cannot mutate data

### 2.3 Add an append-only audit log

Current reference:

- `MSP_PORTAL_PHASE2_PLAN.md`: audit log proposal

Actions:

- add `msp_audit_events`
- log auth events, provisioning, exports, billing actions, role changes, and destructive actions
- add a basic portal audit-log view with filtering by actor, company, and action

Acceptance criteria:

- support can answer who changed what, when, and from where
- disputes and security reviews do not require manual database archaeology

### 2.4 Define support access explicitly

Actions:

- decide whether Vicall support uses a separate admin console or a scoped support role
- if support touches MSP records, make it visible and auditable

Acceptance criteria:

- there is no invisible backdoor operator behavior

## Workstream 3: Operator UX and Product Credibility

These items are what change the feel from "internal tool" to "real platform."

### 3.1 Remove raw-ID workflows from the dashboard

Current hotspots:

- `app.py`: access-code creation form
- `app.py`: employee offboarding form

Actions:

- replace manual `organization_id` entry with company pickers and search
- use clear labels, customer names, and confirmation states

Acceptance criteria:

- operators can perform common tasks without copying internal identifiers

### 3.2 Build a real company workspace

Current hotspot:

- `app.py`: `render_company_manage_page`

Actions:

- expand company pages to include contacts, access codes, seat summary, recent joins, recent removals, notes/history, and billing snapshot
- support suspend/reactivate and code rotation flows
- show company health and billing context in one place

Acceptance criteria:

- a company admin page feels like an account workspace, not a thin admin form

### 3.3 Build a real team-management page

Current hotspot:

- `app.py`: MSP team section on dashboard

Actions:

- add team list, role editor, invite status, last sign-in, deactivation, reset, and session controls
- distinguish pending invites, active users, and disabled users

Acceptance criteria:

- MSP owners can manage their operator team without Vicall assistance

### 3.4 Make portal states read like customer software, not admin scaffolding

Actions:

- tighten copy, errors, and empty states
- make failures actionable and specific
- add confirmation modals and post-action receipts for destructive operations

Acceptance criteria:

- the product reads as deliberate and trustworthy under both success and failure states

## Workstream 4: Billing and Reporting Maturity

### 4.1 Build a billing center, not just a billing table

Current hotspots:

- `app.py`: billing summary section
- `app.py`: billing history rendering
- Stripe customer portal launch flow

Actions:

- show invoice status, invoice links, payment-method state, upcoming renewal/billing period, and failure guidance
- surface hosted invoice URLs when available
- distinguish projected charges from posted charges

Acceptance criteria:

- billing admins can answer basic invoice questions without contacting Vicall

### 4.2 Make exports usable for MSP operations

Current hotspots:

- `app.py`: CSV export routes

Actions:

- add filters for company, status, date range, and recent activity
- make filenames and columns stable and support-friendly
- define standard exports for seats, users, and billing snapshots

Acceptance criteria:

- CSV exports are consistent enough for PSA, finance, and support workflows

### 4.3 Publish and enforce seat policy

Actions:

- document what makes a seat active, billable, inactive, removed, and restorable
- keep the same definitions across UI, exports, billing preview, and invoices

Acceptance criteria:

- finance, support, and MSP customers all see the same seat logic

## Workstream 5: Verification and Release Confidence

### 5.1 Rewrite the smoke test to match the real auth flow

Current hotspot:

- `scripts/smoke_test_msp_lifecycle.py`

Actions:

- update the script to exercise email/password, phone confirmation, and OTP verification correctly
- ensure invite flows include all required fields
- cover at least one multi-company MSP scenario

Acceptance criteria:

- the smoke suite fails when the real portal flow breaks, not just when the old script assumptions break

### 5.2 Add end-to-end portal coverage

Actions:

- add browser-driven tests for sign-in, company creation, access-code creation, offboarding, team invite, and billing portal launch
- add regression coverage for the exact cases that triggered audit findings

Acceptance criteria:

- critical MSP actions are exercised in CI before release

### 5.3 Standardize the dev and CI runtime

Current hotspots:

- `Dockerfile`
- local Python tooling

Actions:

- make Python 3.11 the explicit local and CI baseline
- add a simple bootstrap command for developers
- document test commands that work without guesswork

Acceptance criteria:

- a developer can run portal tests locally without falling into version mismatches

### 5.4 Add release checklists for MSP-impacting changes

Actions:

- define pre-release checks for auth, team management, company management, billing, exports, and webhooks
- require validation on supported desktop and tablet breakpoints if MSPs are expected to use them

Acceptance criteria:

- release quality does not depend on one person remembering the risky flows

## Recommended Sequence

### Sprint 1

- Workstream 0
- Workstream 1.1
- Workstream 5.1

Outcome:

- the biggest trust and tenant-safety failures are closed first

### Sprint 2

- Workstream 1.2 to 1.4
- Workstream 2.1 to 2.3
- Workstream 5.3

Outcome:

- governance and operator-account integrity become credible

### Sprint 3

- Workstream 3.1 to 3.3
- Workstream 4.1
- Workstream 5.2

Outcome:

- the portal starts to feel like software a serious MSP can run every day

### Sprint 4

- Workstream 3.4
- Workstream 4.2 to 4.3
- Workstream 5.4

Outcome:

- polish, reporting, and release discipline catch up with the backend work

## Suggested Ownership

- backend/security: Workstream 0, 1, 2, 5.3
- full-stack/product: Workstream 3, 4.1, 4.2
- QA/release: Workstream 5.1, 5.2, 5.4
- product/ops: seat policy, lifecycle policy, support-access policy

## Definition of Done

The MSP portal can be called institutional when:

- an MSP owner can trust the auth model
- a billing admin can manage invoices without Vicall intervention
- an operator can manage companies and seats without raw IDs or hidden rules
- support can audit actions and explain outcomes
- engineering can release changes with confidence that the critical flows still work

Until then, the portal should be positioned as a capable but still maturing MSP control plane.
