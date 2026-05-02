import CoreML
import Foundation
import Accelerate

/// Lightweight on-device classic spoof detector.
///
/// Pipeline mirrors the cloud LFCC baseline used in Twilio-mimic calibration:
/// - 3-second mono PCM at 16 kHz
/// - power spectrum (n_fft=512, hop=160, win=400, center padded)
/// - 40 linear filterbank energies
/// - 20 LFCC coefficients + delta + delta-delta
/// - mean/std/p10/p90 stats => 240-dim feature vector
/// - XGBoost model exported to Core ML
final class ClassicSpoofDetector {

    static let shared = ClassicSpoofDetector()

    private let model: MLModel
    let isLoaded: Bool

    private let sampleCount = AudioConfiguration.analysisWindowSamples
    private let nFFT = 512
    private let hop = 160
    private let win = 400
    private let numFilters = 40
    private let numCepstra = 20
    private let halfFFT = 257
    private let featureCount = 240
    private let deltaOrder = 4
    // Core ML export carries a fixed positive bias relative to XGBoost's raw margin.
    // Removing it restores the trained Python probability calibration:
    // coreml_target ~= xgb_margin + 0.519685
    private let coreMLMarginBias: Double = 0.5196850381
    private lazy var dft = vDSP.DFT(
        count: nFFT,
        direction: .forward,
        transformType: .complexComplex,
        ofType: Float.self
    )!

    private lazy var filterbank: [[Float]] = Self.makeLinearFilterbank(
        sampleRate: Int(AudioConfiguration.sampleRate),
        nFFT: nFFT,
        numFilters: numFilters,
        fmin: 20.0,
        fmax: 7600.0
    )

