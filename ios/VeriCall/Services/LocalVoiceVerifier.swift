import Foundation
import Accelerate

/// Core voice verification engine using COVARIANCE-based speaker recognition.
///
/// Extracts a 192-dimensional voice signature composed of:
///   * 91  MFCC covariance upper-triangle (features 0-90)
///   * 13  mean delta-MFCCs (features 91-103)
///   * 13  mean delta-delta-MFCCs (features 104-116)
///   * 21  formant features: F1-F3 mean/std + bandwidths + ratios (features 117-137)
///   * 30  pitch-MFCC cross-correlation (features 138-167)
///   * 24  pitch stats + jitter + shimmer (features 168-191)
///
/// The covariance matrix captures HOW MFCC coefficients interact with each other,
/// which reflects the physical shape of the vocal tract — unique per speaker.
/// This replaces the previous mean+std approach which scored 96% between different speakers.
public final class LocalVoiceVerifier {

    // MARK: - Constants

    // 24-dim Mean Voiced CMS (Weighted Bands)
    // [0-11]  Low Freq (Mean MFCC 1-12)
    // [12-23] High Freq (Mean MFCC 13-24)
    public static let featureDimension = 24

    // MARK: - DSP Configuration

    private let sampleRate: Double
    private let frameSize: Int
    private let hopSize: Int
    private let fftSize: Int
    private let numMelBands: Int = 32
    private let numMFCCs: Int = 25 // 0..24

