# Gemini Context & Instructions

## Objective
Replace the current voice verification AI in VeriCall with the newly converted **WavLM Deepfake Detection Model**.

## Resources
- **New Model:** `WavLMDeepfake.mlpackage`
  - **Source:** Converted from `DavidCombei/wavLM-base-Deepfake_V2`.
  - **Location:** Currently in `~/.gemini/antigravity/scratch/wavlm_coreml/`. Needs to be moved to `VeriCall/voice-ml/` (or appropriate model directory).
  - **Input:** `input_values` (1, 48000) float32 (3 seconds @ 16kHz).
  - **Output:** `logits` (1, 2). Class 1 is "Fake".

## Implementation Steps
1.  **Locate Target:** Find `VoiceVerificationService.swift` in `ios/` directory.
2.  **Import Model:** Copy `.mlpackage` into the Xcode project structure.
3.  **Update Code:**
    - Initialize `WavLMDeepfake` model.
    - Implement audio buffering: Capture audio, resample to 16k, buffer to 3s (48,000 samples).
    - Run prediction.
    - Interpret logits (Softmax).
4.  **Test:** Verify on device or simulator.

## Current Status
- Model converted: [x]
- Model verified: [x] (99.95% confidence on `audio.wav`)
- Project access: [ ] Verifying