    private lazy var fftWindow: [Float] = {
        var short = [Float](repeating: 0, count: win)
        vDSP_hann_window(&short, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        var full = [Float](repeating: 0, count: nFFT)
        let offset = (nFFT - win) / 2
        full.replaceSubrange(offset..<(offset + win), with: short)
        return full
    }()

    private lazy var dctBasis: [[Float]] = Self.makeDCTBasis(numCoefficients: numCepstra, inputCount: numFilters)

    private init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            guard let url = Bundle.main.url(forResource: "VeriCallClassicSpoof", withExtension: "mlmodelc") else {
                fatalError("ClassicSpoofDetector: missing VeriCallClassicSpoof.mlmodelc in app bundle")
            }
            model = try MLModel(contentsOf: url, configuration: config)
            isLoaded = true
            print("[ClassicSpoofDetector] classic model loaded")
        } catch {
            isLoaded = false
            fatalError("ClassicSpoofDetector: failed to load VeriCallClassicSpoof – \(error)")
        }
    }

    /// Returns classic spoof probability in [0, 1].
    func predict(samples: [Float]) -> Float? {
        guard let features = extractFeatureVector(samples: samples), features.count == featureCount else {
            return nil
        }

        do {
            var dict: [String: Any] = [:]
            dict.reserveCapacity(featureCount)
            for (idx, value) in features.enumerated() {
                dict["input_\(idx)"] = Double(value)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: dict)
            let output = try model.prediction(from: provider)
            guard let raw = output.featureValue(for: "target")?.doubleValue, raw.isFinite else {
                print("[ClassicSpoofDetector] invalid target output")
                return nil
            }
            let calibratedMargin = raw - coreMLMarginBias
            let prob = 1.0 / (1.0 + exp(-calibratedMargin))
            return Float(min(1.0, max(0.0, prob)))
        } catch {
            print("[ClassicSpoofDetector] prediction error: \(error)")
            return nil
        }
    }

    private func extractFeatureVector(samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return nil }

        var audio = Array(samples.prefix(sampleCount))
        if audio.count < sampleCount {
            audio.append(contentsOf: repeatElement(0, count: sampleCount - audio.count))
        }

        let peak = audio.map { abs($0) }.max() ?? 0
        if peak > 1 {
            audio = audio.map { $0 / peak }
        }

        guard let spectrogram = powerSpectrogram(audio) else { return nil }
        let frameCount = spectrogram.count
        if frameCount == 0 { return nil }

        var logEnergies = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: numFilters
        )

        for frameIdx in 0..<frameCount {
            let power = spectrogram[frameIdx]
            for filterIdx in 0..<numFilters {
                var energy: Float = 0
                vDSP_dotpr(power, 1, filterbank[filterIdx], 1, &energy, vDSP_Length(halfFFT))
                logEnergies[filterIdx][frameIdx] = log(max(energy, 1e-8))
            }
        }

        let cepstra = applyDCT(logEnergies)
        let delta = computeDelta(cepstra)
        let delta2 = computeDelta(delta)
        let stacked = cepstra + delta + delta2

        var featureVector: [Float] = []
        featureVector.reserveCapacity(featureCount)
        for row in stacked {
            featureVector.append(mean(row))
            featureVector.append(std(row))
            featureVector.append(percentile(row, q: 0.10))
            featureVector.append(percentile(row, q: 0.90))
        }
        return featureVector
    }

    private func powerSpectrogram(_ audio: [Float]) -> [[Float]]? {
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: pad)
        padded.append(contentsOf: audio)
        padded.append(contentsOf: repeatElement(0, count: pad))

        guard padded.count >= nFFT else { return nil }
        let frameCount = 1 + (padded.count - nFFT) / hop
        var output: [[Float]] = []
        output.reserveCapacity(frameCount)
        let imagIn = [Float](repeating: 0, count: nFFT)

        for frame in 0..<frameCount {
            let start = frame * hop
            var windowed = Array(padded[start..<(start + nFFT)])
            vDSP_vmul(windowed, 1, fftWindow, 1, &windowed, 1, vDSP_Length(nFFT))

            var realPart = [Float](repeating: 0, count: nFFT)
            var imagPart = [Float](repeating: 0, count: nFFT)
            dft.transform(
                inputReal: windowed,
                inputImaginary: imagIn,
                outputReal: &realPart,
                outputImaginary: &imagPart
            )

            var power = [Float](repeating: 0, count: halfFFT)
            for idx in 0..<halfFFT {
                power[idx] = realPart[idx] * realPart[idx] + imagPart[idx] * imagPart[idx]
            }
            output.append(power)
        }

        return output
    }

    private func applyDCT(_ features: [[Float]]) -> [[Float]] {
        let frameCount = features.first?.count ?? 0
        var output = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: numCepstra
        )
        for frameIdx in 0..<frameCount {
            for coeffIdx in 0..<numCepstra {
                var value: Float = 0
                for filterIdx in 0..<numFilters {
                    value += dctBasis[coeffIdx][filterIdx] * features[filterIdx][frameIdx]
                }
                output[coeffIdx][frameIdx] = value
            }
        }
        return output
    }

    private func computeDelta(_ features: [[Float]]) -> [[Float]] {
        let frameCount = features.first?.count ?? 0
        let denom = Float(2 * (1...deltaOrder).reduce(0) { $0 + ($1 * $1) })
        var output = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: features.count
        )
        for rowIdx in 0..<features.count {
            for frameIdx in 0..<frameCount {
                var numerator: Float = 0
                for n in 1...deltaOrder {
                    let prevIdx = max(0, frameIdx - n)
                    let nextIdx = min(frameCount - 1, frameIdx + n)
                    numerator += Float(n) * (features[rowIdx][nextIdx] - features[rowIdx][prevIdx])
                }
                output[rowIdx][frameIdx] = numerator / denom
            }
        }
        return output
    }

    private func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_meanv(values, 1, &value, vDSP_Length(values.count))
        return value
    }

    private func std(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mu = mean(values)
        let variance = values.reduce(Float(0)) { $0 + (($1 - mu) * ($1 - mu)) } / Float(values.count)
        return sqrt(max(variance, 0))
    }

    private func percentile(_ values: [Float], q: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(0, min(Float(sorted.count - 1), q * Float(sorted.count - 1)))
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        if lower == upper { return sorted[lower] }
        let weight = rank - Float(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func makeLinearFilterbank(
        sampleRate: Int,
        nFFT: Int,
        numFilters: Int,
        fmin: Float,
        fmax: Float
    ) -> [[Float]] {
        let halfFFT = nFFT / 2 + 1
        let freqs = (0..<halfFFT).map { Float($0) * Float(sampleRate) / Float(nFFT) }
        let edges = (0..<(numFilters + 2)).map {
            fmin + Float($0) * (fmax - fmin) / Float(numFilters + 1)
        }
        var filters = Array(repeating: Array(repeating: Float(0), count: halfFFT), count: numFilters)
        for idx in 0..<numFilters {
            let left = edges[idx]
            let center = edges[idx + 1]
            let right = edges[idx + 2]
            for (bin, freq) in freqs.enumerated() {
                if freq >= left && freq <= center && center > left {
                    filters[idx][bin] = (freq - left) / (center - left)
                } else if freq >= center && freq <= right && right > center {
                    filters[idx][bin] = (right - freq) / (right - center)
                }
            }
        }
        return filters
    }

    private static func makeDCTBasis(numCoefficients: Int, inputCount: Int) -> [[Float]] {
        let n = Float(inputCount)
        return (0..<numCoefficients).map { k in
            let scale: Float = k == 0 ? sqrt(1.0 / n) : sqrt(2.0 / n)
            return (0..<inputCount).map { i in
                scale * cos(Float.pi / n * (Float(i) + 0.5) * Float(k))
            }
        }
    }
}
