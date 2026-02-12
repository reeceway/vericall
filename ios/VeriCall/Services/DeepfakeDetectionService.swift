import Foundation
import AVFoundation
import CoreML
import Accelerate

/// Real-time deepfake detection during VoIP calls.
///
/// Periodically samples the remote audio buffer (3 seconds) and runs the
/// WavLMDeepfake CoreML model to classify the audio as "real" (human) or "fake" (AI).
@MainActor
final class DeepfakeDetectionService: ObservableObject {

    static let shared = DeepfakeDetectionService()

    // MARK: - Published State

    @Published private(set) var detectionResult: DeepfakeDetectionResult?
    @Published private(set) var isDetecting = false

    // MARK: - CoreML Model

    private var model: WavLMDeepfake?

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

    // MARK: - Smoothing

    private var recentResults: [Bool] = [] // true = human
    private let smoothingWindow = 5
    /// Model must be at least this confident in "fake" before we flag it.
    /// WavLM is very accurate, so we use a high threshold to be safe.
    private let fakeConfidenceThreshold: Float = 0.70

    // MARK: - Background Queue

    private let detectionQueue = DispatchQueue(
        label: "com.vericall.deepfake",
        qos: .userInitiated
    )

    // MARK: - Audio Source

    private let audioStream = AudioStreamService.shared

    // MARK: - Init

    private init() {
        // Load CoreML model
        if #available(iOS 17.0, *) {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all 
                model = try WavLMDeepfake(configuration: config)
                print("[DeepfakeDetection] WavLM CoreML model loaded")
            } catch {
                print("[DeepfakeDetection] Failed to load model: \(error)")
            }
        } else {
            print("[DeepfakeDetection] WavLM model requires iOS 17+")
        }
    }

    // MARK: - Public API

    func startDetection() {
        guard !isDetecting else { return }
        guard model != nil else {
            print("[DeepfakeDetection] No model available - cannot start")
            return
        }

        isDetecting = true
        detectionResult = nil
        recentResults.removeAll()

        // Wait for audio to accumulate before first detection
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

        print("[DeepfakeDetection] Detection started (first run in \(initialDelay)s)")
    }

    func stopDetection() {
        detectionTimer?.invalidate()
        detectionTimer = nil
        isDetecting = false
        recentResults.removeAll()
        print("[DeepfakeDetection] Detection stopped")
    }

    // MARK: - Detection Pipeline

    /// Called from the main actor timer; captures state then dispatches to background.
    private func performDetectionCycle() {
        // Capture model reference on main actor
        guard let capturedModel = self.model else { return }

        // Thread-safe copy of remote audio
        let remoteAudio: [Float] = audioStream.remoteQueue.sync {
            return audioStream.remoteBuffer
        }

        let requiredSamples = inputSampleCount // 48000
        guard remoteAudio.count >= requiredSamples else {
            print("[DeepfakeDetection] Waiting for audio (\(remoteAudio.count)/\(requiredSamples) samples)")
            return
        }

        // Use the most recent 3 seconds (48000 samples)
        let chunk = Array(remoteAudio.suffix(requiredSamples))

        // Check audio energy (RMS) to avoid running on silence
        var rms: Float = 0
        vDSP_measqv(chunk, 1, &rms, vDSP_Length(chunk.count))
        rms = sqrt(rms)
        guard rms > 0.003 else {
            print("[DeepfakeDetection] Audio too quiet (RMS: \(String(format: "%.4f", rms))) - skipping")
            return
        }

        // Run on background queue
        // CoreML model is thread-safe for inference but not Sendable, so we capture it carefully
        nonisolated(unsafe) let model = capturedModel
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.runDetection(chunk: chunk, model: model)
        }
    }

    /// Pure background detection — no main-actor state accessed.
    nonisolated private func runDetection(chunk: [Float], model: WavLMDeepfake) {
        let t0 = CFAbsoluteTimeGetCurrent()

        // 1. Create MLMultiArray input
        // WavLM expects shape (1, 48000)
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: chunk.count)], dataType: .float32) else {
            print("[DeepfakeDetection] Failed to create MLMultiArray")
            return
        }

        // Allow direct memory access for speed
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
           let count = ptr.count
           if let baseAddr = ptr.baseAddress {
               // Copy chunk to input buffer
               chunk.withUnsafeBufferPointer { srcPtr in
                   if let srcAddr = srcPtr.baseAddress {
                       memcpy(baseAddr, srcAddr, min(count, chunk.count) * MemoryLayout<Float>.stride)
                   }
               }
           }
        }

        // 2. Run CoreML inference
        do {
            let prediction = try model.prediction(audio: input)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            // 3. Process Result
            // Output has 'label' (String) and 'label_probs' (Dictionary<String, Double>) (Found via strings inspection)
            let probs = prediction.label_probs
            let fakeProb = Float(probs["fake"] ?? 0.0)
            let realProb = Float(probs["real"] ?? 0.0)
            let predictedLabel = prediction.label

            // Only classify as fake if model confidence exceeds threshold
            let isHuman = fakeProb < fakeConfidenceThreshold
            let confidence = isHuman ? max(realProb, 1.0 - fakeProb) : fakeProb

            Task { @MainActor [weak self] in
                self?.processResult(
                    isHuman: isHuman,
                    confidence: confidence,
                    label: isHuman ? "real" : "fake",
                    processingTimeMs: ms
                )
            }

            print("[DeepfakeDetection] raw=\(predictedLabel) fake=\(String(format: "%.1f%%", fakeProb * 100)) real=\(String(format: "%.1f%%", realProb * 100)) → \(isHuman ? "HUMAN" : "FAKE") (\(String(format: "%.0fms", ms)))")
        } catch {
            print("[DeepfakeDetection] Inference error: \(error)")
        }
    }

    private func processResult(
        isHuman: Bool,
        confidence: Float,
        label: String,
        processingTimeMs: Double
    ) {
        // Smoothing: majority vote over recent results
        recentResults.append(isHuman)
        if recentResults.count > smoothingWindow {
            recentResults.removeFirst()
        }

        let humanCount = recentResults.filter { $0 }.count
        let smoothedIsHuman = humanCount > recentResults.count / 2

        detectionResult = DeepfakeDetectionResult(
            isHuman: smoothedIsHuman,
            confidence: confidence,
            label: smoothedIsHuman ? "real" : "fake",
            timestamp: Date(),
            processingTimeMs: processingTimeMs
        )
    }
}
