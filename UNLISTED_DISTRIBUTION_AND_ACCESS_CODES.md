# Vicall Unlisted Distribution And Access Codes

## Distribution Decision

Use TestFlight first, then submit Vicall as an unlisted App Store app. Unlisted distribution keeps the app out of App Store search and category browsing, but it is not private. Anyone with the link can install it, so access control must be enforced by Vicall login.

For truly organization-only distribution, use Apple Custom Apps through Apple Business Manager. That is stricter, but it limits distribution to specified organizations and is a heavier MSP onboarding path.

## App Store Readiness

- Create/use the production bundle ID `com.vicall.app`.
- Enable Push Notifications, VoIP background mode, audio background mode, and remote notifications.
- Create a production Apple VoIP Services certificate for the production bundle ID.
- Create a production Twilio Push Credential and wire Release/TestFlight tokens to that SID.
- Keep Debug on the current sandbox push credential.
- Set `TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION` on the Twilio Voice Fly service before uploading a TestFlight build.
- Archive and upload to App Store Connect for TestFlight.
- Submit for unlisted App Store distribution after TestFlight stabilizes.

## Current Release Prep Status

- Debug builds as `com.reeceway.vericall.dev` with `APS_ENVIRONMENT=development`.
- Release builds as `com.vicall.app` with `APS_ENVIRONMENT=production`.
- Xcode archive preflight currently fails because no Apple Developer account is configured in Xcode on this Mac and no profile exists for `com.vicall.app`.
- The Twilio Voice token service accepts `push_environment`.
- Development tokens use `TWILIO_PUSH_CREDENTIAL_SID_DEVELOPMENT` if present, otherwise the current `TWILIO_PUSH_CREDENTIAL_SID`.
- Production tokens use `TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION`.
- Current production Twilio Push Credential SID: `CRe62ce9692f2c5e245a5ebcbf1471426c`.
- `Info.plist` now uses `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(MARKETING_VERSION)`, and `$(CURRENT_PROJECT_VERSION)` instead of hardcoded test values.

The production VoIP CSR is ready here:

```text
/Users/reeceway/Desktop/vericall voiceprints/vericall/release/apple/VicallVoIPProduction_com.vicall.app.csr
```

Keep this private key on this Mac. Do not upload it to Apple:

```text
/Users/reeceway/Desktop/vericall voiceprints/vericall/release/apple/VicallVoIPProduction_com.vicall.app.key
```

## Portal Steps Reece Must Do

### Apple Developer Bundle ID

1. Go to Apple Developer `Certificates, Identifiers & Profiles`.
2. Open `Identifiers`.
3. Create a new `App IDs` identifier.
4. Choose `App`.
5. Description: `Vicall`.
6. Bundle ID: `Explicit`, value `com.vicall.app`.
7. Enable `Push Notifications`.
8. Enable `Associated Domains` if Apple shows it in the capability list.
9. Save/register the identifier.

### Xcode Account

1. Open Xcode.
2. Go to `Xcode > Settings > Accounts`.
3. Add/sign in with the Apple Developer account for team `96294C9WZU`.
4. Keep automatic signing enabled in the Vicall project.

After this, rerun:

```sh
cd /Users/reeceway/Desktop/vericall\ voiceprints/vericall/ios
xcodebuild -workspace VeriCall.xcworkspace \
  -scheme VeriCall \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/VicallProdPreflight.xcarchive \
  -allowProvisioningUpdates \
  archive
```

### Apple Production VoIP Certificate

1. In Apple Developer `Certificates, Identifiers & Profiles`, open `Certificates`.
2. Create a new certificate.
3. Choose `VoIP Services Certificate`.
4. Select the `com.vicall.app` identifier.
5. Upload:

```text
/Users/reeceway/Desktop/vericall voiceprints/vericall/release/apple/VicallVoIPProduction_com.vicall.app.csr
```

6. Download the generated `.cer` file to this Mac.

Then run:

```sh
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/create_production_push_credential.sh /path/to/downloaded_voip_services.cer
```

That script will create the non-sandbox Twilio Push Credential and set `TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION` on Fly.

### App Store Connect App Record

1. Go to App Store Connect.
2. Open `My Apps`.
3. Create a new app.
4. Platform: `iOS`.
5. Name: `Vicall`.
6. Primary language: `English (U.S.)`.
7. Bundle ID: `com.vicall.app`.
8. SKU: `VICALL-IOS`.
9. User access: full access for now, unless you want to constrain App Store Connect roles later.
10. Fill in the privacy policy URL, support URL, app category, age rating, review notes, and screenshots.

Do not request unlisted distribution until the app is approved at least once.

Set the production Twilio credential after creating it:

```sh
flyctl secrets set TWILIO_PUSH_CREDENTIAL_SID_PRODUCTION=CR_PRODUCTION_SID_HERE -a vericall-twilio-voice
```

Or use the helper after downloading the Apple production VoIP `.cer`:

```sh
/Users/reeceway/Desktop/vericall\ voiceprints/vericall/twilio_voice_service/create_production_push_credential.sh /path/to/voip_services.cer
```

## Access Code Product Shape

MSPs should be able to generate a company-wide code and a link like:

```text
https://join.vicall.app/ACME-2026
vicall://join?code=ACME-2026
```

The iOS app now stores invite codes from `vicall://join?code=...`, `vicall://join/CODE`, and `https://join.vicall.app/CODE`. The app also shows a company access-code step before phone verification.

Current limitation: the production API does not yet expose access-code validation. The app captures the code, but it deliberately does not send `access_code` to `/auth/request-otp` yet because the live OpenAPI schema only documents `phone_number`.

## Backend Contract

Add these endpoints to the auth API before relying on access codes for real security:

```text
POST /access/validate
body: { "access_code": "ACME-2026" }
response: {
  "valid": true,
  "organization_id": "uuid",
  "organization_name": "Acme Dental",
  "code_id": "uuid",
  "grant_token": "short_lived_token"
}

POST /auth/request-otp
body: {
  "phone_number": "+14125550100",
  "access_grant_token": "short_lived_token"
}

POST /auth/verify-otp
body: {
  "phone_number": "+14125550100",
  "otp": "123456",
  "public_key": "...",
  "access_grant_token": "short_lived_token"
}
```

The server should reject OTP requests without a valid grant token once unlisted distribution is live.

## Data Model

- `organizations`: customer company or MSP tenant.
- `access_codes`: code, organization ID, MSP owner ID, expiration, max redemptions, redemption count, active/disabled state.
- `access_code_redemptions`: user phone, device ID, organization ID, code ID, timestamp, IP/device metadata.
- `msp_admins`: which MSP users can create, rotate, and revoke company codes.

## Security Rules

- Store only a hash of each access code.
- Normalize codes uppercase and allow only alphanumeric, dash, and underscore.
- Prefer one company-wide code per company plus optional campaign-specific codes.
- Rate-limit validation and OTP request by IP, phone number, and code.
- Support revocation and rotation without requiring app updates.
- Never trust local iOS access-code storage as authorization.

## iOS Flip To Enforce

After the backend validates access codes, set:

```swift
Constants.sendCompanyAccessCodeToBackend = true
```

Then replace the direct `access_code` send with the stronger `access_grant_token` contract above.
