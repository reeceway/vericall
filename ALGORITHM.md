# Voice Verification Algorithm (v2.0)

## Overview
The VeriCall voice verification system uses a **24-dimensional feature vector** derived from **Mean Voiced MFCCs** (Mel Frequency Cepstral Coefficients) with **Cepstral Mean Subtraction (CMS)**.

This approach was selected after extensive batch testing on the FSDD dataset, outperforming covariance-based, hybrid, and dynamic (delta) feature sets. It achieves an accuracy of **85.7%** on the test set with a **33% discrimination gap** between same-speaker and cross-speaker scores.

## Feature Extraction Pipeline

1.  **VAD (Voice Activity Detection)**:
    *   Frames are analyzed for RMS amplitude.
    *   Only frames with RMS > 0.015 are considered "voiced".
    *   This removes silence and low-level background noise.

2.  **MFCC Extraction**:
    *   FFT Size: 512 (assuming 16kHz audio)
    *   Mel Bands: 32
    *   MFCC Coefficients: 25 (0-24) applied to the Mel filterbank log-energies.

3.  **Channel Normalization (CMS)**:
    *   The mean of each MFCC coefficient (0-24) is computed across the *entire* utterance.
    *   This global mean is subtracted from every frame. This removes stationary channel effects (microphone frequency response, transmission path).

4.  **Feature Computation (Mean Voiced CMS)**:
    *   We discard MFCC 0 (Energy) as it varies with distance/volume.
    *   We use MFCCs **1 through 24**.
    *   We compute the **Mean** of these 24 coefficients *only over the Voiced frames*.
    *   **Result**: A 24-element vector representing the average spectral shape of the speaker's voice, relative to the channel average.

## Scoring Mechanism

*   **Metric**: **Cosine Similarity**.
*   **Formula**: `dot(A, B) / (norm(A) * norm(B))`
*   **Range**: -1.0 to 1.0 (approximated as percentage -100% to 100%).
*   **Threshold**: **72.0%**.
    *   Scores > 72% are considered a **MATCH**.
    *   Scores <= 72% are considered a **NO MATCH**.

## Performance Logic

*   **Low Frequencies (MFCCs 1-12)**: Provide robust speaker matching. They capture the core formant structure and are stable across different recordings.
*   **High Frequencies (MFCCs 13-24)**: Provide critical discrimination against impostors. While slightly less stable, they capture finer spectral details (breathiness, roughness) that differentiate similar-sounding voices.
*   **Why Mean?**: Covariance (texture/dynamics) proved to be too similar across speakers for short utterances. The *static timbre* (average shape) is the most distinctive feature for this specific use case.

## Enrollment

Users must enroll by providing 3-5 short phrases.
*   The system extracts the 24-dim vector for each phrase.
*   The **enrollment signature** is the average vector of these samples.

## Verification

When a user speaks:
1.  Audio is captured.
2.  24-dim vector is extracted.
3.  Cosine similarity is computed against the stored enrollment signature.
4.  If Score > Threshold, access is granted.
