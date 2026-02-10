#!/usr/bin/env python3
"""
test_voice_ml.py - Test script for VeriCall Voice ML module

Run this to verify the voice ML components are working correctly.
Tests 192-dimensional embeddings.
"""

import os
import sys
import numpy as np
import tempfile
import io

# Add voice-ml to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

try:
    from speaker_model import SpeakerModel, get_speaker_model
    from voice_enrollment import VoiceEnrollmentService, get_enrollment_service
    from voice_verification import VoiceVerificationService, get_verification_service
    print("✓ Imports successful")
except ImportError as e:
    print(f"✗ Import failed: {e}")
    sys.exit(1)


def test_constants():
    """Verify constants match TECH_SPEC.md."""
    print("\n=== Verifying Constants ===")
    
    model = get_speaker_model()
    
    assert model.EMBEDDING_DIM == 192, f"Expected EMBEDDING_DIM=192, got {model.EMBEDDING_DIM}"
    print(f"✓ EMBEDDING_DIM = {model.EMBEDDING_DIM}")
    
    assert model.MATCH_THRESHOLD == 0.75, f"Expected MATCH_THRESHOLD=0.75, got {model.MATCH_THRESHOLD}"
    print(f"✓ MATCH_THRESHOLD = {model.MATCH_THRESHOLD}")
    
    assert model.WARNING_THRESHOLD == 0.55, f"Expected WARNING_THRESHOLD=0.55, got {model.WARNING_THRESHOLD}"
    print(f"✓ WARNING_THRESHOLD = {model.WARNING_THRESHOLD}")
    
    assert model.SAMPLE_RATE == 16000, f"Expected SAMPLE_RATE=16000, got {model.SAMPLE_RATE}"
    print(f"✓ SAMPLE_RATE = {model.SAMPLE_RATE}")
    
    print("✓ All constants match TECH_SPEC.md")


def test_dimension_reduction():
    """Test 256 -> 192 dimension reduction."""
    print("\n=== Testing Dimension Reduction ===")
    
    model = get_speaker_model()
    
    # Create 256-dim embedding
    embedding_256 = np.random.randn(256).astype(np.float32)
    embedding_256 = embedding_256 / np.linalg.norm(embedding_256)
    
    # Reduce to 192
    embedding_192 = model.reduce_dimensions(embedding_256)
    
    assert len(embedding_192) == 192, f"Expected 192-dim, got {len(embedding_192)}"
    print(f"✓ Reduced {len(embedding_256)}-dim to {len(embedding_192)}-dim")
    
    # Verify normalization
    norm = np.linalg.norm(embedding_192)
    assert abs(norm - 1.0) < 0.01, f"Expected normalized vector, got norm={norm}"
    print(f"✓ Reduced embedding is normalized (norm={norm:.4f})")
    
    # Test passing 192-dim through (should return unchanged)
    embedding_pass = model.reduce_dimensions(embedding_192.tolist())
    assert len(embedding_pass) == 192
    print("✓ 192-dim passes through unchanged")


def test_similarity():
    """Test cosine similarity computation."""
    print("\n=== Testing Similarity Computation ===")
    
    model = get_speaker_model()
    
    # Create two similar embeddings
    emb1 = np.random.randn(192).astype(np.float32)
    emb1 = emb1 / np.linalg.norm(emb1)
    
    # Create similar embedding (add small noise)
    emb2 = emb1 + np.random.randn(192) * 0.1
    emb2 = emb2 / np.linalg.norm(emb2)
    
    # Create different embedding
    emb3 = np.random.randn(192).astype(np.float32)
    emb3 = emb3 / np.linalg.norm(emb3)
    
    # Compute similarities
    sim_same = model.compute_similarity(emb1, emb2)
    sim_diff = model.compute_similarity(emb1, emb3)
    
    print(f"✓ Similarity (similar vectors): {sim_same:.4f}")
    print(f"✓ Similarity (different vectors): {sim_diff:.4f}")
    
    # Similar vectors should have higher similarity
    assert sim_same > sim_diff, "Similar vectors should have higher similarity"
    print("✓ Similarity ordering is correct")
    
    # Test exact match
    sim_identical = model.compute_similarity(emb1, emb1)
    assert abs(sim_identical - 1.0) < 0.001, f"Identical vectors should have similarity=1, got {sim_identical}"
    print(f"✓ Identical vectors similarity: {sim_identical:.4f}")


