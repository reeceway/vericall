# Vicall App Store Metadata Draft

## App Name

Vicall

## Subtitle

Voice security for phone calls

## Promotional Text

Vicall helps teams answer calls with more confidence by checking caller identity signals and warning when a voice is not confirmed.

## Description

Vicall is a secure calling app built for organizations that want stronger protection against voice impersonation and synthetic voice scams.

Vicall supports app-to-app voice calls, native iOS ringing through CallKit, contact-backed caller display, and live voice checks during a call. When a voice cannot be confirmed or is flagged as synthetic, Vicall can notify the user so they know to treat the call carefully.

For MSP and company deployments, Vicall supports invite-code onboarding so access can be limited by organization.

Key features:
- Native iOS incoming-call experience
- Contact-backed caller identity
- Live voice-check status during calls
- Synthetic-voice alert notifications
- Company access-code onboarding
- Secure calling workflow designed for managed teams

## Keywords

voice security, caller verification, call security, synthetic voice, deepfake detection, MSP, secure calls

## Category

Primary: Business

Secondary: Utilities

## Support URL

TODO: Add production support URL.

## Marketing URL

TODO: Add production marketing URL.

## Privacy Policy URL

TODO: Add production privacy policy URL.

## App Review Notes

Vicall is a secure calling app for organization-managed users. The app requires phone-number verification and may require a company access code during onboarding.

For review, use this test path:

1. Install the app.
2. Enter the review access code: `VICALL-REVIEW-4P7M`.
3. Enter a phone number that can receive SMS verification codes and complete the OTP prompt.
4. Open the app on two devices or use the provided second test account to place an app-to-app call.
5. Background/lock the receiver to confirm native CallKit ringing.
6. Answer the call and open Vicall during the active call to see the voice-check status.

Notes:
- The app uses Twilio Voice for app-to-app calling and PushKit/CallKit for native incoming-call handling.
- The voice check is a safety signal and does not block emergency calls or replace user judgment.
- The app should not be force-quit/swiped away for background incoming-call testing; this follows iOS PushKit behavior.

TODO before submission:
- Reconfirm the review access code validates on production and returns the App Review MSP grant context before uploading.
- Confirm production Twilio push credential is configured.

## Privacy Label Draft

Data likely collected:
- Phone Number: used for account verification and caller identity.
- Contacts: used to show contact-backed caller names and discover other Vicall users.
- User ID / Device ID: used for account, push registration, and call routing.
- Diagnostics: used for debugging reliability and call delivery.
- Audio Data: Twilio transports live call audio; Vicall performs live voice-check analysis during calls.

Data likely linked to user:
- Phone Number
- Contacts-derived matches
- User ID / Device ID
- Call metadata needed to route app-to-app calls

Data not for tracking:
- Do not use collected data for third-party advertising or cross-app tracking.

TODO before submission:
- Finalize the privacy policy with Twilio as a subprocesser/vendor.
- Confirm whether audio analysis is fully on-device or whether any audio windows leave the device in production.
- Remove or disable debug capture modes in production builds.

## Screenshot Checklist

- Onboarding welcome screen with Vicall branding.
- Company access-code screen.
- Phone verification screen.
- Home/call screen.
- Native incoming call screen showing Vicall caller display.
- Active call screen showing `Human Voice` / `Voice Not Confirmed` / `Synthetic Voice Alert` states.
- Settings screen after cleanup.
