"""
voice_verification.py - Voice Verification Service for VeriCall

Real-time voice verification during calls.
Compares incoming 192-dim embeddings against stored voice prints.
Target: < 500ms processing time per verification.

Constants (MUST MATCH iOS):
- voiceEmbeddingDimension = 192
- voiceMatchThreshold = 0.75
- voiceWarningThreshold = 0.55
"""

import numpy as np
from typing import Dict, Any, Optional, Union, List
from dataclasses import dataclass
from datetime import datetime
import io
import time

from speaker_model import SpeakerModel, get_speaker_model


@dataclass
class VerificationResult:
    """Result of voice verification process."""
    match_score: float  # 0.0-1.0
    is_match: bool      # True if match_score >= 0.75
    confidence: str     # "high", "medium", "low"
    processing_time_ms: float
    timestamp: str
    error: Optional[str] = None


@dataclass
class VerificationSession:
    """Tracks verification state during a call."""
    user_id: str
    call_id: str
    voice_print: np.ndarray  # 192-dim
    recent_scores: List[float]
    last_verified_at: Optional[datetime] = None
    consecutive_matches: int = 0
    consecutive_mismatches: int = 0
    alert_triggered: bool = False


class VoiceVerificationService:
    """
    Service for real-time voice verification during calls.
    
    Processes 192-dim voice embeddings from iOS and compares
    against stored voice prints to verify caller identity.
    
    Performance target: < 500ms per verification
    
    Constants (MUST MATCH iOS):
    - MATCH_THRESHOLD = 0.75
    - WARNING_THRESHOLD = 0.55
    - EMBEDDING_DIM = 192
    """
    
    # CONSTANTS - MUST MATCH iOS
    MATCH_THRESHOLD = 0.75       # isMatch = true if score >= 0.75
    WARNING_THRESHOLD = 0.55     # Below this = warning/alert level
    EMBEDDING_DIM = 192
    
    # Session management
    CONSECUTIVE_MISMATCH_LIMIT = 2  # Trigger alert after this many mismatches
    SCORE_HISTORY_SIZE = 5          # Number of recent scores to track
    
    def __init__(self, model: Optional[SpeakerModel] = None):
        """
        Initialize the verification service.
        
        Args:
            model: Optional speaker model instance
        """
        self.model = model or get_speaker_model()
        self.active_sessions: Dict[str, VerificationSession] = {}
    
    def create_session(self, 
                       call_id: str, 
                       user_id: str, 
                       voice_print: Union[np.ndarray, List[float], bytes]) -> VerificationSession:
        """
        Create a new verification session for a call.
        
        Args:
            call_id: Unique call identifier
            user_id: User being verified
            voice_print: Stored voice print (192-dim numpy array, list, or bytes)
            
        Returns:
            VerificationSession object
        """
        # Convert voice print to numpy array if needed
        if isinstance(voice_print, list):
            voice_print = self.model.embedding_from_list(voice_print)
        elif isinstance(voice_print, bytes):
            voice_print = self.model.embedding_from_bytes(voice_print)
        
        # Validate dimension
        if len(voice_print) != self.EMBEDDING_DIM:
            raise ValueError(f"Voice print must be {self.EMBEDDING_DIM} dimensions, got {len(voice_print)}")
        
        session = VerificationSession(
            user_id=user_id,
            call_id=call_id,
            voice_print=voice_print,
            recent_scores=[],
            last_verified_at=None,
            consecutive_matches=0,
            consecutive_mismatches=0,
            alert_triggered=False
        )
        
        self.active_sessions[call_id] = session
        return session
    
    def verify_from_audio(self, 
                          call_id: str,
                          audio_data: Union[bytes, io.BytesIO],
                          user_id: Optional[str] = None) -> VerificationResult:
        """
        Verify a voice sample (audio) against the stored voice print.
        
        Args:
            call_id: Active call identifier
            audio_data: Voice sample audio data
            user_id: Optional user ID for session validation
            
        Returns:
            VerificationResult with match score and status
        """
        start_time = time.time()
        
        try:
            # Get session
            session = self.active_sessions.get(call_id)
            if session is None:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error="No active verification session for this call"
                )
            
            # Validate user if provided
            if user_id and session.user_id != user_id:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error="User ID mismatch"
                )
            
            # Convert BytesIO to bytes if needed
            if isinstance(audio_data, io.BytesIO):
                audio_data.seek(0)
                audio_data = audio_data.read()
            
            # Extract 192-dim embedding from sample
            sample_embedding = self.model.extract_embedding(audio_data)
            
            # Compute similarity
            score = self.model.compute_similarity(sample_embedding, session.voice_print)
            
            # Determine match status (using 0.75 threshold)
            is_match = score >= self.MATCH_THRESHOLD
            
            # Determine confidence level
            if score >= 0.90:
                confidence = "high"
            elif score >= 0.70:
                confidence = "medium"
            else:
                confidence = "low"
            
            # Update session state
            self._update_session(session, score, is_match)
            
            # Calculate processing time
            processing_time_ms = (time.time() - start_time) * 1000
            
            return VerificationResult(
                match_score=round(score, 4),
                is_match=is_match,
                confidence=confidence,
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat()
            )
            
        except Exception as e:
            processing_time_ms = (time.time() - start_time) * 1000
            return VerificationResult(
                match_score=0.0,
                is_match=False,
                confidence="low",
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat(),
                error=str(e)
            )
    
    def verify_from_embedding(self,
                              call_id: str,
                              embedding: List[float],
                              user_id: Optional[str] = None) -> VerificationResult:
        """
        Verify a pre-computed embedding against the stored voice print.
        
        This is the primary method used when iOS sends embeddings directly.
        
        Args:
            call_id: Active call identifier
            embedding: 192-dim voice embedding from iOS
            user_id: Optional user ID for session validation
            
        Returns:
            VerificationResult
        """
        start_time = time.time()
        
        try:
            # Get session
            session = self.active_sessions.get(call_id)
            if session is None:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error="No active verification session for this call"
                )
            
            # Validate user if provided
            if user_id and session.user_id != user_id:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error="User ID mismatch"
                )
            
            # Validate embedding dimension
            if len(embedding) != self.EMBEDDING_DIM:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error=f"Invalid embedding dimension: {len(embedding)} (expected {self.EMBEDDING_DIM})"
                )
            
            # Convert to numpy
            sample_embedding = np.array(embedding, dtype=np.float32)
            
            # Compute similarity
            score = self.model.compute_similarity(sample_embedding, session.voice_print)
            
            # Determine match (threshold 0.75)
            is_match = score >= self.MATCH_THRESHOLD
            
            # Determine confidence
            if score >= 0.90:
                confidence = "high"
            elif score >= 0.70:
                confidence = "medium"
            else:
                confidence = "low"
            
            # Update session
            self._update_session(session, score, is_match)
            
            # Calculate processing time
            processing_time_ms = (time.time() - start_time) * 1000
            
            return VerificationResult(
                match_score=round(score, 4),
                is_match=is_match,
                confidence=confidence,
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat()
            )
            
        except Exception as e:
            processing_time_ms = (time.time() - start_time) * 1000
            return VerificationResult(
                match_score=0.0,
                is_match=False,
                confidence="low",
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat(),
                error=str(e)
            )
    
    def _update_session(self, session: VerificationSession, score: float, is_match: bool):
        """Update session state with new verification result."""
        # Add score to history
        session.recent_scores.append(score)
        if len(session.recent_scores) > self.SCORE_HISTORY_SIZE:
            session.recent_scores.pop(0)
        
        session.last_verified_at = datetime.utcnow()
        
        # Update consecutive counters
        if is_match:
            session.consecutive_matches += 1
            session.consecutive_mismatches = 0
        else:
            session.consecutive_mismatches += 1
            session.consecutive_matches = 0
        
        # Check for alert condition (below WARNING_THRESHOLD)
        if session.consecutive_mismatches >= self.CONSECUTIVE_MISMATCH_LIMIT:
            if score < self.WARNING_THRESHOLD:
                session.alert_triggered = True
    
    def should_trigger_alert(self, call_id: str) -> bool:
        """
        Check if voice mismatch alert should be triggered.
        
        Args:
            call_id: Active call identifier
            
        Returns:
            True if alert should be triggered
        """
        session = self.active_sessions.get(call_id)
        if session is None:
            return False
        return session.alert_triggered
    
    def get_session_status(self, call_id: str) -> Optional[Dict[str, Any]]:
        """
        Get current verification session status.
        
        Args:
            call_id: Active call identifier
            
        Returns:
            Session status dictionary or None
        """
        session = self.active_sessions.get(call_id)
        if session is None:
            return None
        
        avg_score = np.mean(session.recent_scores) if session.recent_scores else 0.0
        
        return {
            "user_id": session.user_id,
            "call_id": session.call_id,
            "recent_scores": session.recent_scores,
            "average_score": round(avg_score, 4),
            "consecutive_matches": session.consecutive_matches,
            "consecutive_mismatches": session.consecutive_mismatches,
            "alert_triggered": session.alert_triggered,
            "last_verified_at": session.last_verified_at.isoformat() if session.last_verified_at else None
        }
    
    def end_session(self, call_id: str):
        """
        End a verification session and clean up.
        
        Args:
            call_id: Active call identifier
        """
        if call_id in self.active_sessions:
            del self.active_sessions[call_id]
    
    def quick_verify(self, 
                     embedding: List[float],
                     voice_print: Union[np.ndarray, List[float], bytes]) -> VerificationResult:
        """
        Quick verification without session management.
        
        Args:
            embedding: 192-dim voice embedding
            voice_print: Stored voice print
            
        Returns:
            VerificationResult
        """
        start_time = time.time()
        
        try:
            # Convert voice print if needed
            if isinstance(voice_print, list):
                voice_print = self.model.embedding_from_list(voice_print)
            elif isinstance(voice_print, bytes):
                voice_print = self.model.embedding_from_bytes(voice_print)
            
            # Validate dimension
            if len(embedding) != self.EMBEDDING_DIM:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error=f"Invalid embedding dimension: {len(embedding)}"
                )
            
            if len(voice_print) != self.EMBEDDING_DIM:
                return VerificationResult(
                    match_score=0.0,
                    is_match=False,
                    confidence="low",
                    processing_time_ms=0.0,
                    timestamp=datetime.utcnow().isoformat(),
                    error=f"Invalid voice print dimension: {len(voice_print)}"
                )
            
            # Convert embedding
            sample_embedding = np.array(embedding, dtype=np.float32)
            
            # Compute similarity
            score = self.model.compute_similarity(sample_embedding, voice_print)
            
            # Determine match (threshold 0.75)
            is_match = score >= self.MATCH_THRESHOLD
            
            # Determine confidence
            if score >= 0.90:
                confidence = "high"
            elif score >= 0.70:
                confidence = "medium"
            else:
                confidence = "low"
            
            processing_time_ms = (time.time() - start_time) * 1000
            
            return VerificationResult(
                match_score=round(score, 4),
                is_match=is_match,
                confidence=confidence,
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat()
            )
            
        except Exception as e:
            processing_time_ms = (time.time() - start_time) * 1000
            return VerificationResult(
                match_score=0.0,
                is_match=False,
                confidence="low",
                processing_time_ms=round(processing_time_ms, 2),
                timestamp=datetime.utcnow().isoformat(),
                error=str(e)
            )


# Singleton instance
_verification_service = None

def get_verification_service() -> VoiceVerificationService:
    """Get or create the singleton verification service instance."""
    global _verification_service
    if _verification_service is None:
        _verification_service = VoiceVerificationService()
    return _verification_service