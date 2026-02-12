import Foundation
import AVFoundation
import Accelerate
import CoreML

/// Real-time deepfake detection during VoIP calls using Core ML WavLM model.
///
/// Periodically samples the remote audio buffer (3 seconds) and runs the
/// WavLMDeepfake model to classify the audio as "real" (human) or "fake" (AI).
@MainActor
final class DeepfakeDetectionService: ObservableObject {

    static let shared = DeepfakeDetectionService()

    // MARK: - Published State

    @Published private(set) var detectionResult: DeepfakeDetectionResult?
    @Published private(set) var isDetecting = false
    @Published var useNormalization = true // Toggle for Lab (Default TRUE for Hemgg)
    @Published var lastAudioStats: String = "Waiting..."

    // MARK: - Core ML Model

    private var model: HemggDeepfake?

    // MARK: - Audio Configuration

    private let sampleRate: Double = AudioConfiguration.sampleRate // 16 kHz
    private let contextLengthInSeconds: Double = 3.0
    private var inputSampleCount: Int {
        Int(contextLengthInSeconds * sampleRate)
    }

    // MARK: - Detection Timer

    private var detectionTimer: Timer?
    private let detectionInterval: TimeInterval = 4.0
    private let initialDelay: TimeInterval = 4.0

    // MARK: - Threshold

    /// Model must be at least this confident in "fake" before we flag it.
    private let fakeConfidenceThreshold: Float = 0.50

    // MARK: - Background Queue

    private let detectionQueue = DispatchQueue(
        label: "com.vericall.deepfake",
        qos: .userInitiated
    )

    // MARK: - Audio Source

    private let audioStream = AudioStreamService.shared

    // MARK: - Init

