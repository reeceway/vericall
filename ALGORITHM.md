# AI Deepfake Detection Algorithm: WavLM (v4.0)

## Overview
VeriCall uses a **WavLM-based** Transformer model (CoreML, FP16) to perform **real-time deepfake detection** on incoming VoIP audio. The model classifies audio segments as either **Human ("real")** or **AI-Generated ("fake")** based on raw waveform analysis, leveraging self-supervised learning representations that are highly effective at detecting vocoder artifacts and synthetic speech patterns.

## Detection Pipeline

1. **Audio Sampling**
   - **Source**: Remote audio from `AudioStreamService` ring buffer.
   - **Format**: 16kHz mono PCM (Float32).
   - **Context Window**: 3 seconds (48,000 samples).
   - **Buffer Strategy**: Waits for buffer to fill at start, then samples every 4 seconds.
   - **Energy Check**: Skips silence (RMS < 0.003).

2. **Preprocessing**
   - **None**: The model accepts raw audio waveforms directly.
   - **Input Shape**: `(1, 48000)` tensor.
   - **Normalization**: Implicitly handled by the model (expected input range approx [-1.0, 1.0]).

3. **CoreML Inference**
   - **Model**: `WavLMDeepfake.mlpackage` (Converted from `DavidCombei/wavLM-base-Deepfake_V2`).
   - **Precision**: FP16 (Half-Precision).
   - **Architecture**: WavLM Base (Transformer encoder).
   - **Output**: Class probabilities `{"fake": Float, "real": Float}`.

4. **Scoring & Classification**
   - **Deepfake Threshold**: **0.70** (70%).
   - The model must be at least 70% confident that audio is `fake` to trigger an alert.
   - Otherwise, it defaults to `human`.
   - **Recall Strategy**: Prioritizes avoiding false positives (flags real users as fake).

5. **Result Smoothing**
   - A rolling majority vote window (last 5 results) is used to stabilize the verify/alert UI.

## Performance
| Model | Accuracy | False Positive Rate | Inference Time (iPhone) |
|-------|----------|---------------------|-------------------------|
| WavLM | ~84% | ~6.7% | ~50ms |
| ConvNeXt (Old) | ~76% | ~26% | ~240ms |

## Requirements
- **iOS 17.0+**: Required for `WavLM` CoreML support.
- **Hardware**: Runs on Neural Engine (ANE) or CPU depending on device.
