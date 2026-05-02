# Vicall App Store Screenshot Shot List

Use real in-app screenshots only. Do not use the green logo card, splash art, or mostly marketing text.

## Current Submission Context

- Current production app target: `com.vicall.app`
- Current project target device family: `iPhone` only
- Apple rejected prior screenshots because the majority did not show the app in use

## Required Set For The Next Submission

Create at least 5 real iPhone screenshots at `6.5-inch` size.

Recommended sequence:

1. **Home / ready-to-call screen**
   - Show the main call entry point
   - Include the Vicall branding, not just a blank landing screen
   - Avoid using the pure login screen as the first screenshot

2. **Incoming call screen**
   - Show `Vicall from <name or number>`
   - If possible, show the branded incoming-call UI while the app is open
   - If using native CallKit, pair this with an in-app screen elsewhere so Apple sees actual app functionality

3. **Active call with human verdict**
   - Show the real call UI
   - Make sure the `Human Voice` or equivalent trust chip is visible
   - This is one of the strongest “app in use” screenshots

4. **Active call with warning state**
   - Show `Voice Not Confirmed` or `Synthetic Voice Alert`
   - This demonstrates the product’s core value instead of just showing a dialer

5. **Contacts / caller identity screen**
   - Show the contacts list or contact-linked caller identity
   - Reinforces that the app is useful beyond a static call screen

Optional extras:

6. **Company access code onboarding**
   - Only as a supporting screenshot, not the majority
   - If included, keep it to one screenshot

7. **Settings / security preferences**
   - Only if the screen is polished and clearly part of the shipped user experience

## Screenshot Rules

- Majority must show the app actively being used
- Login/onboarding can appear, but only as a minority
- Avoid empty states when possible
- Avoid using only branding or launch art
- Keep system chrome realistic; do not heavily doctor the images

## Practical Capture Plan

Use one device/build and capture these states:

1. Fresh authenticated home screen
2. A real incoming call test
3. A connected call with a `Human Voice` result
4. A connected call with a warning/fake result
5. Contacts tab with at least one recognizable contact row

## Apple Review Tie-In

These screenshots should be uploaded before the next resubmission so the `2.3.3 Accurate Metadata` issue does not recur.
