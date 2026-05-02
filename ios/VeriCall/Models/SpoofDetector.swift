import CoreML
import Foundation

/// Thin wrapper around the exported Layer-3 spoof head.
/// Input : 48,000 float32 PCM samples (3 s @ 16 kHz, normalised to [-1, 1])
/// Path  : samples -> VoiceEmbedder -> 192-d embedding -> VeriCallSpoofHead
/// Output: spoof logit, converted to clone_probability via sigmoid.
final class SpoofDetector {

    static let shared = SpoofDetector()

    private let model: MLModel
    let isLoaded: Bool

    private init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            guard let url = Bundle.main.url(forResource: "VeriCallSpoofHead", withExtension: "mlmodelc") else {
                fatalError("SpoofDetector: missing VeriCallSpoofHead.mlmodelc in app bundle")
            }
            model = try MLModel(contentsOf: url, configuration: config)
            isLoaded = true
            print("[SpoofDetector] spoof head loaded")
        } catch {
            isLoaded = false
            fatalError("SpoofDetector: failed to load VeriCallSpoofHead – \(error)")
        }
    }

    /// Returns P(clone) in [0, 1]. Values ≥ threshold indicate synthetic/cloned audio.
    /// - Parameter samples: float32 PCM at 16 kHz, normalised to [-1, 1].
    ///   Fewer than 48,000 samples are zero-padded; more are truncated.
    func predict(samples: [Float]) -> Float? {
        do {
            guard let embedding = EmbedderWrapper.shared.embed(samples: samples), embedding.count == AudioConfiguration.embeddingDim else {
                print("[SpoofDetector] failed to compute embedding for spoof head")
                return nil
            }

            let mlArray = try MLMultiArray(shape: [1, NSNumber(value: AudioConfiguration.embeddingDim)], dataType: .float32)
            let dst = mlArray.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<AudioConfiguration.embeddingDim {
                dst[i] = embedding[i]
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: ["embedding": mlArray])
            let output = try model.prediction(from: provider)
            guard let target = output.featureValue(for: "target")?.multiArrayValue else {
                print("[SpoofDetector] missing target output")
                return nil
            }
            let logit = target[0].floatValue
            guard logit.isFinite else {
                print("[SpoofDetector] invalid non-finite logit: \(logit)")
                return nil
            }
            let prob = 1.0 / (1.0 + exp(-Double(logit)))
            return min(1, max(0, Float(prob)))
        } catch {
            print("[SpoofDetector] prediction error: \(error)")
            return nil
        }
    }

    /// Debug parity helper: run spoof model directly on a prepared 48k waveform.
    /// Logs statistical characteristics so we can compare runtime preprocessing paths.
    func debugPredict(label: String, samples: [Float]) -> Float? {
        let rms = sqrt(samples.reduce(0) { $0 + ($1 * $1) } / Float(max(1, samples.count)))
        let peak = samples.map { abs($0) }.max() ?? 0
        let out = predict(samples: samples)
        if let out {
            print(String(format: "[SpoofDetector] %@ rms=%.5f peak=%.5f out=%.3f", label, rms, peak, out))
        } else {
            print(String(format: "[SpoofDetector] %@ rms=%.5f peak=%.5f out=nil", label, rms, peak))
        }
        return out
    }
}
