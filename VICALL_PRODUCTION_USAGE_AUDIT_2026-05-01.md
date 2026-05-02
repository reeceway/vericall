# Vicall Production Usage Audit - 2026-05-01

This audit used production services and production control-plane data. It did not create fake calls, fake seats, fake invoices, or fake Stripe payments.

Artifacts:

- `/tmp/vicall-production-usage-audit.json`
- `/tmp/vicall-portal-audit/portal-audit-result.json`
- `/tmp/vicall-portal-audit/05-dashboard.png`
- `/tmp/vicall-portal-audit/06-billing.png`
- `/tmp/vicall-portal-audit/06-audit.png`

## Verdict

Status: **Yellow - usage tracking repaired; live customer-company charging still blocked by missing payment method**

Production is capturing real call events and linking them to the active MSP seat. During this audit, the historical usage cache was found stale, patched, deployed, and reconciled. The remaining blocker is live Stripe charging for a billable customer company, which cannot be proven until a default payment method is added.

## Production Checks

| Point | Result | Evidence |
| --- | --- | --- |
| Twilio/portal service health | PASS | `https://vericall-twilio-voice.fly.dev/health` returned HTTP 200. |
| Main API health | PASS | `https://vericall-api.fly.dev/health` returned HTTP 200. |
| Portal email/password/SMS login | PASS | Production portal audit completed dashboard, billing, and audit pages. |
| MSP owner account | PASS | Reece Way is active owner for Vicall MSP. |
| MSP firm non-billable | PASS | Current dashboard shows Vericall as active firm with 0 billable seats. |
| Stripe customer link | PASS/PARTIAL | Stripe customer exists for Vicall MSP, but no default payment method is on file. |
| Payment-before-customer rule | PASS | Portal blocks customer company provisioning until payment method setup. |
| Active membership/seat | PASS | One active firm membership exists for phone ending `8887`. |
| Voice token gate | PASS | Active production seat can receive a Twilio token; deliberately nonexistent identity is blocked with 403. |
| Device bindings | PASS | Production has 8 device bindings, including the active owner identity. |
| Real call event capture | PASS | Production DB has real completed call sessions for the MSP. |
| Live usage calculation | PASS | April live rollup shows 14 calls, 1,340 billable seconds, 30 rounded billable minutes for the active seat. |
| Cached user usage reporting | PASS after repair | `user_usage_monthly` now shows 14 calls and 30 rounded minutes for phone ending `8887`. |
| Cached historical org usage | PASS after repair | April `organization_usage_monthly` now shows 14 calls, 1,340 seconds, and 30 rounded minutes for Vericall with $0 amount because the firm is non-billable. |
| Portal current billing view | PASS | May 2026 correctly shows 0 calls/minutes because there are no May calls yet. |
| Portal historical usage data | PASS after repair | The DB cache that the historical billing view reads now contains the April user/company usage. |
| Billing run audit trail | PASS | Billing and Stripe invoice status events are present in the audit log. |
| Automatic customer billing proof | BLOCKED | Cannot prove live customer-company charging until a default Stripe payment method and billable customer company exist. |

## Important Finding

The call tracking path works:

`Twilio callback -> call_sessions -> call_participants -> membership/org/MSP link -> live usage rollup`

The reporting/cache path was incomplete for historical usage:

`call_sessions -> user_usage_monthly / organization_usage_monthly -> portal historical billing report`

That meant Vicall was not losing the raw usage events, but the MSP portal could under-report historical minutes after a billing run if additional calls landed in that same period and no later billing action refreshed the usage snapshots.

Repair applied:

- Added `ControlPlaneStore.record_usage_snapshot`.
- `run_monthly_billing_for_msp` now persists usage snapshots before returning, even when status is `already_ran`, `skipped_zero_amount`, or `skipped_missing_payment_method`.
- Deployed `vericall-twilio-voice` image `deployment-01KQK3STE6E3GH3G88VMEMEHJN`.
- Reconciled April 2026 for Vicall MSP: status `already_ran`, 14 calls, 30 billable minutes, $0 amount, 1 organization usage row, 1 user usage row.

## Current Production State For Vicall MSP

- MSP: Vicall
- Owner: Reece Way
- Phone: ending `8887`
- Firm: Vericall
- Firm billing: non-billable
- Active seats: 1
- Billable seats: 0
- Current period: May 2026
- May tracked calls: 0
- April real call usage from live events: 14 calls, 30 rounded billable minutes
- April cached user usage rows: 1
- Default Stripe payment method: missing

## Required Proof Before Calling This Fully MSP-Ready

1. After adding a default Stripe payment method, create a real billable customer company and repeat the flow with a real seat:
   - create customer company
   - issue access code
   - onboard phone in app
   - place real call
   - verify seat appears
   - verify live minutes appear by user and company
   - verify `$20/seat`, `450 minutes/seat`, and `$0.001/minute` overage math
   - verify automatic Stripe collection path
2. Keep the production usage audit script in the release checklist so stale reporting cache cannot come back quietly.
