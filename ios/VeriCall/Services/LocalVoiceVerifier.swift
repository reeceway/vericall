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

    public static let featureDimension = 192

    // MARK: - DSP Configuration

    private let sampleRate: Double
    private let frameSize: Int
    private let hopSize: Int
    private let fftSize: Int
    private let numMelBands: Int = 32
    private let numMFCCs: Int = 13

    // MARK: - FFT

    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float]

    // MARK: - Mel Filterbank

    private var melFilterbank: [[Float]] = []

    // MARK: - VAD

    private let vadRMSThreshold: Float = 0.015
    private let vadZCRCeiling: Float = 0.45

    // MARK: - Feature Weights
    // Covariance features: 2.0 (backbone of speaker identity)
    // Delta means: 2.5 (proven discriminative - 35% cross-speaker)
    // Formants: 3.0 (vocal tract resonances are very personal)
    // Pitch-MFCC: 2.0 (how pitch interacts with spectral shape)
    // Pitch stats + jitter/shimmer: 3.0 (vocal fold physiology)
    private var featureWeights: [Float] = []

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
        buildFeatureWeights()
    }

    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
    }

    // MARK: - Feature Weights

    private func buildFeatureWeights() {
        var w = [Float](repeating: 0, count: Self.featureDimension)

        // DIMENSION-NORMALIZED WEIGHTS FOR CLONE DETECTION
        //
        // Problem: 91-dim covariance at w=1.5 contributes 136.5 total vs
        //          13-dim deltas at w=5.0 only 65 total.
        // Solution: Assign each group a TARGET INFLUENCE share, then compute
        //           per-dimension weight = influence / num_dims
        //
        // Clone detection data:
        //   Mean Delta = 54.6% clone vs original (BEST discriminator)
        //   Mean DeltaDelta = 69.8% clone vs original
        //   MFCC Covariance = 77.3% clone vs original (moderate)
        //   Formants = 95.6% clone = FOOLED
        //   Pitch-MFCC = 90.7% clone = FOOLED
        //   Pitch+Jitter = 96.2% clone = FOOLED
        //
        // Target influence distribution (must sum to 100):
        let groups: [(range: Range<Int>, influence: Float)] = [
            (0..<91,   15.0),  // MFCC covariance: moderate help (77.3%)
            (91..<104, 40.0),  // Mean delta: BEST clone detector (54.6%)
            (104..<117, 25.0), // Mean delta-delta: good (69.8%)
            (117..<138, 10.0), // Formants: slight help for speaker-vs-speaker
            (138..<168,  5.0), // Pitch-MFCC: mostly fooled
            (168..<192,  5.0), // Pitch+Jitter: mostly fooled
        ]

        for (range, influence) in groups {
            let perDim = influence / Float(range.count)
            for i in range { w[i] = perDim }
        }

        featureWeights = w
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
        let t0 = CFAbsoluteTimeGetCurrent()

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
        let useAllFrames = voicedCount < max(4, frames.count / 5)

        // 5. Log mel energies -> MFCCs
        let logMelEnergies: [[Float]] = spectra.map { melSpectrumToLogEnergies(spectrum: $0) }
        let rawMFCCs: [[Float]] = logMelEnergies.map { dctType2($0, numCoeffs: numMFCCs) }

        // 6. CMS (Cepstral Mean Subtraction)
        let cmsMeans = meanAcrossFrames(rawMFCCs)
        var allMFCCs = rawMFCCs
        for t in 0..<allMFCCs.count {
            for k in 0..<allMFCCs[t].count {
                allMFCCs[t][k] -= cmsMeans[k]
            }
        }

        // 7. Deltas
        let deltaMFCCs = computeDeltas(allMFCCs)
        let deltaDeltaMFCCs = computeDeltas(deltaMFCCs)

        // 8. Gather voiced frames
        var voicedMFCCs: [[Float]] = []
        var voicedDeltas: [[Float]] = []
        var voicedDeltaDeltas: [[Float]] = []
        var voicedFrames: [[Float]] = []
        var voicedSpectra: [[Float]] = []

        for i in 0..<frames.count {
            if useAllFrames || voicedMask[i] {
                voicedMFCCs.append(allMFCCs[i])
                voicedDeltas.append(deltaMFCCs[i])
                voicedDeltaDeltas.append(deltaDeltaMFCCs[i])
                voicedFrames.append(frames[i])
                voicedSpectra.append(spectra[i])
            }
        }

        guard voicedMFCCs.count >= 2 else {
            return [Float](repeating: 0, count: Self.featureDimension)
        }

        // 9. Pitch estimation per voiced frame
        let pitchPerFrame: [Float] = voicedFrames.map { estimatePitch($0) ?? 0 }

        // 10. Build 192-dim feature vector
        var features: [Float] = []

        // [0-90] MFCC Covariance upper triangle (91 dims)
        features.append(contentsOf: computeCovarianceUpperTriangle(voicedMFCCs))

        // [91-103] Mean Delta-MFCCs (13 dims)
        features.append(contentsOf: meanAcrossFrames(voicedDeltas))

        // [104-116] Mean DeltaDelta-MFCCs (13 dims)
        features.append(contentsOf: meanAcrossFrames(voicedDeltaDeltas))

        // [117-137] Formant features (21 dims)
        features.append(contentsOf: extractFormantFeatures(voicedFrames))

        // [138-167] Pitch-MFCC cross-correlation (30 dims)
        features.append(contentsOf: computePitchMFCCCorrelation(pitchPerFrame, mfccs: voicedMFCCs))

        // [168-191] Pitch stats + jitter + shimmer (24 dims)
        features.append(contentsOf: extractPitchJitterShimmer(pitchPerFrame, frames: voicedFrames))

        // Ensure exactly 192
        while features.count < Self.featureDimension { features.append(0) }
        if features.count > Self.featureDimension { features = Array(features.prefix(Self.featureDimension)) }

        // L2-normalize
        let normalized = l2Normalize(features)

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[VoiceVerifier] Signature (COV): \(String(format: "%.1f", ms))ms, voiced \(voicedCount)/\(frames.count) frames")
        return normalized
    }

    // MARK: - MFCC Covariance Matrix (91 dims)

    /// Computes the upper triangle of the 13×13 MFCC covariance matrix.
    /// This captures how each MFCC coefficient co-varies with every other,
    /// reflecting the physical coupling of vocal tract resonances.
    /// Two speakers can have similar per-coefficient statistics but VERY
    /// different cross-coefficient correlations.
    private func computeCovarianceUpperTriangle(_ mfccs: [[Float]]) -> [Float] {
        let dim = numMFCCs // 13
        let n = Float(mfccs.count)

        // Compute means
        let means = meanAcrossFrames(mfccs)

        // Compute covariance: Cov(i,j) = E[(x_i - mu_i)(x_j - mu_j)]
        // Upper triangle including diagonal: 13*14/2 = 91 elements
        var covUpper: [Float] = []
        for i in 0..<dim {
            for j in i..<dim {
                var sum: Float = 0
                for frame in mfccs {
                    sum += (frame[i] - means[i]) * (frame[j] - means[j])
                }
                // Use correlation coefficient (normalized covariance) for scale invariance
                let cov = sum / n
                covUpper.append(cov)
            }
        }

        // Normalize to correlation coefficients for scale invariance
        // Corr(i,j) = Cov(i,j) / (std_i * std_j)
        let stds = stdAcrossFrames(mfccs)
        var corrUpper: [Float] = []
        var idx = 0
        for i in 0..<dim {
            for j in i..<dim {
                let denom = stds[i] * stds[j]
                if denom > 1e-10 {
                    corrUpper.append(covUpper[idx] / denom)
                } else {
                    corrUpper.append(0)
                }
                idx += 1
            }
        }

        return corrUpper // 91 values
    }

    // MARK: - Formant Features via LPC (21 dims)

    /// Estimates F1, F2, F3 formant frequencies and bandwidths using
    /// Linear Predictive Coding (LPC). Formant positions are determined
    /// by the physical dimensions of the vocal tract — highly speaker-specific.
    private func extractFormantFeatures(_ frames: [[Float]]) -> [Float] {
        var allF1: [Float] = [], allF2: [Float] = [], allF3: [Float] = []
        var allB1: [Float] = [], allB2: [Float] = [], allB3: [Float] = []

        for frame in frames {
            let formants = estimateFormants(frame)
            if formants.count >= 3 {
                allF1.append(formants[0].freq)
                allF2.append(formants[1].freq)
                allF3.append(formants[2].freq)
                allB1.append(formants[0].bandwidth)
                allB2.append(formants[1].bandwidth)
                allB3.append(formants[2].bandwidth)
            }
        }

        guard !allF1.isEmpty else {
            return [Float](repeating: 0, count: 21)
        }

        var result: [Float] = []

        // Formant frequencies: mean + std (6 dims)
        result.append(mean(allF1)); result.append(std(allF1))
        result.append(mean(allF2)); result.append(std(allF2))
        result.append(mean(allF3)); result.append(std(allF3))

        // Formant bandwidths: mean + std (6 dims)
        result.append(mean(allB1)); result.append(std(allB1))
        result.append(mean(allB2)); result.append(std(allB2))
        result.append(mean(allB3)); result.append(std(allB3))

        // Formant ratios (very robust features): mean + std (6 dims)
        let f2f1 = zip(allF2, allF1).map { $0.1 > 0 ? $0.0 / $0.1 : 0 }
        let f3f2 = zip(allF3, allF2).map { $0.1 > 0 ? $0.0 / $0.1 : 0 }
        let f3f1 = zip(allF3, allF1).map { $0.1 > 0 ? $0.0 / $0.1 : 0 }
        result.append(mean(f2f1)); result.append(std(f2f1))
        result.append(mean(f3f2)); result.append(std(f3f2))
        result.append(mean(f3f1)); result.append(std(f3f1))

        // Formant dispersion (3 dims)
        // Average spacing between formants — reflects vocal tract length
        let dispersion = zip(zip(allF1, allF2), allF3).map { (f12, f3) -> Float in
            return (f3 - f12.0) / 2.0
        }
        result.append(mean(dispersion))
        result.append(std(dispersion))
        result.append(median(dispersion))

        while result.count < 21 { result.append(0) }
        return Array(result.prefix(21))
    }

    /// LPC-based formant estimation
    private func estimateFormants(_ frame: [Float]) -> [(freq: Float, bandwidth: Float)] {
        let lpcOrder = 12 // Good for 3-4 formants at 16kHz
        let lpcCoeffs = computeLPC(frame, order: lpcOrder)

        // Find roots of LPC polynomial
        let roots = findLPCRoots(lpcCoeffs)

        // Convert roots to frequencies and bandwidths
        var formants: [(freq: Float, bandwidth: Float)] = []
        for root in roots {
            let angle = atan2(root.imag, root.real)
            let freq = abs(angle) * Float(sampleRate) / (2.0 * Float.pi)

            // Only keep formants in valid range (200-5000 Hz)
            guard freq > 200 && freq < Float(sampleRate / 2.0 - 500) else { continue }

            // Bandwidth from pole radius
            let radius = sqrt(root.real * root.real + root.imag * root.imag)
            let bandwidth = -Float(sampleRate) / (2.0 * Float.pi) * log(max(radius, 1e-10))

            // Only keep if bandwidth is reasonable (< 500 Hz)
            if bandwidth > 0 && bandwidth < 500 {
                formants.append((freq: freq, bandwidth: bandwidth))
            }
        }

        // Sort by frequency and return first 3
        formants.sort { $0.freq < $1.freq }
        return Array(formants.prefix(3))
    }

    /// Levinson-Durbin LPC analysis
    private func computeLPC(_ frame: [Float], order: Int) -> [Float] {
        let n = frame.count
        guard n > order else { return [Float](repeating: 0, count: order + 1) }

        // Autocorrelation
        var r = [Float](repeating: 0, count: order + 1)
        for i in 0...order {
            var sum: Float = 0
            for j in 0..<(n - i) {
                sum += frame[j] * frame[j + i]
            }
            r[i] = sum
        }

        guard abs(r[0]) > 1e-10 else { return [Float](repeating: 0, count: order + 1) }

        // Levinson-Durbin recursion
        var a = [Float](repeating: 0, count: order + 1)
        var aTemp = [Float](repeating: 0, count: order + 1)
        a[0] = 1.0

        var e = r[0]

        for i in 1...order {
            var lambda: Float = 0
            for j in 0..<i {
                lambda -= a[j] * r[i - j]
            }
            lambda /= e

            aTemp = a
            for j in 0...i {
                a[j] = aTemp[j] + lambda * aTemp[i - j]
            }

            e *= (1.0 - lambda * lambda)
            guard e > 1e-10 else { break }
        }

        return a
    }

    /// Find roots of LPC polynomial using Durand-Kerner method
    private func findLPCRoots(_ coeffs: [Float]) -> [(real: Float, imag: Float)] {
        let n = coeffs.count - 1
        guard n > 0 else { return [] }

        // Initialize roots on unit circle with slight perturbation
        var rootsReal = [Float](repeating: 0, count: n)
        var rootsImag = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let angle = 2.0 * Float.pi * Float(i) / Float(n) + 0.1
            rootsReal[i] = 0.95 * cos(angle)
            rootsImag[i] = 0.95 * sin(angle)
        }

        // Iterate Durand-Kerner
        for _ in 0..<50 {
            for i in 0..<n {
                // Evaluate polynomial at root i
                var pReal: Float = coeffs[0]
                var pImag: Float = 0
                var zPowReal: Float = 1
                var zPowImag: Float = 0

                for k in 1...n {
                    let newZPowReal = zPowReal * rootsReal[i] - zPowImag * rootsImag[i]
                    let newZPowImag = zPowReal * rootsImag[i] + zPowImag * rootsReal[i]
                    zPowReal = newZPowReal
                    zPowImag = newZPowImag
                    pReal += coeffs[k] * zPowReal
                    pImag += coeffs[k] * zPowImag
                }

                // Compute denominator: product of (z_i - z_j) for j != i
                var denomReal: Float = 1
                var denomImag: Float = 0
                for j in 0..<n where j != i {
                    let diffReal = rootsReal[i] - rootsReal[j]
                    let diffImag = rootsImag[i] - rootsImag[j]
                    let newDenomReal = denomReal * diffReal - denomImag * diffImag
                    let newDenomImag = denomReal * diffImag + denomImag * diffReal
                    denomReal = newDenomReal
                    denomImag = newDenomImag
                }

                // z_i = z_i - P(z_i) / product
                let denomMagSq = denomReal * denomReal + denomImag * denomImag
                guard denomMagSq > 1e-20 else { continue }
                let quotReal = (pReal * denomReal + pImag * denomImag) / denomMagSq
                let quotImag = (pImag * denomReal - pReal * denomImag) / denomMagSq

                rootsReal[i] -= quotReal
                rootsImag[i] -= quotImag
            }
        }

        // Return only roots with positive imaginary part (conjugate pairs)
        var result: [(real: Float, imag: Float)] = []
        for i in 0..<n {
            if rootsImag[i] > 0 {
                result.append((real: rootsReal[i], imag: rootsImag[i]))
            }
        }
        return result
    }

    // MARK: - Pitch-MFCC Cross-Correlation (30 dims)

    /// Computes how pitch covaries with each MFCC coefficient.
    /// Some people's voice gets brighter when they speak higher; others don't.
    /// This is very speaker-specific.
    private func computePitchMFCCCorrelation(_ pitchPerFrame: [Float], mfccs: [[Float]]) -> [Float] {
        guard pitchPerFrame.count == mfccs.count, !pitchPerFrame.isEmpty else {
            return [Float](repeating: 0, count: 30)
        }

        let voicedPitch = pitchPerFrame.filter { $0 > 0 }
        guard voicedPitch.count > 2 else {
            return [Float](repeating: 0, count: 30)
        }

        let pitchMean = mean(pitchPerFrame)
        let pitchStd = std(pitchPerFrame)
        let mfccMeans = meanAcrossFrames(mfccs)
        let mfccStds = stdAcrossFrames(mfccs)

        var result: [Float] = []

        // Correlation of pitch with each MFCC (13 dims)
        for k in 0..<numMFCCs {
            var sum: Float = 0
            for i in 0..<pitchPerFrame.count {
                sum += (pitchPerFrame[i] - pitchMean) * (mfccs[i][k] - mfccMeans[k])
            }
            let cov = sum / Float(pitchPerFrame.count)
            let denom = pitchStd * mfccStds[k]
            result.append(denom > 1e-10 ? cov / denom : 0)
        }

        // Pitch-delta correlation: how pitch change relates to MFCC change (13 dims)
        if pitchPerFrame.count > 1 {
            let pitchDeltas = zip(pitchPerFrame.dropFirst(), pitchPerFrame).map { $0 - $1 }
            let mfccDeltas: [[Float]] = zip(mfccs.dropFirst(), mfccs).map { (curr, prev) in
                zip(curr, prev).map { $0 - $1 }
            }
            let pdMean = mean(pitchDeltas)
            let pdStd = std(pitchDeltas)
            let mdMeans = meanAcrossFrames(mfccDeltas)
            let mdStds = stdAcrossFrames(mfccDeltas)

            for k in 0..<numMFCCs {
                var sum: Float = 0
                for i in 0..<pitchDeltas.count {
                    sum += (pitchDeltas[i] - pdMean) * (mfccDeltas[i][k] - mdMeans[k])
                }
                let cov = sum / Float(pitchDeltas.count)
                let denom = pdStd * mdStds[k]
                result.append(denom > 1e-10 ? cov / denom : 0)
            }
        } else {
            result.append(contentsOf: [Float](repeating: 0, count: 13))
        }

        // Pitch dynamics features (4 dims):
        // How much pitch varies relative to MFCCs changing
        let mfccTotalVariance = mfccStds.map { $0 * $0 }.reduce(0, +)
        let pitchVariance = pitchStd * pitchStd
        result.append(mfccTotalVariance > 1e-10 ? pitchVariance / mfccTotalVariance : 0) // pitch/mfcc variance ratio
        result.append(pitchStd) // raw pitch variability
        // Pitch contour shape: split into quarters, compute slope
        let quarters = segmentedMeans(pitchPerFrame, segments: 2)
        result.append(contentsOf: quarters)

        while result.count < 30 { result.append(0) }
        return Array(result.prefix(30))
    }

    // MARK: - Pitch + Jitter + Shimmer (24 dims)

    private func extractPitchJitterShimmer(_ pitchPerFrame: [Float], frames: [[Float]]) -> [Float] {
        var result: [Float] = []

        let voicedPitch = pitchPerFrame.filter { $0 > 0 }
        let pitchValues = voicedPitch.isEmpty ? [Float(0)] : voicedPitch

        // Pitch statistics (8 dims)
        result.append(mean(pitchValues))
        result.append(std(pitchValues))
        result.append(pitchValues.min() ?? 0)
        result.append(pitchValues.max() ?? 0)
        result.append(median(pitchValues))
        result.append((pitchValues.max() ?? 0) - (pitchValues.min() ?? 0))  // range
        // Quartiles
        let sorted = pitchValues.sorted()
        let q1idx = sorted.count / 4
        let q3idx = 3 * sorted.count / 4
        result.append(sorted[min(q1idx, sorted.count - 1)])  // Q1
        result.append(sorted[min(q3idx, sorted.count - 1)])  // Q3

        // Jitter - pitch period perturbation (4 dims)
        // Measures micro-variations in vocal fold vibration
        if voicedPitch.count > 2 {
            var absJitter: [Float] = []
            for i in 1..<voicedPitch.count {
                absJitter.append(abs(voicedPitch[i] - voicedPitch[i-1]))
            }
            let meanPitch = mean(voicedPitch)
            let jitterPercent = meanPitch > 0 ? mean(absJitter) / meanPitch * 100 : 0
            result.append(jitterPercent)
            result.append(std(absJitter))
            // RAP (Relative Average Perturbation): 3-point jitter
            var rap: [Float] = []
            for i in 1..<(voicedPitch.count - 1) {
                let avg3 = (voicedPitch[i-1] + voicedPitch[i] + voicedPitch[i+1]) / 3.0
                rap.append(abs(voicedPitch[i] - avg3))
            }
            result.append(mean(rap))
            result.append(std(rap))
        } else {
            result.append(contentsOf: [Float](repeating: 0, count: 4))
        }

        // Shimmer - amplitude perturbation (4 dims)
        // Measures micro-variations in voice intensity
        if frames.count > 2 {
            var frameRMS: [Float] = []
            for frame in frames {
                var rms: Float = 0
                vDSP_measqv(frame, 1, &rms, vDSP_Length(frame.count))
                frameRMS.append(sqrt(rms))
            }
            var absShimmer: [Float] = []
            for i in 1..<frameRMS.count {
                absShimmer.append(abs(frameRMS[i] - frameRMS[i-1]))
            }
            let meanRMS = mean(frameRMS)
            let shimmerPercent = meanRMS > 0 ? mean(absShimmer) / meanRMS * 100 : 0
            result.append(shimmerPercent)
            result.append(std(absShimmer))
            // APQ (Amplitude Perturbation Quotient): 5-point shimmer
            var apq: [Float] = []
            for i in 2..<(frameRMS.count - 2) {
                let avg5 = (frameRMS[i-2] + frameRMS[i-1] + frameRMS[i] + frameRMS[i+1] + frameRMS[i+2]) / 5.0
                apq.append(abs(frameRMS[i] - avg5))
            }
            if !apq.isEmpty {
                result.append(mean(apq))
                result.append(std(apq))
            } else {
                result.append(contentsOf: [Float](repeating: 0, count: 2))
            }
        } else {
            result.append(contentsOf: [Float](repeating: 0, count: 4))
        }

        // Pitch trajectory segments (8 dims)
        let pitchSegs = segmentedMeans(pitchValues, segments: 8)
        result.append(contentsOf: pitchSegs)

        while result.count < 24 { result.append(0) }
        return Array(result.prefix(24))
    }

    // MARK: - Per-Group Cosine Similarity
    //
    // Instead of one global weighted cosine (where L2-normalized 91-dim covariance
    // dominates the vector direction), compute cosine similarity INDEPENDENTLY
    // for each feature group, then combine with a weighted average.
    // This gives direct control over each group's influence.

    /// Feature groups with their influence weights (must sum to 100)
    private static let scoringGroups: [(name: String, range: Range<Int>, weight: Float)] = [
        ("MFCCCov",      0..<91,   15),  // Covariance: moderate clone resistance (77.3%)
        ("MeanDelta",    91..<104, 40),  // BEST clone detector (54.6% clone vs original)
        ("MeanDD",       104..<117, 25), // Good dynamics (69.8%)
        ("Formants",     117..<138, 10), // Fooled by clone (95.6%) but good for real speakers
        ("PitchMFCC",    138..<168,  5), // Mostly fooled (90.7%)
        ("PitchJitter",  168..<192,  5), // Mostly fooled (96.2%)
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

            let groupSim = (magA > 1e-10 && magB > 1e-10) ? dot / (magA * magB) : 0
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

    private func computeDeltas(_ featureSequence: [[Float]]) -> [[Float]] {
        let N = featureSequence.count
        guard N > 2 else { return featureSequence }
        let width = 2
        var deltas = [[Float]](repeating: [Float](repeating: 0, count: featureSequence[0].count), count: N)
        let denom: Float = 2.0 * Float(width * (width + 1) * (2 * width + 1)) / 6.0
        let denomSafe = max(denom, 1e-10)

        for t in 0..<N {
            let dim = featureSequence[t].count
            var delta = [Float](repeating: 0, count: dim)
            for tau in 1...width {
                let prev = max(0, t - tau)
                let next = min(N - 1, t + tau)
                for d in 0..<dim {
                    delta[d] += Float(tau) * (featureSequence[next][d] - featureSequence[prev][d])
                }
            }
            for d in 0..<dim { delta[d] /= denomSafe }
            deltas[t] = delta
        }
        return deltas
    }

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

    private func estimatePitch(_ frame: [Float]) -> Float? {
        let minLag = Int(sampleRate / 500)
        let maxLag = Int(sampleRate / 60)
        guard maxLag < frame.count else { return nil }

        var bestLag = minLag
        var bestCorr: Float = -1

        var energy: Float = 0
        vDSP_svesq(frame, 1, &energy, vDSP_Length(frame.count))
        guard energy > 1e-10 else { return nil }

        for lag in minLag...min(maxLag, frame.count - 1) {
            var corr: Float = 0
            let n = frame.count - lag
            vDSP_dotpr(frame, 1, Array(frame[lag...]), 1, &corr, vDSP_Length(n))
            corr /= energy
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }

        guard bestCorr > 0.3 else { return nil }
        return Float(sampleRate) / Float(bestLag)
    }

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

    private func stdAcrossFrames(_ frames: [[Float]]) -> [Float] {
        let means = meanAcrossFrames(frames)
        let dim = means.count
        var result = [Float](repeating: 0, count: dim)
        for frame in frames {
            for d in 0..<dim { let diff = frame[d] - means[d]; result[d] += diff * diff }
        }
        let n = Float(frames.count)
        for d in 0..<dim { result[d] = sqrt(result[d] / n) }
        return result
    }

    private func mean(_ arr: [Float]) -> Float {
        guard !arr.isEmpty else { return 0 }
        return arr.reduce(0, +) / Float(arr.count)
    }

    private func std(_ arr: [Float]) -> Float {
        guard arr.count > 1 else { return 0 }
        let m = mean(arr)
        let variance = arr.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(arr.count)
        return sqrt(variance)
    }

    private func median(_ arr: [Float]) -> Float {
        guard !arr.isEmpty else { return 0 }
        let sorted = arr.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    }

    private func segmentedMeans(_ arr: [Float], segments: Int) -> [Float] {
        guard !arr.isEmpty else { return [Float](repeating: 0, count: segments) }
        let segSize = max(1, arr.count / segments)
        var result: [Float] = []
        for s in 0..<segments {
            let start = s * segSize
            let end = min(start + segSize, arr.count)
            if start < arr.count {
                result.append(mean(Array(arr[start..<end])))
            } else {
                result.append(result.last ?? 0)
            }
        }
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