    // MARK: - FFT

    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float]

    // MARK: - Mel Filterbank

    private var melFilterbank: [[Float]] = []

    // MARK: - VAD
    
    private let vadRMSThreshold: Float = 0.015
    private let vadZCRCeiling: Float = 0.45



    // MARK: - Init

    public init(sampleRate: Double = AudioConfiguration.sampleRate,
                frameSize: Int = AudioConfiguration.frameSize) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.hopSize = frameSize / 2
        self.fftSize = frameSize

        self.window = vDSP.window(ofType: Float.self,
                                  usingSequence: .hanningDenormalized,
                                  count: frameSize,
                                  isHalfWindow: false)

        self.fftSetup = vDSP_DFT_zop_CreateSetup(nil,
                                                   vDSP_Length(fftSize),
                                                   .FORWARD)
        buildMelFilterbank()
    }

    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
    }





    // MARK: - Mel Filterbank Construction

    private func hzToMel(_ hz: Float) -> Float { 2595.0 * log10(1.0 + hz / 700.0) }
    private func melToHz(_ mel: Float) -> Float { 700.0 * (powf(10.0, mel / 2595.0) - 1.0) }

    private func buildMelFilterbank() {
        let nyquist = Float(sampleRate / 2.0)
        let numBins = fftSize / 2 + 1
        let melLow = hzToMel(20)
        let melHigh = hzToMel(nyquist)
        let numPoints = numMelBands + 2
        var melPoints = [Float](repeating: 0, count: numPoints)
        for i in 0..<numPoints {
            melPoints[i] = melLow + Float(i) * (melHigh - melLow) / Float(numPoints - 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binPoints = hzPoints.map { Int(($0 / nyquist) * Float(numBins - 1)) }

        melFilterbank = []
        for m in 0..<numMelBands {
            var filter = [Float](repeating: 0, count: numBins)
            let left = binPoints[m], center = binPoints[m + 1], right = binPoints[m + 2]
            if center > left {
                for k in left...center { filter[k] = Float(k - left) / Float(center - left) }
            }
            if right > center {
                for k in center...right where k < numBins {
                    filter[k] = Float(right - k) / Float(right - center)
                }
            }
            melFilterbank.append(filter)
        }
    }

    // MARK: - Main Extraction

    public func extractSignature(from audioData: [Float]) -> [Float] {
        // 1. Preprocess
        var audio = normalizeAudio(audioData)
        audio = applyPreEmphasis(audio)

        // 2. Frame
        let frames = frameAudio(audio)
        guard !frames.isEmpty else {
            return [Float](repeating: 0, count: Self.featureDimension)
        }

        // 3. Power spectra
        let spectra = frames.map { computePowerSpectrum(frame: $0) }

        // 4. VAD
        let voicedMask = frames.enumerated().map { (i, frame) -> Bool in
            return isVoicedFrame(frame: frame, spectrum: spectra[i])
        }
        let voicedCount = voicedMask.filter { $0 }.count
        
        // Use all frames if too few voiced (fallback)
        let useAllFrames = voicedCount < max(10, frames.count / 10)

        // 5. Log mel energies -> MFCCs
        // 5. Log mel energies -> MFCCs
        let logMelEnergies: [[Float]] = spectra.map { melSpectrumToLogEnergies(spectrum: $0) }
        let rawMFCCs: [[Float]] = logMelEnergies.map { dctType2($0, numCoeffs: numMFCCs) }

        // 6. CMS (Cepstral Mean Subtraction) for Covariance
        let cmsMeans = meanAcrossFrames(rawMFCCs)
        var cmsMFCCs = rawMFCCs
        for t in 0..<cmsMFCCs.count {
            for k in 0..<cmsMFCCs[t].count {
                cmsMFCCs[t][k] -= cmsMeans[k]
            }
        }

        // 7. Gather VOICED CMS frames
        var voicedCMSMFCCs: [[Float]] = []
        
        for i in 0..<cmsMFCCs.count {
            if useAllFrames || voicedMask[i] {
                // Use CMS features (channel normalized)
                voicedCMSMFCCs.append(cmsMFCCs[i])
            }
        }

        if voicedCMSMFCCs.isEmpty {
            return [Float](repeating: 0, count: Self.featureDimension)
        }

        // 9. Extract Mean of Voiced CMS (Indices 1-24)
        var meanAccum = [Float](repeating: 0, count: 24)
        for frame in voicedCMSMFCCs {
            // voicedCMSMFCCs has 25 coeffs (0..24 if numMFCCs=25). We want 1..24.
            for j in 1...24 { meanAccum[j-1] += frame[j] }
        }
        
        var features: [Float] = []
        for j in 0..<24 { 
            features.append(meanAccum[j] / Float(voicedCMSMFCCs.count)) 
        }
        
        return features
    }
    
    /// Computes correlation of MFCCs 1...12, excluding diagonal (variances).
    /// Input: [Frame][MFCC] (0...12) -> we use indices 1...12
    /// Output: Flattened upper triangle (row 0..11, col > row)
    private func computeOffDiagonalCovariance(_ data: [[Float]]) -> [Float] {
        guard !data.isEmpty else { return [] }
        let numFrames = data.count
        // Data has 13 dims (0..12). We want 1..12 (12 dims).
        let dim = 12
        
        // 1. Compute means for indices 1...12
        var means = [Float](repeating: 0, count: dim)
        for i in 0..<numFrames {
            for j in 0..<dim {
                means[j] += data[i][j+1] // data index j+1 maps to 0-based mean index j
            }
        }
        for j in 0..<dim { means[j] /= Float(numFrames) }

        // 2. Compute covariance (upper triangle, NO DIAGONAL)
        // Rows 0..11 of our 12x12 matrix.
        var result: [Float] = []
        for r in 0..<dim { // row
            for c in (r+1)..<dim { // col > row (no diagonal)
                var sum: Float = 0
                for i in 0..<numFrames {
                     let valR = data[i][r+1] - means[r]
                     let valC = data[i][c+1] - means[c]
                     sum += valR * valC
                }
                result.append(sum / Float(numFrames - 1))
            }
        }
        return result
    }


    // MARK: - Per-Group Cosine Similarity
    //
    // Instead of one global weighted cosine (where L2-normalized 91-dim covariance
    // dominates the vector direction), compute cosine similarity INDEPENDENTLY
    // for each feature group, then combine with a weighted average.
    // This gives direct control over each group's influence.

    /// Feature groups with their weighting.
    /// We use a single group for the 24-dim Mean Voiced CMS vector.
    /// This captures the spectral shape (timbre) of the voice, channel-normalized
    /// via CMS, across MFCCs 1-24. High-frequency MFCCs (13-24) provide
    /// critical differentiation for impostors.
    private static let scoringGroups: [(name: String, range: Range<Int>, weight: Float)] = [
        ("Mean CMS (1-24)", 0..<24, 100.0)
    ]

    public func calculateSimilarity(between a: [Float], and b: [Float]) -> Float {
        guard a.count == b.count, a.count == Self.featureDimension else { return 0 }

        var totalWeight: Float = 0
        var weightedSum: Float = 0

        for group in Self.scoringGroups {
            let sliceA = Array(a[group.range])
            let sliceB = Array(b[group.range])

            // Cosine similarity for this group
            var dot: Float = 0
            var magA: Float = 0
            var magB: Float = 0
            vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(sliceA.count))
            vDSP_svesq(sliceA, 1, &magA, vDSP_Length(sliceA.count))
            vDSP_svesq(sliceB, 1, &magB, vDSP_Length(sliceB.count))
            magA = sqrt(magA)
            magB = sqrt(magB)

            // Skip groups where either side is near-zero (e.g. failed formant extraction)
            // Don't count their weight in the denominator — treat as missing data
            guard magA > 1e-10 && magB > 1e-10 else { continue }

            let groupSim = dot / (magA * magB)
            weightedSum += group.weight * max(0, groupSim)
            totalWeight += group.weight
        }

        guard totalWeight > 0 else { return 0 }
        return max(0, min(1, weightedSum / totalWeight))
    }

    public func verify(audioData: [Float], against storedSignature: VoiceSignature) -> VoiceVerificationResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let live = extractSignature(from: audioData)
        let sim = calculateSimilarity(between: live, and: storedSignature.vector)
        let dur = Double(audioData.count) / sampleRate
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[VoiceVerifier] Weighted similarity: \(String(format: "%.3f", sim))")
        return VoiceVerificationResult(similarity: sim, analysisDuration: dur, processingTimeMs: ms)
    }

    // MARK: - Power Spectrum

    private func computePowerSpectrum(frame: [Float]) -> [Float] {
        guard let setup = fftSetup else {
            return [Float](repeating: 0, count: fftSize / 2 + 1)
        }
        var real = frame
        var imag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)

        let numBins = fftSize / 2 + 1
        var power = [Float](repeating: 0, count: numBins)
        for i in 0..<numBins {
            power[i] = outReal[i] * outReal[i] + outImag[i] * outImag[i]
        }
        return power
    }

    // MARK: - Mel Spectrum -> Log Energies

    private func melSpectrumToLogEnergies(spectrum: [Float]) -> [Float] {
        var energies = [Float](repeating: 0, count: numMelBands)
        for m in 0..<numMelBands {
            let filter = melFilterbank[m]
            let len = min(spectrum.count, filter.count)
            var dot: Float = 0
            vDSP_dotpr(spectrum, 1, filter, 1, &dot, vDSP_Length(len))
            energies[m] = log(max(dot, 1e-10))
        }
        return energies
    }

    // MARK: - DCT Type-II

    private func dctType2(_ input: [Float], numCoeffs: Int) -> [Float] {
        let N = input.count
        var result = [Float](repeating: 0, count: numCoeffs)
        for k in 0..<numCoeffs {
            var sum: Float = 0
            for n in 0..<N {
                sum += input[n] * cosf(Float.pi * Float(k) * (Float(n) + 0.5) / Float(N))
            }
            result[k] = sum
        }
        return result
    }

    // MARK: - Deltas



    // MARK: - VAD

    private func isVoicedFrame(frame: [Float], spectrum: [Float]) -> Bool {
        var rms: Float = 0
        vDSP_measqv(frame, 1, &rms, vDSP_Length(frame.count))
        rms = sqrt(rms)
        guard rms > vadRMSThreshold else { return false }

        var crossings: Float = 0
        for i in 1..<frame.count {
            if (frame[i] >= 0) != (frame[i - 1] >= 0) { crossings += 1 }
        }
        let zcr = crossings / Float(frame.count - 1)
        guard zcr < vadZCRCeiling else { return false }

        let numBins = spectrum.count
        guard numBins > 0 else { return false }
        var geometricSum: Float = 0
        var arithmeticSum: Float = 0
        for i in 0..<numBins {
            let val = max(spectrum[i], 1e-10)
            geometricSum += log(val)
            arithmeticSum += val
        }
        let geoMean = exp(geometricSum / Float(numBins))
        let ariMean = arithmeticSum / Float(numBins)
        let flatness = ariMean > 1e-10 ? geoMean / ariMean : 1.0
        guard flatness < 0.5 else { return false }

        return true
    }

    // MARK: - Pitch Estimation



    // MARK: - Statistical Helpers

    private func meanAcrossFrames(_ frames: [[Float]]) -> [Float] {
        guard let first = frames.first else { return [] }
        let dim = first.count
        var result = [Float](repeating: 0, count: dim)
        for frame in frames { for d in 0..<dim { result[d] += frame[d] } }
        let n = Float(frames.count)
        for d in 0..<dim { result[d] /= n }
        return result
    }



    // MARK: - Audio Pre-processing

    private func normalizeAudio(_ audio: [Float]) -> [Float] {
        var maxAmp: Float = 0
        vDSP_maxmgv(audio, 1, &maxAmp, vDSP_Length(audio.count))
        guard maxAmp > 1e-10 else { return audio }
        var out = [Float](repeating: 0, count: audio.count)
        var scale = 1.0 / maxAmp
        vDSP_vsmul(audio, 1, &scale, &out, 1, vDSP_Length(audio.count))
        return out
    }

    private func applyPreEmphasis(_ audio: [Float], coeff: Float = 0.97) -> [Float] {
        var out = [Float](repeating: 0, count: audio.count)
        out[0] = audio[0]
        for i in 1..<audio.count { out[i] = audio[i] - coeff * audio[i - 1] }
        return out
    }

    private func frameAudio(_ audio: [Float]) -> [[Float]] {
        var frames: [[Float]] = []
        var start = 0
        while start + frameSize <= audio.count {
            let slice = Array(audio[start..<(start + frameSize)])
            var windowed = [Float](repeating: 0, count: frameSize)
            vDSP_vmul(slice, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            frames.append(windowed)
            start += hopSize
        }
        return frames
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let mag = sqrt(sumSq)
        guard mag > 1e-10 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var s = 1.0 / mag
        vDSP_vsmul(v, 1, &s, &out, 1, vDSP_Length(v.count))
        return out
    }
}
