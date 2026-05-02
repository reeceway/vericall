import CoreML
import Foundation
import Accelerate

/// Wraps VoiceEmbedder.mlpackage (ECAPA-TDNN stage1 epoch1_best).
///
/// Input pipeline:
///   [Float] PCM at 16kHz → 80-band log-Mel fbank [1, 300, 80] → VoiceEmbedder → [Float](192)
///
/// The model was exported with metadata:
///   input_name: fbank_features, shape [1, 300, 80]
///   output_name: embedding, shape [1, 192]
///   sample_rate: 16000, seconds: 3.0, fixed_frames: 300
///   frontend_norm: sentence_mean_subtract
final class EmbedderWrapper {

    static let shared = EmbedderWrapper()

    private let model: VoiceEmbedder
    let isLoaded: Bool

    // fbank parameters matching VoiceEmbedder training
    private let sampleRate: Float = 16_000
    private let frameLength: Int  = 400    // 25ms
    private let frameStep: Int    = 160    // 10ms
    private let numMelBands: Int  = 80
    private let numFrames: Int    = 300    // 3s at 10ms hop

    private init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            model = try VoiceEmbedder(configuration: config)
            isLoaded = true
            print("[EmbedderWrapper] model loaded")
        } catch {
            isLoaded = false
            fatalError("EmbedderWrapper: failed to load VoiceEmbedder — \(error)")
        }
    }

    // MARK: - Public API

    /// Compute 192-dim embedding from 48,000 PCM samples at 16kHz.
    /// Returns nil if inference fails.
    func embed(samples: [Float]) -> [Float]? {
        let t0 = CFAbsoluteTimeGetCurrent()

        // 1. Compute 80-band log-Mel fbank [numFrames × numMelBands]
        guard let fbank = computeFbank(samples: samples) else { return nil }

        // 2. Sentence-mean-subtract (matches training frontend_norm)
        let normalised = sentenceMeanSubtract(fbank)

        // 3. Pack into MLMultiArray [1, 300, 80]
        guard let mlArray = try? MLMultiArray(
            shape: [1, NSNumber(value: numFrames), NSNumber(value: numMelBands)],
            dataType: .float32
        ) else { return nil }

        let dst = mlArray.dataPointer.assumingMemoryBound(to: Float.self)
        let count = numFrames * numMelBands
        normalised.withUnsafeBytes { src in
            dst.initialize(from: src.bindMemory(to: Float.self).baseAddress!, count: count)
        }

        // 4. Run model
        do {
            let input  = VoiceEmbedderInput(fbank_features: mlArray)
            let output = try model.prediction(input: input)
            let embPtr = output.embedding.dataPointer.assumingMemoryBound(to: Float.self)
            let result = Array(UnsafeBufferPointer(start: embPtr, count: 192))
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[EmbedderWrapper] inference \(String(format: "%.1f", ms))ms")
            return result
        } catch {
            print("[EmbedderWrapper] inference error: \(error)")
            return nil
        }
    }

    /// Cosine similarity in [0, 1] between two 192-dim embeddings.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        // Clamp to [0,1] (cosine is [-1,1], but embeddings should be positive)
        return max(0, min(1, dot / denom))
    }

    // MARK: - Fbank Computation

    /// Returns flat [numFrames × numMelBands] array in row-major order.
    private func computeFbank(samples: [Float]) -> [Float]? {
        let inputLen = AudioConfiguration.analysisWindowSamples  // 48000
        var buf = [Float](repeating: 0, count: max(samples.count, inputLen))
        let copy = min(samples.count, inputLen)
        buf.replaceSubrange(0..<copy, with: samples[0..<copy])

        // Pre-emphasis
        var emphasized = [Float](repeating: 0, count: inputLen)
        emphasized[0] = buf[0]
        let alpha: Float = 0.97
        for i in 1..<inputLen {
            emphasized[i] = buf[i] - alpha * buf[i - 1]
        }

        // Build mel filterbank matrix (lazy static)
        let melFilters = Self.melFilterbank(
            numFilters: numMelBands,
            fftSize: frameLength,
            sampleRate: sampleRate
        )

        let fftSize = frameLength
        let halfFFT = fftSize / 2 + 1
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var result = [Float](repeating: 0, count: numFrames * numMelBands)

        for frame in 0..<numFrames {
            let start = frame * frameStep
            let end   = start + fftSize
            guard end <= inputLen else { break }

            // Hamming window
            var windowed = [Float](emphasized[start..<end])
            var window   = [Float](repeating: 0, count: fftSize)
            vDSP_hamm_window(&window, vDSP_Length(fftSize), 0)
            vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // FFT
            var realPart = windowed
            var imagPart = [Float](repeating: 0, count: fftSize)
            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Power spectrum
            var power = [Float](repeating: 0, count: halfFFT)
            for i in 0..<halfFFT {
                power[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i]
            }

            // Apply mel filters
            for m in 0..<numMelBands {
                var energy: Float = 0
                vDSP_dotpr(power, 1, melFilters[m], 1, &energy, vDSP_Length(halfFFT))
                // Log mel with floor
                result[frame * numMelBands + m] = log(max(energy, 1e-10))
            }
        }

        return result
    }

    private func sentenceMeanSubtract(_ fbank: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(fbank, 1, &mean, vDSP_Length(fbank.count))
        var out = fbank
        var neg = -mean
        vDSP_vsadd(out, 1, &neg, &out, 1, vDSP_Length(out.count))
        return out
    }

    // MARK: - Mel Filterbank (cached)

    private static var _melFilterbank: [[Float]]? = nil

    private static func melFilterbank(numFilters: Int, fftSize: Int, sampleRate: Float) -> [[Float]] {
        if let cached = _melFilterbank { return cached }

        let halfFFT = fftSize / 2 + 1
        let fMin: Float = 0
        let fMax: Float = sampleRate / 2

        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        let melPoints = (0...(numFilters + 1)).map { i -> Float in
            melToHz(melMin + Float(i) * (melMax - melMin) / Float(numFilters + 1))
        }
        let binPoints = melPoints.map { Int(($0 / sampleRate) * Float(fftSize) + 0.5) }

        var filters = [[Float]](repeating: [Float](repeating: 0, count: halfFFT), count: numFilters)
        for m in 0..<numFilters {
            let left   = binPoints[m]
            let center = binPoints[m + 1]
            let right  = binPoints[m + 2]
            for k in left..<center {
                if k < halfFFT {
                    filters[m][k] = Float(k - left) / Float(center - left)
                }
            }
            for k in center..<right {
                if k < halfFFT {
                    filters[m][k] = Float(right - k) / Float(right - center)
                }
            }
        }

        _melFilterbank = filters
        return filters
    }
}
