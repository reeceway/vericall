import Foundation
import Accelerate

// MARK: - Deepfake Detection Result

/// Result from the on-device AI deepfake detection model
public struct DeepfakeDetectionResult: Equatable {
    /// Whether the audio is classified as human (true) or AI-generated (false)
    public let isHuman: Bool

    /// Model confidence score (0.0 to 1.0)
    public let confidence: Float

    /// Raw classification label from the model ("real" or "fake")
    public let label: String

    /// Timestamp of this detection
    public let timestamp: Date

    /// Time taken to run inference in milliseconds
    public let processingTimeMs: Double

    public init(isHuman: Bool, confidence: Float, label: String, timestamp: Date = Date(), processingTimeMs: Double) {
        self.isHuman = isHuman
        self.confidence = confidence
        self.label = label
        self.timestamp = timestamp
        self.processingTimeMs = processingTimeMs
    }
}

// MARK: - Audio Configuration
public struct AudioConfiguration {
    /// Sample rate in Hz (16kHz for voice)
    public static let sampleRate: Double = 16000.0

    /// Number of audio channels (mono)
    public static let channelCount: UInt32 = 1

    /// Bits per sample
    public static let bitsPerSample: UInt32 = 16

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
