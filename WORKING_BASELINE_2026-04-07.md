# Vicall Working Baseline - 2026-04-07

This is the last known-good product baseline before App Store and unlisted-distribution prep.

## Known Good Behavior

- Foreground Twilio calls work.
- Locked/background incoming calls wake through PushKit and ring through CallKit.
- Answering from the native CallKit screen connects audio.
- The in-call spoof chip works when the user opens Vicall during the call.
- Classic-only spoof detection is the current production candidate.
- Remote-only spoof alerts are enabled:
  - one caution notification for long audible/unconfirmed analysis before any human verdict
  - four-pulse serious alert for confirmed synthetic voice
- Contact-backed caller display works without blocking the PushKit to CallKit synchronous path.
- The Settings UI has been cleaned up and visible branding is now Vicall.

## Critical Rules Not To Regress

- Do not put live Contacts queries inside the PushKit incoming-call callback path.
- Do not add `Task {}` hops between `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` and `CXProvider.reportNewIncomingCall`.
- Do not re-enable the conference wake path unless it is a controlled diagnostic.
- Do not move the spoof model back to neural-only for live calls without recalibrating real Twilio audio.
- Do not test background ringing after force-quitting/swiping away the receiver app.

## Last Working Dev Build

The last installed working Debug build before App Store prep was produced under:

```text
/tmp/vericall-vicall-ringfix-signed-build/Build/Products/Debug-iphoneos/VeriCall.app
```

The App Store prep builds that followed compile, but were not installed over the phones because signing hit the macOS Keychain `codesign` private-key prompt again.

Release/App Store prep now keeps the user-visible app name as `Vicall`, while using the production bundle identifier `com.vicall.app`.

## Smoke Test Before Any Release Upload

1. Install the Debug build on both phones.
2. Open Vicall on both devices and verify clean Twilio bindings.
3. Lock/background the receiver without force-quitting.
4. Place a call from the other phone.
5. Confirm the receiver rings through CallKit.
6. Answer from CallKit and verify two-way audio.
7. Open Vicall during the call and confirm the spoof chip appears.
8. Play real speech and clone playback to verify alert behavior.
