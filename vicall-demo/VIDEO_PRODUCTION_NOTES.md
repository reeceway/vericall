# Vicall Demo Video Notes

This project is anchored to the current app, not the aspirational script.

## Safe current-product claims

- Vicall is a secure calling app deployed by an MSP or IT team.
- Incoming calls can arrive through a native-feeling iPhone call flow.
- The app performs on-device synthetic-voice detection during live calls.
- The green in-call chip currently reads `Human Voice`.
- The red in-call chip currently reads `Synthetic Voice Alert`.
- The detection decision runs on-device.

## Claims to avoid in the video

- `Nothing ever leaves the phone`
- `No cloud processing` as a blanket statement
- `Carrier-level spoof detection`
- `Under one second` detection timing
- `Every call is verified instantly`

Why: the call still uses Twilio transport, and the live detector uses rolling windows plus smoothing before surfacing a strong verdict.

## Best current privacy wording

- `On-device detection`
- `No cloud inference for alerts`
- `No recordings stored by Vicall`

## Capture path we should prefer

The app already supports simulator screenshot mode via `VICALL_SCREENSHOT_KIND`, with these built-in states:

- `home`
- `incoming`
- `active-human`
- `active-warning`
- `contacts`

That is the fastest way to get clean, current-product visuals for most of the video.

## High-risk capture items

- Real lock-screen CallKit footage in the simulator may still be flaky.
- If true lock-screen CallKit is hard to capture cleanly, use either:
  - a real device recording for that specific moment, or
  - the current in-app incoming-call screen as a fallback for the first cut.

## Pricing section

The pricing card currently reflects the draft commercial story, not app-derived values. Confirm before final render if you want to keep:

- `<$1/day`
- `15-person team is $375/month`
- `25-person team is $625/month`
