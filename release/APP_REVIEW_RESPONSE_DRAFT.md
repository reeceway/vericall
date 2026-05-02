# Vicall App Review Reply Draft

Use this after uploading the next fixed build.

```text
Hello App Review,

Thank you for the review details.

We identified and fixed the login-flow issue. The company access code is validated before phone verification, the verification-code screen prevents duplicate OTP submission from one-time-code autofill or paste events, and the review access code now uses the same production MSP access-grant path as managed customer seats.

We also updated the App Store screenshots so they now show the app in active use rather than primarily marketing artwork.

For review, please use the following test flow:

1. Launch Vicall
2. Enter company access code: VICALL-REVIEW-4P7M
3. Enter a valid phone number for OTP verification
4. Continue through verification and onboarding

Additional note:
- Our current submission target is iPhone-only.
- The review access code above has been verified against the production access-code endpoint and is attached to a non-billable App Review firm so verification does not depend on a paid customer billing setup.

Please let us know if you need any additional review credentials or a different test path.

Thank you.
```

## Before Sending

- Replace the build number mention in App Store Connect with the newly uploaded build
- Confirm the access code is still current before reusing it
- Make sure the selected build is the latest iPhone-only build
