# VeriCall Voice ML

Real-time speaker recognition and voice verification system for VeriCall.

## Overview

This module provides:
- **Voice Embedding Extraction**: 192-dim embeddings (reduced from Resemblyzer's 256)
- **Voice Enrollment**: Create voice prints from audio samples or pre-computed embeddings
- **Voice Verification**: Real-time speaker verification during calls (< 500ms)
- **Backend API**: FastAPI endpoints for iOS integration

## Architecture

The iOS app extracts voice embeddings on-device and sends 192-dim vectors to the backend:

```
iOS App (On-Device)
  ├─ Record 5 voice samples during onboarding
  ├─ Extract 256-dim embeddings using Resemblyzer/SpeechBrain
  ├─ Reduce to 192-dim
  └─ Send to POST /api/v1/voice/enroll

During Call:
  ├─ Record 3-second audio chunks
  ├─ Extract 192-dim embedding
  ├─ Send to POST /api/v1/voice/verify
  └─ Display matchScore returned by backend
```

## Constants (MUST MATCH iOS)

| Constant | Value | Description |
|----------|-------|-------------|
| `voiceEmbeddingDimension` | 192 | Embedding vector size |
| `voiceMatchThreshold` | 0.75 | isMatch = true if score >= 0.75 |
| `voiceWarningThreshold` | 0.55 | Below = warning level |
| `voiceSampleRate` | 16000 | Audio sample rate (16kHz) |

## Audio Format (for Server-Side Processing)

- **Format**: WAV
- **Sample Rate**: 16kHz
- **Channels**: Mono
- **Bit Depth**: 16-bit PCM
- **Duration**: 2-30 seconds per sample

## Installation

```bash
# Navigate to voice-ml directory
cd projects/vericall/voice-ml

# Install dependencies
pip install -r requirements.txt

# Download Resemblyzer model (first run)
python -c "from resemblyzer import VoiceEncoder; VoiceEncoder()"
```

## API Endpoints

### POST /api/v1/voice/enroll

Enroll a user with their voice print (192-dim embedding).

**Request**:
```json
{
  "embedding": [0.123, -0.456, ...],  // 192 floats
  "sampleCount": 5
}
```

**Response**:
```json
{
  "success": true,
  "quality": 0.92
}
```

### GET /api/v1/voice/voiceprint/{userId}

Retrieve a user's stored voice print.

**Response**:
```json
{
  "enrolled": true,
  "voiceprint": {
    "embedding": [...],  // 192 floats
    "version": "1.0"
  }
}
```

### POST /api/v1/voice/verify

Verify voice during an active call.

**Request**:
```json
{
  "embedding": [0.123, -0.456, ...],  // 192 floats from iOS
  "userId": "uuid"
}
```

**Response**:
```json
{
  "matchScore": 0.94,
  "isMatch": true
}
```

- `isMatch` = true if `matchScore >= 0.75`

## Quick Start

### Server-Side Enrollment (from Audio)

```python
from voice_enrollment import VoiceEnrollmentService

# Initialize service
enrollment = VoiceEnrollmentService()

# Enroll with 5 audio samples
with open("sample1.wav", "rb") as f1, \
     open("sample2.wav", "rb") as f2, \
     open("sample3.wav", "rb") as f3, \
     open("sample4.wav", "rb") as f4, \
     open("sample5.wav", "rb") as f5:
    result = enrollment.enroll_from_audio([f1.read(), f2.read(), f3.read(), f4.read(), f5.read()])

if result.success:
    print(f"Voice print created! Quality: {result.quality_score}")
    # Store result.embedding_list (192 floats) in database
```

### Server-Side Enrollment (from Embeddings)

```python
# When iOS sends pre-computed embeddings
embeddings = [
    [0.1, -0.2, ...],  # 192-dim from iOS sample 1
    [0.15, -0.18, ...],  # 192-dim from iOS sample 2
    ...
]

result = enrollment.enroll_from_embeddings(embeddings)
```

### Voice Verification

```python
from voice_verification import VoiceVerificationService

# Initialize service
verification = VoiceVerificationService()

# Create session for a call
session = verification.create_session(
    call_id="call-123",
    user_id="user-456",
    voice_print=stored_voice_print  # 192-dim from database
)

# Verify 192-dim embedding from iOS
embedding = [0.12, -0.05, ...]  # 192 floats from iOS
result = verification.verify_from_embedding("call-123", embedding)

print(f"Match score: {result.match_score}")  # 0.0-1.0
print(f"Is match: {result.is_match}")  # True if >= 0.75
print(f"Time: {result.processing_time_ms}ms")  # Target < 500ms
```

### Direct Model Usage

```python
from speaker_model import get_speaker_model

model = get_speaker_model()

# Extract 192-dim embedding from audio
embedding = model.extract_embedding("audio.wav")

# Compare two embeddings
score = model.compute_similarity(embedding1, embedding2)
print(f"Similarity: {score}")  # 0.0 to 1.0
```

## Thresholds

| Metric | Threshold | Description |
|--------|-----------|-------------|
| Match | ≥ 0.75 | `isMatch` = true |
| Warning | < 0.55 | Mismatch warning level |
| Quality | ≥ 0.70 | Acceptable enrollment quality |

## Performance

- **Embedding Extraction**: ~200-300ms per sample (server-side)
- **Verification**: < 50ms per comparison
- **End-to-End**: < 500ms target
- **Accuracy**: > 90% for same speaker identification

## Dimension Reduction

Resemblyzer outputs 256-dim embeddings. We reduce to 192-dim using a learned
projection matrix that preserves similarity relationships:

```python
# In speaker_model.py
embedding_192 = model.reduce_dimensions(embedding_256)
```

The projection matrix is initialized with orthonormal columns and fixed
for consistency across iOS and backend.

## iOS Integration Guide

### Recording Audio

```swift
// Audio configuration
let audioFormat: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000,  // MUST MATCH: voiceSampleRate
    AVNumberOfChannelsKey: 1,  // Mono
    AVLinearPCMBitDepthKey: 16
]
```

### Extracting Embeddings

Use Resemblyzer or SpeechBrain on iOS:

```swift
// Extract 256-dim embedding using Resemblyzer
let embedding256 = resemblyzer.encode(audioSample)

// Reduce to 192-dim (use same projection as backend)
let embedding192 = reduceDimensions(embedding256, to: 192)

// Send to backend
let request = [
    "embedding": embedding192,
    "sampleCount": 5
]
```

### During Call

```swift
// Record 3-second chunks
// Extract 192-dim embedding
// POST to /api/v1/voice/verify
// Display matchScore in UI
```

## File Structure

```
voice-ml/
├── speaker_model.py         # Core model (192-dim embeddings)
├── voice_enrollment.py      # Enrollment service
├── voice_verification.py    # Verification service
├── requirements.txt         # Python dependencies
├── README.md               # This file
├── test_voice_ml.py        # Test suite
└── demo_voice_ml.py        # Demonstration script
```

## Testing

```bash
# Run tests
python test_voice_ml.py

# Run demo
python demo_voice_ml.py

# Test enrollment API
curl -X POST http://localhost:8000/api/v1/voice/enroll \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer {token}" \
  -d '{
    "embedding": [0.1, -0.2, 0.3, ...],  // 192 values
    "sampleCount": 5
  }'

# Test verification API
curl -X POST http://localhost:8000/api/v1/voice/verify \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer {token}" \
  -d '{
    "embedding": [0.1, -0.2, 0.3, ...],  // 192 values
    "userId": "uuid"
  }'
```

## Model Details

**Resemblyzer**: Pre-trained speaker encoder based on GE2E loss.
- Raw output: 256-dimension
- Reduced to: 192-dimension
- Language-independent
- Robust to background noise

**Fallback**: MFCC-based feature extraction when Resemblyzer unavailable.

## License

MIT License - See main project LICENSE