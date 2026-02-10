"""
speaker_model.py - Core Speaker Recognition Model for VeriCall

Uses Resemblyzer for voice embedding extraction.
Provides 192-dimensional voice embeddings (reduced from Resemblyzer's 256).

Constants (MUST MATCH iOS):
- voiceEmbeddingDimension = 192
- voiceMatchThreshold = 0.75
- voiceWarningThreshold = 0.55
- voiceSampleRate = 16000

Audio format requirements:
- WAV format
- 16kHz sample rate
- Mono channel
- 16-bit PCM
"""

import numpy as np
import torch
from pathlib import Path
from typing import Union, List, Tuple, Optional
import tempfile
import io

# Audio processing
import librosa
from scipy.spatial.distance import cosine

# Try to import Resemblyzer, fall back to alternative if not available
try:
    from resemblyzer import VoiceEncoder, preprocess_wav
    RESEMBLYZER_AVAILABLE = True
except ImportError:
    RESEMBLYZER_AVAILABLE = False
    print("Warning: Resemblyzer not available, using fallback implementation")


class SpeakerModel:
    """
    Speaker recognition model for voice verification.
    
    Extracts voice embeddings using Resemblyzer (256-dim) and
    reduces to 192-dim for storage/comparison.
    
    Constants (MUST MATCH iOS):
    - EMBEDDING_DIM = 192
    - MATCH_THRESHOLD = 0.75
    - WARNING_THRESHOLD = 0.55
    """
    
    # CONSTANTS - MUST MATCH iOS
    EMBEDDING_DIM = 192           # Reduced from Resemblyzer's 256
    RAW_DIM = 256                 # Resemblyzer output dimension
    MATCH_THRESHOLD = 0.75        # isMatch = true if score >= 0.75
    WARNING_THRESHOLD = 0.55      # Below this = warning level
    
    # Audio configuration
    SAMPLE_RATE = 16000           # MUST MATCH iOS voiceSampleRate
    DURATION_MIN = 2.0            # Minimum audio duration in seconds
    DURATION_MAX = 30.0           # Maximum audio duration in seconds
    
    def __init__(self, model_path: Optional[str] = None):
        """
        Initialize the speaker model.
        
        Args:
            model_path: Optional path to a pre-trained model checkpoint
        """
        self.encoder = None
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self._projection_matrix = None  # For 256->192 reduction
        
        if RESEMBLYZER_AVAILABLE:
            self._init_resemblyzer()
        else:
            self._init_fallback()
        
        # Initialize projection matrix for dimension reduction
        self._init_projection()
    
    def _init_resemblyzer(self):
        """Initialize Resemblyzer voice encoder."""
        try:
            self.encoder = VoiceEncoder(device=self.device)
            print(f"Resemblyzer initialized on {self.device}")
        except Exception as e:
            print(f"Failed to initialize Resemblyzer: {e}")
            self._init_fallback()
    
    def _init_fallback(self):
        """Initialize fallback MFCC-based encoder."""
        print("Using fallback MFCC-based speaker recognition")
        self.fallback_model = None
    
    def _init_projection(self):
        """
        Initialize projection matrix for 256 -> 192 dimension reduction.
        
        Uses a random projection with orthonormal columns.
        This preserves relative distances while reducing dimensions.
        """
        # Create random projection matrix
        rng = np.random.RandomState(42)  # Fixed seed for reproducibility
        proj = rng.randn(self.RAW_DIM, self.EMBEDDING_DIM)
        
        # Orthogonalize using QR decomposition
        q, _ = np.linalg.qr(proj)
        self._projection_matrix = q.astype(np.float32)
    
    def reduce_dimensions(self, embedding_256: np.ndarray) -> np.ndarray:
        """
        Reduce 256-dimension embedding to 192-dimension.
        
        Uses learned projection matrix to preserve similarity relationships.
        
        Args:
            embedding_256: 256-dimension embedding from Resemblyzer
            
        Returns:
            192-dimension embedding
        """
        if len(embedding_256) == self.EMBEDDING_DIM:
            return embedding_256
        
        if len(embedding_256) != self.RAW_DIM:
            raise ValueError(f"Expected {self.RAW_DIM}-dim embedding, got {len(embedding_256)}")
        
        # Project to lower dimension
        embedding_192 = np.dot(embedding_256, self._projection_matrix)
        
        # Renormalize
        norm = np.linalg.norm(embedding_192)
        if norm > 0:
            embedding_192 = embedding_192 / norm
        
        return embedding_192
    
    def preprocess_audio(self, audio_data: Union[bytes, np.ndarray, str, io.BytesIO]) -> np.ndarray:
        """
        Preprocess audio for embedding extraction.
        
        Args:
            audio_data: Raw audio bytes, numpy array, file path, or BytesIO object
            
        Returns:
            Preprocessed audio waveform (numpy array)
        """
        # Convert various input types to numpy array
        if isinstance(audio_data, str):
            # File path
            wav, sr = librosa.load(audio_data, sr=self.SAMPLE_RATE, mono=True)
        elif isinstance(audio_data, bytes):
            # Raw bytes (assume WAV format)
            wav, sr = librosa.load(io.BytesIO(audio_data), sr=self.SAMPLE_RATE, mono=True)
        elif isinstance(audio_data, io.BytesIO):
            # BytesIO object
            audio_data.seek(0)
            wav, sr = librosa.load(audio_data, sr=self.SAMPLE_RATE, mono=True)
        elif isinstance(audio_data, np.ndarray):
            # Already a numpy array
            wav = audio_data
            sr = self.SAMPLE_RATE
        else:
            raise ValueError(f"Unsupported audio data type: {type(audio_data)}")
        
        # Resample if needed
        if sr != self.SAMPLE_RATE:
            wav = librosa.resample(wav, orig_sr=sr, target_sr=self.SAMPLE_RATE)
        
        # Ensure mono
        if len(wav.shape) > 1:
            wav = librosa.to_mono(wav)
        
        # Normalize
        if wav.max() > 1.0 or wav.min() < -1.0:
            wav = wav / max(abs(wav.max()), abs(wav.min()))
        
        # Apply pre-emphasis filter to boost high frequencies
        wav = librosa.effects.preemphasis(wav)
        
        # Trim silence
        wav, _ = librosa.effects.trim(wav, top_db=20)
        
        # Check duration
        duration = len(wav) / self.SAMPLE_RATE
        if duration < self.DURATION_MIN:
            raise ValueError(f"Audio too short: {duration:.2f}s (min: {self.DURATION_MIN}s)")
        if duration > self.DURATION_MAX:
            # Truncate if too long
            wav = wav[:int(self.DURATION_MAX * self.SAMPLE_RATE)]
        
        return wav
    
    def extract_embedding(self, audio_data: Union[bytes, np.ndarray, str, io.BytesIO]) -> np.ndarray:
        """
        Extract 192-dimensional voice embedding from audio.
        
        Args:
            audio_data: Raw audio bytes, numpy array, file path, or BytesIO object
            
        Returns:
            192-dimensional embedding vector (numpy array)
        """
        # Preprocess audio
        wav = self.preprocess_audio(audio_data)
        
        if RESEMBLYZER_AVAILABLE and self.encoder is not None:
            return self._extract_embedding_resemblyzer(wav)
        else:
            return self._extract_embedding_fallback(wav)
    
    def _extract_embedding_resemblyzer(self, wav: np.ndarray) -> np.ndarray:
        """Extract embedding using Resemblyzer and reduce to 192-dim."""
        if len(wav) < 0.5 * self.SAMPLE_RATE:
            raise ValueError("Audio too short for embedding extraction")
        
        # Use Resemblyzer's preprocess_wav for additional processing
        wav_processed = preprocess_wav(wav, self.SAMPLE_RATE)
        
        # Extract 256-dim embedding
        embedding_256 = self.encoder.embed_utterance(wav_processed)
        
        # Reduce to 192-dim
        embedding_192 = self.reduce_dimensions(embedding_256)
        
        return embedding_192
    
    def _extract_embedding_fallback(self, wav: np.ndarray) -> np.ndarray:
        """
        Extract 192-dim embedding using MFCC-based fallback.
        Used when Resemblyzer is not available.
        """
        # Extract MFCC features
        mfccs = librosa.feature.mfcc(
            y=wav, 
            sr=self.SAMPLE_RATE, 
            n_mfcc=48,
            n_fft=512,
            hop_length=256
        )
        
        # Extract additional features
        chroma = librosa.feature.chroma_stft(y=wav, sr=self.SAMPLE_RATE)
        mel = librosa.feature.melspectrogram(y=wav, sr=self.SAMPLE_RATE)
        mel_db = librosa.power_to_db(mel, ref=np.max)
        
        # Compute statistics for each feature
        mfcc_stats = self._compute_statistics(mfccs)
        chroma_stats = self._compute_statistics(chroma)
        mel_stats = self._compute_statistics(mel_db)
        
        # Concatenate all features
        features = np.concatenate([mfcc_stats, chroma_stats, mel_stats])
        
        # Pad or truncate to 192 dimensions
        if len(features) < self.EMBEDDING_DIM:
            features = np.pad(features, (0, self.EMBEDDING_DIM - len(features)))
        elif len(features) > self.EMBEDDING_DIM:
            features = features[:self.EMBEDDING_DIM]
        
        # Normalize
        features = features / (np.linalg.norm(features) + 1e-8)
        
        return features
    
    def _compute_statistics(self, features: np.ndarray) -> np.ndarray:
        """Compute statistics (mean, std, min, max) for feature matrix."""
        return np.concatenate([
            np.mean(features, axis=1),
            np.std(features, axis=1),
            np.min(features, axis=1),
            np.max(features, axis=1)
        ])
    
    def compute_similarity(self, embedding1: np.ndarray, embedding2: np.ndarray) -> float:
        """
        Compute cosine similarity between two embeddings.
        
        Args:
            embedding1: First embedding vector (192-dim)
            embedding2: Second embedding vector (192-dim)
            
        Returns:
            Similarity score between 0.0 and 1.0
        """
        # Ensure embeddings are 1D
        embedding1 = embedding1.flatten()
        embedding2 = embedding2.flatten()
        
        # Normalize
        e1 = embedding1 / (np.linalg.norm(embedding1) + 1e-8)
        e2 = embedding2 / (np.linalg.norm(embedding2) + 1e-8)
        
        # Compute cosine similarity
        similarity = np.dot(e1, e2)
        
        # Clamp to [0, 1]
        return float(max(0.0, min(1.0, similarity)))
    
    def verify_voice(self, 
                     sample_embedding: np.ndarray, 
                     reference_embedding: np.ndarray) -> Tuple[float, bool, str]:
        """
        Verify if a voice sample matches a reference voice print.
        
        Args:
            sample_embedding: Embedding of the voice sample to verify (192-dim)
            reference_embedding: Stored reference voice print (192-dim)
            
        Returns:
            Tuple of (match_score, is_match, confidence_level)
            is_match = true if match_score >= 0.75
        """
        # Compute similarity
        score = self.compute_similarity(sample_embedding, reference_embedding)
        
        # Determine match (using threshold 0.75)
        is_match = score >= self.MATCH_THRESHOLD
        
        # Determine confidence level
        if score >= 0.90:
            confidence = "high"
        elif score >= 0.70:
            confidence = "medium"
        else:
            confidence = "low"
        
        return score, is_match, confidence
    
    def create_voice_print(self, audio_samples: List[Union[bytes, np.ndarray, str, io.BytesIO]]) -> np.ndarray:
        """
        Create a voice print from multiple audio samples.
        
        Args:
            audio_samples: List of audio samples (typically 3-5 samples)
            
        Returns:
            Average embedding representing the voice print (192-dim)
        """
        if len(audio_samples) < 1:
            raise ValueError("At least one audio sample required")
        
        # Extract embeddings from all samples
        embeddings = []
        for sample in audio_samples:
            try:
                embedding = self.extract_embedding(sample)
                embeddings.append(embedding)
            except Exception as e:
                print(f"Failed to process sample: {e}")
                continue
        
        if len(embeddings) == 0:
            raise ValueError("No valid embeddings extracted from samples")
        
        # Average the embeddings
        voice_print = np.mean(embeddings, axis=0)
        
        # Normalize
        voice_print = voice_print / (np.linalg.norm(voice_print) + 1e-8)
        
        return voice_print
    
    def calculate_quality(self, embedding: np.ndarray) -> float:
        """
        Calculate voice print quality score.
        
        Args:
            embedding: Voice embedding vector
            
        Returns:
            Quality score between 0.0 and 1.0
        """
        variance = np.var(embedding)
        magnitude = np.linalg.norm(embedding)
        quality = min(1.0, (variance * 10 + magnitude * 0.1) / 2)
        return float(max(0.0, quality))
    
    def embedding_to_bytes(self, embedding: np.ndarray) -> bytes:
        """Convert embedding to bytes for storage."""
        return embedding.astype(np.float32).tobytes()
    
    def embedding_from_bytes(self, data: bytes) -> np.ndarray:
        """Convert bytes back to embedding."""
        embedding = np.frombuffer(data, dtype=np.float32)
        return embedding
    
    def embedding_to_list(self, embedding: np.ndarray) -> List[float]:
        """Convert embedding to list for JSON serialization."""
        return embedding.tolist()
    
    def embedding_from_list(self, data: List[float]) -> np.ndarray:
        """Convert list to embedding."""
        return np.array(data, dtype=np.float32)


# Singleton instance
_model_instance = None

def get_speaker_model() -> SpeakerModel:
    """Get or create the singleton speaker model instance."""
    global _model_instance
    if _model_instance is None:
        _model_instance = SpeakerModel()
    return _model_instance