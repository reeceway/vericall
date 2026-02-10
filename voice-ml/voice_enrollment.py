"""
voice_enrollment.py - Voice Enrollment Service for VeriCall

Handles creation of voice prints from multiple audio samples.
Used during user onboarding to establish baseline voice characteristics.

Outputs 192-dimensional embeddings (reduced from Resemblyzer's 256).

Constants (MUST MATCH iOS):
- voiceEmbeddingDimension = 192
- voiceSampleRate = 16000
"""

import numpy as np
from typing import List, Dict, Any, Optional, Union
from dataclasses import dataclass
import io
from datetime import datetime

from speaker_model import SpeakerModel, get_speaker_model


@dataclass
class EnrollmentResult:
    """Result of voice enrollment process."""
    success: bool
    voice_print: Optional[np.ndarray] = None  # 192-dim embedding
    embedding_bytes: Optional[bytes] = None
    embedding_list: Optional[List[float]] = None  # 192 floats for JSON
    message: str = ""
    samples_processed: int = 0
    samples_failed: int = 0
    quality_score: float = 0.0


class VoiceEnrollmentService:
    """
    Service for enrolling users with voice prints.
    
    Processes multiple audio samples to create a robust 192-dimension
    voice print that represents the user's unique voice characteristics.
    
    Note: The iOS app typically extracts embeddings on-device and sends
    them directly to the backend. This service is for server-side processing
    or reference implementation.
    """
    
    # Configuration
    REQUIRED_SAMPLES = 5  # iOS sends 5 samples
    MIN_QUALITY_SCORE = 0.70
    
    # MUST MATCH iOS
    EMBEDDING_DIM = 192
    
    def __init__(self, model: Optional[SpeakerModel] = None):
        """
        Initialize the enrollment service.
        
        Args:
            model: Optional speaker model instance (uses singleton if not provided)
        """
        self.model = model or get_speaker_model()
    
    def enroll_from_audio(self, 
                          audio_samples: List[Union[bytes, io.BytesIO]],
                          validate_quality: bool = True) -> EnrollmentResult:
        """
        Create a voice print from multiple audio samples.
        
        Args:
            audio_samples: List of audio samples (bytes or BytesIO)
            validate_quality: Whether to validate audio quality
            
        Returns:
            EnrollmentResult with 192-dim voice print and status
        """
        if len(audio_samples) < self.REQUIRED_SAMPLES:
            return EnrollmentResult(
                success=False,
                message=f"Insufficient samples: {len(audio_samples)}/{self.REQUIRED_SAMPLES} required"
            )
        
        processed_count = 0
        failed_count = 0
        embeddings = []
        
        # Process each sample
        for i, sample in enumerate(audio_samples[:self.REQUIRED_SAMPLES]):
            try:
                # Convert BytesIO to bytes if needed
                if isinstance(sample, io.BytesIO):
                    sample.seek(0)
                    sample = sample.read()
                
                # Extract 192-dim embedding
                embedding = self.model.extract_embedding(sample)
                embeddings.append(embedding)
                processed_count += 1
                
            except Exception as e:
                failed_count += 1
                print(f"Failed to process sample {i+1}: {e}")
                continue
        
        # Check if we have enough valid embeddings
        if len(embeddings) < 2:
            return EnrollmentResult(
                success=False,
                message=f"Too few valid samples: {len(embeddings)} (need at least 2)",
                samples_processed=processed_count,
                samples_failed=failed_count
            )
        
        # Create voice print from embeddings (average)
        voice_print = np.mean(embeddings, axis=0)
        voice_print = voice_print / (np.linalg.norm(voice_print) + 1e-8)
        
        # Calculate quality score
        quality_score = self._calculate_quality_score(embeddings)
        
        # Validate quality if requested
        if validate_quality and quality_score < self.MIN_QUALITY_SCORE:
            return EnrollmentResult(
                success=False,
                voice_print=voice_print,
                message=f"Voice print quality too low: {quality_score:.2f} (min: {self.MIN_QUALITY_SCORE})",
                samples_processed=processed_count,
                samples_failed=failed_count,
                quality_score=quality_score
            )
        
        # Convert to storage formats
        embedding_bytes = self.model.embedding_to_bytes(voice_print)
        embedding_list = self.model.embedding_to_list(voice_print)
        
        return EnrollmentResult(
            success=True,
            voice_print=voice_print,
            embedding_bytes=embedding_bytes,
            embedding_list=embedding_list,
            message="Voice enrollment successful",
            samples_processed=processed_count,
            samples_failed=failed_count,
            quality_score=quality_score
        )
    
    def enroll_from_embeddings(self, 
                               embeddings: List[List[float]],
                               validate_quality: bool = True) -> EnrollmentResult:
        """
        Create a voice print from pre-computed embeddings.
        
        This is the primary method used when iOS sends embeddings directly.
        
        Args:
            embeddings: List of 192-dim embeddings from iOS
            validate_quality: Whether to validate quality
            
        Returns:
            EnrollmentResult with voice print
        """
        if len(embeddings) < 1:
            return EnrollmentResult(
                success=False,
                message="At least one embedding required"
            )
        
        # Convert to numpy arrays
        embedding_arrays = []
        for emb in embeddings:
            if len(emb) != self.EMBEDDING_DIM:
                return EnrollmentResult(
                    success=False,
                    message=f"Invalid embedding dimension: {len(emb)} (expected {self.EMBEDDING_DIM})"
                )
            embedding_arrays.append(np.array(emb, dtype=np.float32))
        
        # Create voice print (average of embeddings)
        voice_print = np.mean(embedding_arrays, axis=0)
        voice_print = voice_print / (np.linalg.norm(voice_print) + 1e-8)
        
        # Calculate quality
        quality_score = self._calculate_quality_score(embedding_arrays)
        
        if validate_quality and quality_score < self.MIN_QUALITY_SCORE:
            return EnrollmentResult(
                success=False,
                voice_print=voice_print,
                message=f"Quality too low: {quality_score:.2f}",
                quality_score=quality_score
            )
        
        return EnrollmentResult(
            success=True,
            voice_print=voice_print,
            embedding_bytes=self.model.embedding_to_bytes(voice_print),
            embedding_list=self.model.embedding_to_list(voice_print),
            message="Enrollment successful",
            samples_processed=len(embeddings),
            samples_failed=0,
            quality_score=quality_score
        )
    
    def _calculate_quality_score(self, embeddings: List[np.ndarray]) -> float:
        """
        Calculate quality score based on consistency of samples.
        
        Higher consistency between samples = higher quality score.
        
        Args:
            embeddings: List of 192-dim embeddings from multiple samples
            
        Returns:
            Quality score between 0.0 and 1.0
        """
        if len(embeddings) < 2:
            return 0.0
        
        # Compute pairwise similarities
        similarities = []
        for i in range(len(embeddings)):
            for j in range(i + 1, len(embeddings)):
                sim = self.model.compute_similarity(embeddings[i], embeddings[j])
                similarities.append(sim)
        
        # Quality is the average similarity between samples
        quality_score = np.mean(similarities)
        
        return float(quality_score)
    
    def validate_sample(self, audio_data: Union[bytes, io.BytesIO]) -> Dict[str, Any]:
        """
        Validate a single audio sample before enrollment.
        
        Args:
            audio_data: Audio sample to validate
            
        Returns:
            Validation result with details
        """
        try:
            # Convert BytesIO to bytes if needed
            if isinstance(audio_data, io.BytesIO):
                audio_data.seek(0)
                audio_data = audio_data.read()
            
            # Try to preprocess
            wav = self.model.preprocess_audio(audio_data)
            duration = len(wav) / self.model.SAMPLE_RATE
            
            # Check audio levels
            rms = np.sqrt(np.mean(wav**2))
            
            # Determine quality
            quality = "good"
            issues = []
            
            if duration < 3.0:
                issues.append("Audio too short (recommend 3+ seconds)")
            
            if rms < 0.01:
                issues.append("Audio level too low")
                quality = "poor"
            elif rms > 0.9:
                issues.append("Audio level too high (possible clipping)")
                quality = "fair"
            
            return {
                "valid": True,
                "duration": float(duration),
                "rms_level": float(rms),
                "quality": quality,
                "issues": issues
            }
            
        except Exception as e:
            return {
                "valid": False,
                "error": str(e),
                "quality": "invalid"
            }


# Singleton instance
_enrollment_service = None

def get_enrollment_service() -> VoiceEnrollmentService:
    """Get or create the singleton enrollment service instance."""
    global _enrollment_service
    if _enrollment_service is None:
        _enrollment_service = VoiceEnrollmentService()
    return _enrollment_service