# VeriCall: 10-Day Hackathon Sprint

## Goal: Working demo + App Store submission (if time permits)

---

## Day 1-2: Backend Deployment (Feb 10-11)

### Tasks:
- [ ] Clone repo on Mac Mini
- [ ] Set up Fly.io account
- [ ] Create PostgreSQL database (Supabase free tier)
- [ ] Create Redis (Upstash free tier)
- [ ] Deploy backend
- [ ] Test endpoints with curl
- [ ] Verify WebSocket works

**Deliverable:** `https://vericall-api.fly.dev/health` returns OK

**Time:** 4-6 hours

---

## Day 3-4: iOS Build & Basic Testing (Feb 12-13)

### Tasks:
- [ ] Open Xcode project
- [ ] Set up Apple Developer signing
- [ ] Build on iPhone #1
- [ ] Build on iPhone #2
- [ ] Test onboarding flow (both phones)
- [ ] Test voice enrollment
- [ ] Verify basic UI works

**Deliverable:** App runs on 2 physical iPhones

**Time:** 6-8 hours

---

## Day 5-6: Integration Testing (Feb 14-15)

### Tasks:
- [ ] Test contact sync
- [ ] Test call initiation
- [ ] Test device verification badge appears
- [ ] Test voice verification during call
- [ ] Check voice match percentages
- [ ] Test different speaker (mismatch scenario)
- [ ] Fix any critical bugs
- [ ] Add logging for debugging

**Deliverable:** End-to-end call flow works with verification

**Time:** 8-10 hours

---

## Day 7: Polish & Demo Prep (Feb 16)

### Tasks:
- [ ] Polish UI (smooth animations, proper colors)
- [ ] Fix any remaining bugs
- [ ] Create demo script
- [ ] Practice demo 3-5 times
- [ ] Record backup demo video
- [ ] Prepare slide deck (5-7 slides)

**Deliverable:** Demo-ready app + practiced pitch

**Time:** 6-8 hours

---

## Day 8: Hackathon Day (Feb 17)

### Tasks:
- [ ] Arrive early, set up table
- [ ] Test app on venue WiFi
- [ ] Have backup: hotspot on phone
- [ ] Pitch to judges
- [ ] Network with other teams
- [ ] Attend workshops/events

**Deliverable:** Successful pitch, feedback from judges

**Time:** Full day

---

## Day 9-10: App Store Sprint (Feb 18-19) - IF TIME PERMITS

### ONLY if hackathon went well and app is stable

### Day 9 Tasks:
- [ ] Create app icons (all sizes)
- [ ] Take screenshots (3-5 per device size)
- [ ] Write App Store description
- [ ] Create privacy policy (GitHub Pages)
- [ ] Set up App Store Connect
- [ ] Fill in app metadata

**Time:** 4-6 hours

### Day 10 Tasks:
- [ ] Final build in Xcode
- [ ] Archive & upload to App Store Connect
- [ ] Submit for review
- [ ] Set up TestFlight (internal testing)
- [ ] Add team members to TestFlight

**Time:** 3-4 hours

**Note:** App Store review takes 24-48 hours, so app won't be LIVE by hackathon, but submitted.

---

## Priority Matrix

### MUST HAVE (Days 1-7):
- ✅ Backend deployed
- ✅ iOS app builds
- ✅ Basic call flow works
- ✅ Device verification shows
- ✅ Voice verification shows match %
- ✅ Demo-ready

### NICE TO HAVE (Days 8-10 if time):
- ⭐ App Store submission
- ⭐ TestFlight beta
- ⭐ Polish UI animations
- ⭐ Additional features

### CUT IF BEHIND:
- ❌ App Store submission (focus on demo)
- ❌ Complex UI polish
- ❌ Extra features
- ❌ Android version

---

## Daily Schedule Template

```
Morning (2-3 hours):
- Review yesterday's progress
- Pick 2-3 tasks from current day
- Focus on highest priority

Afternoon (2-3 hours):
- Continue tasks
- Test as you go
- Fix blocking issues immediately

Evening (1-2 hours):
- Document what worked/broke
- Update checklist
- Plan tomorrow
- REST (don't burn out)
```

---

## Risk Mitigation

### If Backend Won't Deploy:
- [ ] Use local development server on Mac Mini
- [ ] Update iOS Constants.swift to use local IP
- [ ] Both phones on same WiFi

### If iOS Won't Build:
- [ ] Check Xcode version (15.0+)
- [ ] Verify signing certificates
- [ ] Clean build folder (Cmd+Shift+K)
- [ ] Try building for simulator first

### If Voice Verification Doesn't Work:
- [ ] Check microphone permissions
- [ ] Verify voice thumbprint is being sent
- [ ] Add debug logging
- [ ] Simplify to device verification only for demo

### If Call Won't Connect:
- [ ] Check WebSocket connection
- [ ] Verify both phones have internet
- [ ] Test with local server first
- [ ] Have pre-recorded demo video as backup

---

## Backup Plan (If Nothing Works)

**Always have:**
1. Screen recording of app working (even if buggy)
2. Slide deck explaining architecture
3. Live demo of at least ONE feature (onboarding, voice enrollment)
4. GitHub repo to show code

**Pitch strategy:**
"Here's what we built, here's the code, here's a video of it working. We'd love to show you live but [technical issue]. The architecture is solid and solves a real problem."

---

## Resources Needed

### Hardware:
- Mac Mini (for building)
- 2 iPhones (for testing)
- iPhone charger cables
- Backup battery pack

### Accounts:
- GitHub (done)
- Fly.io (free tier)
- Supabase (free tier)
- Apple Developer ($99 if doing App Store)

### Time Commitment:
- **Days 1-7:** 4-6 hours/day
- **Day 8:** Full day
- **Days 9-10:** 4-6 hours (optional)
- **Total:** 40-50 hours

---

## Success Metrics

### Minimum Viable Demo:
- [ ] App installs on 2 phones
- [ ] Users can onboard
- [ ] Voice enrollment works
- [ ] Call connects
- [ ] "Device Verified" badge shows
- [ ] Voice match % displays

### Full Success:
- [ ] All above works smoothly
- [ ] Demo video recorded
- [ ] Pitch practiced
- [ ] App Store submitted

---

## Post-Hackathon (After Day 10)

### If You Win/Place:
- [ ] Celebrate!
- [ ] Follow up with judges/mentors
- [ ] Continue development
- [ ] Consider incorporation
- [ ] Apply to accelerators

### If Not:
- [ ] Get feedback from judges
- [ ] Fix issues
- [ ] Finish App Store submission
- [ ] Open source the project
- [ ] Build portfolio

---

## Emergency Contacts

If stuck:
- Check GitHub issues in vericall repo
- Review TECH_SPEC.md
- Check DEV_WALKTHROUGH.md
- Search error messages on Stack Overflow
- Ask hackathon mentors

---

**Remember:** Done is better than perfect. A working demo beats a perfect unfinished app.

**Focus on:** Device verification + Voice match % = Winning pitch

**Good luck! 🚀**
