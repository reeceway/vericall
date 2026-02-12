import Foundation
import Accelerate

// MARK: - Voice Signature Model
/// Represents a 192-dimensional MFCC-based voice fingerprint
/// Stored securely in Keychain, never leaves the device
public struct VoiceSignature: Codable, Equatable {
    /// 192-dimensional MFCC-based fingerprint vector
    public let vector: [Float]
    
    /// Timestamp when signature was created
    public let createdAt: Date
    
    /// Sample rate used for extraction
    public let sampleRate: Double
    
    /// Number of phrases used to create this signature
    public let phraseCount: Int
    
    /// Unique identifier for the contact this signature belongs to
    public let contactId: String
    
    public init(vector: [Float], contactId: String, phraseCount: Int = 5, sampleRate: Double = 16000.0) {
        self.vector = vector
        self.contactId = contactId
        self.phraseCount = phraseCount
        self.sampleRate = sampleRate
        self.createdAt = Date()
    }
    
    /// Validate signature has correct dimensions
    public var isValid: Bool {
        return vector.count == LocalVoiceVerifier.featureDimension
    }
}

// MARK: - Voice Verification Result
public struct VoiceVerificationResult: Equatable {
    /// Weighted cosine similarity score (0.0 to 1.0)
    public let similarity: Float
    
    /// Whether the voice matches based on threshold
    public let isMatch: Bool
    
    /// Confidence level for UI display
    public let confidence: MatchConfidence
    
    /// Timestamp of verification
    public let timestamp: Date
    
    /// Duration of audio analyzed (seconds)
    public let analysisDuration: TimeInterval
    
    /// Processing time in milliseconds
    public let processingTimeMs: Double
    
    public init(similarity: Float, analysisDuration: TimeInterval, processingTimeMs: Double) {
        self.similarity = similarity
        self.analysisDuration = analysisDuration
        self.processingTimeMs = processingTimeMs
        self.timestamp = Date()
        self.confidence = MatchConfidence(from: similarity)
        self.isMatch = similarity > VoiceVerificationThresholds.matchThreshold
    }
    
    /// Match confidence levels for UI color coding
    public enum MatchConfidence: String, CaseIterable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        
        init(from similarity: Float) {
            switch similarity {
            case VoiceVerificationThresholds.highConfidence...1.0:
                self = .high
            case VoiceVerificationThresholds.mediumConfidence..<VoiceVerificationThresholds.highConfidence:
                self = .medium
            default:
                self = .low
            }
        }
        
        /// Color for UI display
        public var colorHex: String {
            switch self {
            case .high:
                return "#10B981" // Green
            case .medium:
                return "#F59E0B" // Yellow/Orange
            case .low:
                return "#EF4444" // Red
            }
        }
    }
}

// MARK: - Verification Thresholds
public struct VoiceVerificationThresholds {
    /// Threshold for high-confidence match (green badge)
    /// Per-group scoring: same-speaker scores typically 0.85+
    public static let highConfidence: Float = 0.85
    
    /// Threshold for medium confidence (yellow badge)
    /// 0.72-0.85 is plausible same speaker under noisy/degraded conditions
    /// Voice clones score ~0.70 — will show as orange warning
    public static let mediumConfidence: Float = 0.72
    
    /// Minimum threshold for any match consideration
    /// Per-group scoring: clones score ~0.698, different speakers ~0.545
    public static let matchThreshold: Float = 0.72
    
    /// Threshold for enrollment quality check
    /// Per-group scoring between different phrases of same speaker may be lower
    public static let enrollmentQualityThreshold: Float = 0.55
}

// MARK: - Audio Configuration
public struct AudioConfiguration {
    /// Sample rate in Hz (16kHz for voice)
    public static let sampleRate: Double = 16000.0
    
    /// Number of audio channels (mono)
    public static let channelCount: UInt32 = 1
    
    /// Bits per sample
    public static let bitsPerSample: UInt32 = 16
    
    /// Duration for enrollment phrases (seconds)
    public static let enrollmentPhraseDuration: TimeInterval = 5.0
    
    /// Duration for verification chunks (seconds)
    public static let verificationChunkDuration: TimeInterval = 5.0
    
    /// Buffer size for real-time processing
    public static let bufferSize: UInt32 = 1024
    
    /// Frame size for spectral analysis
    public static let frameSize: Int = 512
    
    /// Hop size between frames (50% overlap)
    public static let hopSize: Int = 256
    
    /// Number of frequency bands for feature extraction
    public static let frequencyBands: Int = 64
    
    /// Number of windows for temporal features
    public static let temporalWindows: Int = 32
}

// MARK: - Enrollment State
public enum EnrollmentState: Equatable {
    case notStarted
    case recording(phraseIndex: Int, progress: Double)
    case processing(phraseIndex: Int)
    case completed
    case failed(Error)
    
    public static func == (lhs: EnrollmentState, rhs: EnrollmentState) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted):
            return true
        case let (.recording(l1, l2), .recording(r1, r2)):
            return l1 == r1 && l2 == r2
        case let (.processing(l), .processing(r)):
            return l == r
        case (.completed, .completed):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

// MARK: - Verification State
public enum VerificationState: Equatable {
    case idle
    case capturing
    case analyzing
    case result(VoiceVerificationResult)
    case error(String)
    
    public var isActive: Bool {
        switch self {
        case .capturing, .analyzing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Audio Level Data
public struct AudioLevelData {
    /// Current amplitude (0.0 to 1.0)
    public let amplitude: Float
    
    /// Frequency spectrum data for visualization
    public let spectrum: [Float]
    
    /// Timestamp of sample
    public let timestamp: Date
    
    public init(amplitude: Float, spectrum: [Float]) {
        self.amplitude = amplitude
        self.spectrum = spectrum
        self.timestamp = Date()
    }
}

// MARK: - Enrollment Progress
public struct EnrollmentProgress {
    public let currentPhrase: Int
    public let totalPhrases: Int
    public let recordingProgress: Double
    public let isProcessing: Bool
    
    public var percentageComplete: Double {
        let phraseProgress = Double(currentPhrase) / Double(totalPhrases)
        let currentProgress = recordingProgress / Double(totalPhrases)
        return (phraseProgress + currentProgress) * 100.0
    }
    
    public var isComplete: Bool {
        return currentPhrase >= totalPhrases
    }
}
