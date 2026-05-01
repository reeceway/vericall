import Foundation
import Accelerate

// MARK: - Deepfake Detection Result

/// Result from the on-device AI deepfake detection model.
public struct DeepfakeDetectionResult: Equatable {
    /// Whether the audio is classified as human (true) or AI-generated (false).
    public let isHuman: Bool

    /// Model confidence score (0.0 to 1.0).
    public let confidence: Float

    /// Raw classification label from the model ("real" or "fake").
    public let label: String

    /// Timestamp of this detection.
    public let timestamp: Date

    /// Time taken to run inference in milliseconds.
    public let processingTimeMs: Double

    public init(
        isHuman: Bool,
        confidence: Float,
        label: String,
        timestamp: Date = Date(),
        processingTimeMs: Double
    ) {
        self.isHuman = isHuman
        self.confidence = confidence
        self.label = label
        self.timestamp = timestamp
        self.processingTimeMs = processingTimeMs
    }
}

// MARK: - Audio Configuration

public struct AudioConfiguration {
    public static let sampleRate: Double = 16_000.0
    public static let remoteSampleRate: Double = 48_000.0
    public static let analysisWindowSeconds: Double = 3.0
    public static let analysisWindowSamples: Int = 48_000  // 3s x 16kHz
    public static let fbankFrames: Int = 300
    public static let fbankBands: Int = 80
    public static let embeddingDim: Int = 192
    public static let voiceEmbedderVersion: String = "voice-embedder-stage1-epoch1-best-20260401"
    public static let spoofDetectorVersion: String = "vericall-spoof-layer3-webrtc-20260403"
    public static let spoofNeuralWeightCall: Float = 0.00
    public static let spoofClassicWeightCall: Float = 1.00
    public static let spoofHumanThresholdCall: Float = 0.90
    // cloneProbability is spoof probability. These values match the release
    // calibration used with the live 240-feature classic spoof model.
    public static let spoofUncertaintyMarginCall: Float = 0.05
    public static let spoofExtremeFakeThresholdCall: Float = 0.98
    public static let spoofImmediateFakeThresholdCall: Float = 0.995
    public static let spoofWarmupWindowsCall: Int = 4
    public static let spoofHistoryWindowsCall: Int = 5
    public static let spoofAudibleRMSCall: Float = 0.003
    public static let spoofDecisionSpeechActivityCall: Float = 0.20
    public static let speakerMatchThresholdCall: Float = 0.90
}

// MARK: - Audio Level Data

public struct AudioLevelData {
    /// Current amplitude (0.0 to 1.0).
    public let amplitude: Float

    /// Frequency spectrum data for visualization.
    public let spectrum: [Float]

    /// Timestamp of sample.
    public let timestamp: Date

    public init(amplitude: Float, spectrum: [Float]) {
        self.amplitude = amplitude
        self.spectrum = spectrum
        self.timestamp = Date()
    }
}

// MARK: - Spoof Detection Result

public enum AnalysisConfidence: String, Codable, Equatable {
    case high
    case low
}

public enum SpoofVerdict: String, Codable, Equatable {
    case human
    case likelyFake
    case uncertain
}

/// Result from VeriCallSpoofDetector (Wav2Vec2 fine-tuned)
public struct SpoofResult: Equatable {
    public let cloneProbability: Float
    public let isHuman: Bool
    public let verdict: SpoofVerdict
    public let confidence: AnalysisConfidence
    public let threshold: Float
    public let supportingWindows: Int
    public let processingTimeMs: Double
    public let timestamp: Date
    public let rms: Float?
    public let speechActivityRatio: Float?

    public init(
        cloneProbability: Float,
        confidence: AnalysisConfidence = .high,
        threshold: Float = AudioConfiguration.spoofHumanThresholdCall,
        supportingWindows: Int = 1,
        processingTimeMs: Double,
        rms: Float? = nil,
        speechActivityRatio: Float? = nil,
        timestamp: Date = Date()
    ) {
        self.cloneProbability = cloneProbability
        self.confidence = confidence
        self.threshold = threshold
        self.supportingWindows = supportingWindows
        self.rms = rms
        self.speechActivityRatio = speechActivityRatio

        let lower = max(0, threshold - AudioConfiguration.spoofUncertaintyMarginCall)
        let upper = min(1, threshold + AudioConfiguration.spoofUncertaintyMarginCall)

        if cloneProbability >= AudioConfiguration.spoofImmediateFakeThresholdCall {
            self.verdict = .likelyFake
        } else if confidence == .low {
            self.verdict = .uncertain
        } else if cloneProbability <= lower {
            self.verdict = .human
        } else if supportingWindows < AudioConfiguration.spoofWarmupWindowsCall {
            self.verdict = .uncertain
        } else if cloneProbability >= upper && cloneProbability >= AudioConfiguration.spoofExtremeFakeThresholdCall {
            self.verdict = .likelyFake
        } else {
            self.verdict = .uncertain
        }

        self.isHuman = self.verdict == .human
        self.processingTimeMs = processingTimeMs
        self.timestamp = timestamp
    }
}

// MARK: - Speaker Verification Result

/// Result from VoiceEmbedder (ECAPA-TDNN stage1 epoch1_best)
public struct SpeakerResult: Equatable {
    public let similarity: Float
    public let isMatch: Bool
    public let threshold: Float
    public let processingTimeMs: Double
    public let timestamp: Date

    public init(
        similarity: Float,
        threshold: Float = AudioConfiguration.speakerMatchThresholdCall,
        processingTimeMs: Double,
        timestamp: Date = Date()
    ) {
        self.similarity = similarity
        self.threshold = threshold
        self.isMatch = similarity >= threshold
        self.processingTimeMs = processingTimeMs
        self.timestamp = timestamp
    }
}

// MARK: - Combined Analysis Result

public struct CallAnalysisResult {
    public let spoof: SpoofResult?
    public let speaker: SpeakerResult?
    public let timestamp: Date

    public init(spoof: SpoofResult?, speaker: SpeakerResult?, timestamp: Date = Date()) {
        self.spoof = spoof
        self.speaker = speaker
        self.timestamp = timestamp
    }

    public var isSafe: Bool {
        guard let spoof = spoof, let speaker = speaker else { return false }
        return spoof.isHuman && speaker.isMatch
    }
}

// MARK: - Voice Signature (Enrollment)

public struct VoiceSignature: Codable, Equatable {
    public let contactId: String
    public let embedding: [Float]
    public let modelVersion: String
    public let enrolledAt: Date

    public init(
        contactId: String,
        embedding: [Float],
        modelVersion: String = AudioConfiguration.voiceEmbedderVersion,
        enrolledAt: Date = Date()
    ) {
        self.contactId = contactId
        self.embedding = embedding
        self.modelVersion = modelVersion
        self.enrolledAt = enrolledAt
    }
}
