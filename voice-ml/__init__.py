"""
VeriCall Voice ML Module

Speaker recognition and voice verification for real-time caller verification.
"""

from .speaker_model import SpeakerModel, get_speaker_model
from .voice_enrollment import VoiceEnrollmentService, get_enrollment_service, EnrollmentResult
from .voice_verification import VoiceVerificationService, get_verification_service, VerificationResult

__all__ = [
    'SpeakerModel',
    'get_speaker_model',
    'VoiceEnrollmentService',
    'get_enrollment_service',
    'EnrollmentResult',
    'VoiceVerificationService',
    'get_verification_service',
    'VerificationResult',
]