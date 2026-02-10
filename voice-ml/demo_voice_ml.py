#!/usr/bin/env python3
"""
demo_voice_ml.py - Demonstration of VeriCall Voice ML

Shows end-to-end usage of voice enrollment and verification
with 192-dimensional embeddings.
"""

import os
import sys
import numpy as np

# Add voice-ml to path
sys.path.insert(0, os.path.dirname(__file__))

from speaker_model import get_speaker_model
from voice_enrollment import get_enrollment_service
from voice_verification import get_verification_service


def create_voice_embedding(base_freq=1.0, noise_level=0.05):
    """
    Create a synthetic 192-dim voice embedding.
    Simulates what iOS would send after extracting from audio.
    """
    # Create base pattern based on frequency
    t = np.linspace(0, 4 * np.pi, 192)
    base = np.sin(base_freq * t) + 0.5 * np.sin(base_freq * 2 * t)
    
    # Add noise
    noise = np.random.normal(0, noise_level, 192)
    embedding = base + noise
    
    # Normalize
    embedding = embedding / np.linalg.norm(embedding)
    
    return embedding.astype(np.float32)


def main():
    print("=" * 60)
    print("VeriCall Voice ML Demo (192-dim Embeddings)")
    print("=" * 60)
    print()
    print("This demo simulates the voice enrollment and verification")
    print("process using 192-dimensional embeddings (as per API spec).")
    print()
    print("Constants (matching iOS):")
    print("  - voiceEmbeddingDimension = 192")
    print("  - voiceMatchThreshold = 0.75")
    print("  - voiceWarningThreshold = 0.55")
    print()
    
    # Initialize services
    print("[1/5] Initializing voice services...")
    speaker_model = get_speaker_model()
    enrollment_service = get_enrollment_service()
    verification_service = get_verification_service()
    print("      ✓ Services ready")
    print()
    
    # Show constants
    print(f"      Model constants:")
    print(f"        EMBEDDING_DIM = {speaker_model.EMBEDDING_DIM}")
    print(f"        MATCH_THRESHOLD = {speaker_model.MATCH_THRESHOLD}")
    print(f"        WARNING_THRESHOLD = {speaker_model.WARNING_THRESHOLD}")
    print()
    
    # Simulate user onboarding - voice enrollment
    print("[2/5] User Onboarding - Voice Enrollment")
    print("      iOS extracts 192-dim embeddings from 5 voice samples...")
    
    # Simulate 5 embeddings from same voice
    user_voice_freq = 1.0
    enrollment_embeddings = []
    
    for i in range(5):
        # Slight variation in each sample
        freq = user_voice_freq + np.random.uniform(-0.05, 0.05)
        emb = create_voice_embedding(base_freq=freq, noise_level=0.05)
        enrollment_embeddings.append(emb.tolist())
        print(f"      ✓ Sample {i+1}: 192-dim embedding extracted")
    
    # Process enrollment
    result = enrollment_service.enroll_from_embeddings(enrollment_embeddings)
    
    if result.success:
        print(f"      ✓ Enrollment successful!")
        print(f"        Quality score: {result.quality_score:.2%}")
        print(f"        Voice print: {len(result.embedding_list)} dimensions")
    else:
        print(f"      ✗ Enrollment failed: {result.message}")
        return
    
    voice_print = result.embedding_list
    print()
    
    # Simulate active call - voice verification
    print("[3/5] Active Call - Voice Verification")
    print("      Alice calls Bob, VeriCall verifies Alice's voice...")
    
    call_id = "call-demo-123"
    user_id = "user-alice-456"
    
    # Create verification session
    session = verification_service.create_session(call_id, user_id, voice_print)
    print(f"      ✓ Verification session created: {call_id}")
    print()
    
    # Simulate voice chunks during call (every 3 seconds)
    print("[4/5] Real-time Verification During Call")
    print("      iOS sends 192-dim embedding every 3 seconds...")
    print()
    
    num_chunks = 5
    for i in range(num_chunks):
        # Alice speaks (matching voice)
        freq = user_voice_freq + np.random.uniform(-0.03, 0.03)
        embedding = create_voice_embedding(base_freq=freq, noise_level=0.05)
        
        # Verify
        result = verification_service.verify_from_embedding(
            call_id, embedding.tolist()
        )
        
        match_indicator = "✓" if result.is_match else "⚠"
        print(f"      {match_indicator} Chunk {i+1}: "
              f"Score={result.match_score:.2%}, "
              f"IsMatch={result.is_match}, "
              f"Time={result.processing_time_ms:.0f}ms")
    
    print()
    
    # Simulate impostor
    print("[5/5] Impostor Detection")
    print("      Someone else takes over the call (different voice)...")
    print()
    
    impostor_freq = 2.5  # Different voice frequency
    for i in range(3):
        embedding = create_voice_embedding(base_freq=impostor_freq, noise_level=0.05)
        
        result = verification_service.verify_from_embedding(
            call_id, embedding.tolist()
        )
        
        match_indicator = "✓" if result.is_match else "⚠"
        alert = " 🚨 ALERT!" if result.match_score < 0.55 else ""
        
        print(f"      {match_indicator} Chunk {i+1}: "
              f"Score={result.match_score:.2%}, "
              f"IsMatch={result.is_match}{alert}")
    
    # Check final status
    print()
    print("      Final Session Status:")
    status = verification_service.get_session_status(call_id)
    print(f"        Average score: {status['average_score']:.2%}")
    print(f"        Alert triggered: {status['alert_triggered']}")
    print()
    
    # End session
    verification_service.end_session(call_id)
    print("      ✓ Call ended, session cleaned up")
    print()
    
    # Summary
    print("=" * 60)
    print("Demo Complete!")
    print("=" * 60)
    print()
    print("Summary:")
    print("  • Voice enrollment created 192-dim voice print")
    print("  • Real-time verification using cosine similarity")
    print("  • Match threshold: 0.75 (isMatch = score >= 0.75)")
    print("  • Warning threshold: 0.55 (below triggers alert)")
    print("  • Processing time: < 50ms per verification")
    print()
    print("VeriCall is ready to protect your calls! 🔒")


if __name__ == "__main__":
    main()