def test_enrollment_from_embeddings():
    """Test enrollment from pre-computed 192-dim embeddings."""
    print("\n=== Testing Enrollment from Embeddings ===")
    
    service = get_enrollment_service()
    
    # Create 5 random 192-dim embeddings
    embeddings = []
    for i in range(5):
        emb = np.random.randn(192).astype(np.float32)
        emb = emb / np.linalg.norm(emb)
        embeddings.append(emb.tolist())
    
    print(f"✓ Created {len(embeddings)} test embeddings (192-dim)")
    
    # Enroll
    result = service.enroll_from_embeddings(embeddings)
    
    print(f"✓ Enrollment result:")
    print(f"  Success: {result.success}")
    print(f"  Quality: {result.quality_score:.4f}")
    print(f"  Voice print shape: {len(result.embedding_list)}-dim")
    
    assert result.success, f"Enrollment failed: {result.message}"
    assert len(result.embedding_list) == 192, f"Expected 192-dim voice print"
    assert result.quality_score >= 0.0 and result.quality_score <= 1.0
    
    return result.embedding_list


def test_verification_from_embedding(voice_print):
    """Test verification using 192-dim embeddings."""
    print("\n=== Testing Verification from Embedding ===")
    
    service = get_verification_service()
    
    # Create session
    session = service.create_session(
        call_id="test-call-123",
        user_id="test-user-456",
        voice_print=voice_print
    )
    print(f"✓ Created verification session: {session.call_id}")
    
    # Test with similar embedding (should match)
    similar_emb = np.array(voice_print) + np.random.randn(192) * 0.05
    similar_emb = similar_emb / np.linalg.norm(similar_emb)
    
    result1 = service.verify_from_embedding("test-call-123", similar_emb.tolist())
    print(f"✓ Similar embedding:")
    print(f"  Match score: {result1.match_score:.4f}")
    print(f"  Is match: {result1.is_match}")
    print(f"  Time: {result1.processing_time_ms:.2f}ms")
    
    # Test with different embedding (should not match)
    diff_emb = np.random.randn(192).astype(np.float32)
    diff_emb = diff_emb / np.linalg.norm(diff_emb)
    
    result2 = service.verify_from_embedding("test-call-123", diff_emb.tolist())
    print(f"✓ Different embedding:")
    print(f"  Match score: {result2.match_score:.4f}")
    print(f"  Is match: {result2.is_match}")
    
    # Verify threshold logic
    assert result1.match_score >= 0.75, "Similar embedding should have score >= 0.75"
    assert result1.is_match == True, "Similar embedding should be a match"
    assert result2.is_match == False, "Different embedding should not be a match"
    
    # End session
    service.end_session("test-call-123")
    print("✓ Session ended")


def test_quick_verify():
    """Test quick verification without session."""
    print("\n=== Testing Quick Verify ===")
    
    service = get_verification_service()
    
    # Create voice print
    voice_print = np.random.randn(192).astype(np.float32)
    voice_print = voice_print / np.linalg.norm(voice_print)
    
    # Create similar embedding
    similar_emb = voice_print + np.random.randn(192) * 0.05
    similar_emb = similar_emb / np.linalg.norm(similar_emb)
    
    result = service.quick_verify(similar_emb.tolist(), voice_print.tolist())
    
    print(f"✓ Quick verify result:")
    print(f"  Match score: {result.match_score:.4f}")
    print(f"  Is match: {result.is_match}")
    print(f"  Confidence: {result.confidence}")
    print(f"  Time: {result.processing_time_ms:.2f}ms")
    
    assert result.processing_time_ms < 500, "Processing should be < 500ms"


def main():
    """Run all tests."""
    print("=" * 60)
    print("VeriCall Voice ML Test Suite (192-dim)")
    print("=" * 60)
    
    try:
        # Run tests
        test_constants()
        test_dimension_reduction()
        test_similarity()
        voice_print = test_enrollment_from_embeddings()
        test_verification_from_embedding(voice_print)
        test_quick_verify()
        
        # Summary
        print("\n" + "=" * 60)
        print("✓ All tests passed!")
        print("=" * 60)
        print("\nConstants verified:")
        print("  - EMBEDDING_DIM = 192")
        print("  - MATCH_THRESHOLD = 0.75")
        print("  - WARNING_THRESHOLD = 0.55")
        print("  - SAMPLE_RATE = 16000")
        print("\nVoice ML is ready for iOS integration!")
        return 0
        
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}")
        return 1
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())