    private init() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // Use Neural Engine if available
            self.model = try HemggDeepfake(configuration: config)
            print("[DeepfakeDetection] Core ML Hemgg model loaded successfully")
        } catch {
            print("[DeepfakeDetection] Failed to load Core ML model: \(error)")
        }
    }

    // MARK: - Public API

    func startDetection() {
        guard !isDetecting else { return }
        guard model != nil else {
            print("[DeepfakeDetection] No Core ML model available - cannot start")
            return
        }

        isDetecting = true
        detectionResult = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self, self.isDetecting else { return }
            self.performDetectionCycle()
            self.detectionTimer = Timer.scheduledTimer(
                withTimeInterval: self.detectionInterval,
                repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.performDetectionCycle()
                }
            }
        }

        print("[DeepfakeDetection] Core ML detection started (first run in \(initialDelay)s)")
    }

    func stopDetection() {
        detectionTimer?.invalidate()
        detectionTimer = nil
        isDetecting = false
        print("[DeepfakeDetection] Detection stopped")
    }

    // MARK: - Detection Pipeline

    // MARK: - Lab Mode Configuration
    
    enum InputSource {
        case remote // Default: VoIP call audio
        case local  // Lab Mode: Microphone input
    }
    
    var inputSource: InputSource = .remote
    var inputGain: Float = 1.0

    // MARK: - Detection Pipeline

    private func performDetectionCycle() {
        guard let model = self.model else { return }

        // Thread-safe copy of audio
        let audioData: [Float]
        if inputSource == .local {
            audioData = audioStream.captureQueue.sync {
                return audioStream.captureBuffer
            }
        } else {
            audioData = audioStream.remoteQueue.sync {
                return audioStream.remoteBuffer
            }
        }
        
        let requiredSamples = inputSampleCount // 48000
        guard audioData.count >= requiredSamples else {
            // Only log waiting if we are actually detecting
            if isDetecting {
                 print("[DeepfakeDetection] Waiting for audio (\(audioData.count)/\(requiredSamples) samples)")
            }
            return
        }

        // Use the most recent 3 seconds
        var chunk = Array(audioData.suffix(requiredSamples))
        
        // Apply Lab Gain if needed
        if inputGain != 1.0 {
            var gain = inputGain
            vDSP_vsmul(chunk, 1, &gain, &chunk, 1, vDSP_Length(chunk.count))
        }

        // Audio diagnostics
        var rms: Float = 0
        vDSP_measqv(chunk, 1, &rms, vDSP_Length(chunk.count))
        rms = sqrt(rms)
        var minVal: Float = 0, maxVal: Float = 0
        vDSP_minv(chunk, 1, &minVal, vDSP_Length(chunk.count))
        vDSP_maxv(chunk, 1, &maxVal, vDSP_Length(chunk.count))
        
        let stats = "RMS: \(String(format: "%.3f", rms)) | Pk: \(String(format: "%.2f", max(abs(minVal), abs(maxVal))))"
        print("[DeepfakeDetection] \(stats)")
        
        Task { @MainActor in
            self.lastAudioStats = stats
        }
        
        // Normalize if enabled (DEFAULT TRUE for Hemgg)
        // Check either the toggle OR if it's the default behavior we want
        if useNormalization {
            var normalizedChunk = chunk
            var mean: Float = 0
            var stdDev: Float = 0
            vDSP_normalize(chunk, 1, &normalizedChunk, 1, &mean, &stdDev, vDSP_Length(chunk.count))
            if stdDev > 0 {
                chunk = normalizedChunk
            }
        }

        // Run on background queue
        nonisolated(unsafe) let capturedModel = model
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.runDetection(chunk: chunk, model: capturedModel)
        }
    }

    /// Pure background detection — no main-actor state accessed.
    nonisolated private func runDetection(chunk: [Float], model: HemggDeepfake) {
        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            // Prepare input: (1, 48000) float32 tensor
            let multiArray = try MLMultiArray(shape: [1, 48000] as [NSNumber], dataType: .float32)
            
            // Efficiently copy float array to MLMultiArray
            let count = chunk.count
            chunk.withUnsafeBufferPointer { bufferPointer in
                let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
                if let baseAddress = bufferPointer.baseAddress {
                    ptr.update(from: baseAddress, count: count)
                }
            }

            // Predict
            let input = HemggDeepfakeInput(input_values: multiArray)
            let output = try model.prediction(input: input)
            
            // Handle output: logits (1, 2)
            let logitsArray = output.logits
            let logitsCount = logitsArray.count // Should be 2
            
            guard logitsCount == 2 else {
                print("[DeepfakeDetection] Unexpected logits shape: \(logitsArray.shape)")
                return
            }
            
            // Extract logits - Hemgg: Index 0 = Fake, Index 1 = Real
            let logitFake = logitsArray[0].floatValue // Index 0 (AIVoice)
            let logitReal = logitsArray[1].floatValue // Index 1 (HumanVoice)
            
            // Softmax
            let maxLogit = max(logitFake, logitReal)
            let expFake = exp(logitFake - maxLogit)
            let expReal = exp(logitReal - maxLogit)
            let sumExp = expFake + expReal
            
            let fakeProb = expFake / sumExp
            let realProb = expReal / sumExp
            
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            
            let realThreshold: Float = 0.85
            let isHuman = realProb > realThreshold
            let confidence = isHuman ? realProb : fakeProb
            
            Task { @MainActor [weak self] in
                self?.detectionResult = DeepfakeDetectionResult(
                    isHuman: isHuman,
                    confidence: confidence,
                    label: isHuman ? "real" : "fake",
                    timestamp: Date(),
                    processingTimeMs: ms
                )
            }

            print("[DeepfakeDetection] \(String(format: "%.0f", ms))ms | logits=[\(String(format: "%.3f", logitFake)), \(String(format: "%.3f", logitReal))] fake=\(String(format: "%.4f%%", fakeProb * 100)) real=\(String(format: "%.4f%%", realProb * 100)) → \(isHuman ? "HUMAN" : "FAKE - AI DETECTED")")
        } catch {
            print("[DeepfakeDetection] Core ML inference error: \(error)")
        }
    }
}
