# VeriCall: Dev Walkthrough

## How We Designed a Deepfake-Proof Calling System in One Conversation

---

## The Starting Point

**The hackathon prompt:** Build something to combat AI-generated voice scams (deepfakes).

**Initial thought:** "Can we build a tool that detects if a voice is AI-generated?"

This is where most teams would start. And it's a trap.

---

## Phase 1: The Detection Approach (Dead End)

### First Idea: AI Deepfake Detector

```
┌─────────────────────────────────────────────────────────────────┐
│ INITIAL CONCEPT                                                 │
│                                                                 │
│ Incoming Call → Analyze Audio → "Is this AI?" → Yes/No         │
│                                                                 │
│ Problems we immediately identified:                              │
│ • Arms race: Detectors improve, but so do generators            │
│ • False positives: Real voices flagged as fake                 │
│ • Latency: Analysis takes time, call already happening         │
│ • Access: Can't intercept carrier audio on iOS                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**The realization:** Trying to detect fakes is playing defense. The attacker always has the advantage because they can test their fakes against your detector before attacking.

> "What if instead of asking 'is this fake?', we ask 'is this the real person?'"

This was the pivot moment.

---

## Phase 2: Flip the Problem

### New Frame: Verify Authenticity, Don't Detect Fakes

```
OLD APPROACH:                    NEW APPROACH:
─────────────                    ─────────────
"Is this voice AI-generated?"     "Is this voice the person they claim to be?"
│                                │
▼                                ▼
Hard to detect                  Compare to known
(adversarial)                   reference (voiceprint)
│                                │
▼                                ▼
Arms race                      Attacker must clone
(they adapt)                    SPECIFIC person (much harder)
```

**Key insight:** A scammer using generic AI voice fails immediately because it won't match anyone's voiceprint. They'd have to specifically clone YOUR mom's voice - and even then, the clone won't be perfect.

---

## Phase 3: But Wait, That's Not Enough

### The Stolen Phone Problem

We sketched out the voice verification system and immediately found a hole:

```
ATTACK SCENARIO:
────────────────
1. Attacker steals Mom's phone (unlocked)
2. Attacker calls you using Mom's phone
3. Your phone shows: "Incoming call from Mom"
4. You answer
5. Attacker speaks (their voice, not Mom's)
6. Voice verification: ❌ MISMATCH

Wait... this actually works! The voice won't match.
```

But then we thought harder:

```
WORSE SCENARIO:
───────────────
1. Attacker gets Mom's phone number (SIM swap, social engineering)
2. Attacker registers their OWN device with Mom's number
3. Attacker calls you
4. Your phone shows: "Mom calling" (caller ID spoofed)
5. You answer... How do we know it's actually Mom's DEVICE?
```

**This led to the two-phase architecture:**

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│ PHASE 1: DEVICE VERIFICATION (Before you answer)                  │
│ ─────────────────────────────────────────────────               │
│ • Caller's device has a cryptographic key in Secure Enclave       │
│ • When calling, device SIGNS the call request                     │
│ • Server verifies signature before notifying recipient            │
│ • Recipient sees: "Mom - ✓ Device Verified"                     │
│                                                                 │
│ PHASE 2: VOICE VERIFICATION (During the call)                    │
│ ─────────────────────────────────────────────────               │
│ • Caller's voice is compared to enrolled voiceprint               │
│ • Real-time analysis: "Voice Match: 94%"                        │
│ • Catches: stolen device, AI voice cloning                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 4: Understanding the Cryptography

### Why Not Just Use Caller ID?

```
CALLER ID IS TRIVIALLY SPOOFABLE:
─────────────────────────────────
Anyone can make a call appear to come from any number.
VoIP services let you set arbitrary caller ID.

WHAT WE NEED:
─────────────
Proof that the call originates from a SPECIFIC DEVICE
that the real owner registered.
```

### The Signature Flow

```
REGISTRATION (One-time):
───────────────────────
1. User downloads app
2. App generates key pair in Secure Enclave

┌──────────────────────────────────────────────┐
│ Private Key: Stays in Secure Enclave         │
│ NEVER leaves the device                        │
│ Cannot be extracted                            │
│                                                │
│ Public Key: Uploaded to server               │
│ Linked to phone number                         │
└──────────────────────────────────────────────┘

3. User verifies phone number (SMS OTP)
4. Server stores: phone_number → public_key mapping

MAKING A CALL:
──────────────
1. Caller creates message: timestamp + nonce + recipient_id
2. Caller SIGNS message with private key
3. Server verifies signature with public key
4. If valid, shows: "From verified device ✓"
```

---

## Phase 5: Understanding Voiceprints

### How Do You Turn a Voice into Numbers?

```
Audio → [Neural Network] → [192 numbers] → Voice Signature

Same person, different words → Similar vectors
Different people, same words → Different vectors

Comparison: Cosine Similarity
• Same person: 0.85-0.99 (very aligned)
• Different person: 0.20-0.50 (not aligned)
• AI Clone: 0.60-0.80 (close but not perfect)

Threshold: 0.75
→ Above = Verified
→ Below = Mismatch
```

---

## Phase 6: The Final Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ ATTACK MATRIX                                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ ATTACK                    │ DEVICE  │ VOICE  │ RESULT         │
│                           │ CHECK   │ CHECK  │                │
│ ──────────────────────────┼─────────┼────────┼────────────────│
│ Random scammer calls      │ ❌      │ N/A    │ Blocked        │
│ Caller ID spoofing        │ ❌      │ N/A    │ Blocked        │
│ Stolen phone (locked)     │ ❌      │ N/A    │ Blocked        │
│ Stolen phone (unlocked) │ ✓       │ ❌     │ Warning        │
│ SIM swap attack           │ ❌      │ N/A    │ Blocked        │
│ AI voice clone (new dev)  │ ❌      │ N/A    │ Blocked        │
│ AI voice clone (real dev) │ ✓       │ ⚠️     │ Warning (70%)  │
│ Real person, real device  │ ✓       │ ✓      │ Verified ✓     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Pitch (30 seconds)

> "AI can clone anyone's voice. Scammers are using this to impersonate family members and steal money.
>
> VeriCall stops this with two-factor voice verification.
>
> First, cryptographic device verification - before you answer, you know the call is from the right phone.
>
> Second, real-time voice matching - during the call, we verify the speaker matches their enrolled voiceprint.
>
> If someone steals grandma's phone and calls you? Device verified, but voice mismatch. You'll know instantly.
>
> VeriCall: Know who's really calling."

---

## Key Learnings

### 1. Reframe the Problem
**We didn't build a "deepfake detector." We built an "identity verifier."**

### 2. Defense in Depth
**No single check is foolproof. Device + voice together = robust.**

### 3. Work With Platform Constraints
**iOS doesn't let you intercept calls. We built VoIP architecture instead.**

### 4. The Attacker's Perspective
**Every design decision stress-tested: "How would an attacker beat this?"**

---

*Built in one conversation. From problem to solution to implementation.*
