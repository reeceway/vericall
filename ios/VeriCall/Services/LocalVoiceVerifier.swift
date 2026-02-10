import Foundation
import Accelerate

/// Core spectral fingerprinting engine using Accelerate framework
/// Extracts 192-dimensional voice signatures entirely on-device
public final class LocalVoiceVerifier {
    
    // MARK: - Constants
    /// Total feature vector dimension
    public static let featureDimension = 192
    
    /// Feature group sizes
    private let frequencyBandCount = 64      // Features 1-64
    private let zeroCrossingWindows = 32     // Features 65-96
    private let rmsWindowCount = 32          // Features 97-128
    private let centroidWindowCount = 32     // Features 129-160
    private let deltaFeatureCount = 32       // Features 161-192
    
    // MARK: - DSP Configuration
    private let sampleRate: Double
    private let frameSize: Int
    private let hopSize: Int
    private let fftSize: Int
    
    // MARK: - FFT Setup
    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float]
    
    // MARK: - Buffers
    private var fftBuffer: [Float]
    private var magnitudeBuffer: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    
    // MARK: - Frequency Bands (Log scale)
    private let frequencyBands: [Float]
    
    public init(sampleRate: Double = AudioConfiguration.sampleRate,
                frameSize: Int = AudioConfiguration.frameSize) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.hopSize = frameSize / 2  // 50% overlap
        self.fftSize = frameSize
        
        // Initialize Hann window
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        
        // Initialize FFT setup
        self.fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            .FORWARD
        )
        
        // Initialize buffers
        self.fftBuffer = [Float](repeating: 0, count: fftSize)
        self.magnitudeBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.realBuffer = [Float](repeating: 0, count: fftSize)
        self.imagBuffer = [Float](repeating: 0, count: fftSize)
        
        // Initialize log-spaced frequency bands (0 to Nyquist)
        let nyquist = Float(sampleRate / 2.0)
        let bandCount = frequencyBandCount
        self.frequencyBands = (0..<bandCount).map { i in
            let logMin = log10(Float(20.0))  // 20 Hz
            let logMax = log10(nyquist)
            let t = Float(i) / Float(bandCount - 1)
            return powf(10.0, logMin + t * (logMax - logMin))
        }
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }
    
    // MARK: - Main Extraction Method
    
    /// Extract 192-dimensional spectral signature from audio data
    /// - Parameter audioData: Raw PCM audio samples (mono, 16kHz)
    /// - Returns: 192-dimensional feature vector
    public func extractSignature(from audioData: [Float]) -> [Float] {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Normalize audio
        var normalizedAudio = normalizeAudio(audioData)
        
        // Pre-emphasis filter (high-pass at ~50Hz)
        normalizedAudio = applyPreEmphasis(normalizedAudio)
        
        // Frame the audio
        let frames = frameAudio(normalizedAudio)
        
        // Extract all feature groups
        var features: [Float] = []
        
        // Features 1-64: Frequency band energies
        let bandEnergies = extractFrequencyBandEnergies(frames: frames)
        features.append(contentsOf: bandEnergies)
        
        // Features 65-96: Zero crossing rate per window
        let zcrFeatures = extractZeroCrossingRates(audio: normalizedAudio)
        features.append(contentsOf: zcrFeatures)
        
        // Features 97-128: RMS energy windows
        let rmsFeatures = extractRMSEnergies(audio: normalizedAudio)
        features.append(contentsOf: rmsFeatures)
        
        // Features 129-160: Spectral centroid approximation
        let centroidFeatures = extractSpectralCentroids(frames: frames)
        features.append(contentsOf: centroidFeatures)
        
        // Features 161-192: Delta features (change over time)
        let deltaFeatures = extractDeltaFeatures(from: features)
        features.append(contentsOf: deltaFeatures)
        
        // Normalize feature vector to unit length
        let normalizedFeatures = normalizeVector(features)
        
        let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        print("[LocalVoiceVerifier] Signature extraction: \(String(format: "%.2f", processingTime))ms")
        
        return normalizedFeatures
    }
    
    // MARK: - Similarity Calculation
    
    /// Calculate cosine similarity between two voice signatures
    /// - Parameters:
    ///   - signature1: First voice signature
    ///   - signature2: Second voice signature
    /// - Returns: Cosine similarity (0.0 to 1.0)
    public func calculateSimilarity(between signature1: [Float], and signature2: [Float]) -> Float {
        guard signature1.count == signature2.count,
              signature1.count == LocalVoiceVerifier.featureDimension else {
            return 0.0
        }
        
        // Use Accelerate for fast dot product
        var dotProduct: Float = 0
        vDSP_dotpr(signature1, 1, signature2, 1, &dotProduct, vDSP_Length(signature1.count))
        
        // Calculate magnitudes (vectors are already normalized, so this should be ~1.0)
        var mag1: Float = 0
        var mag2: Float = 0
        vDSP_measqv(signature1, 1, &mag1, vDSP_Length(signature1.count))
        vDSP_measqv(signature2, 1, &mag2, vDSP_Length(signature2.count))
        
        mag1 = sqrt(mag1 * Float(signature1.count))
        mag2 = sqrt(mag2 * Float(signature2.count))
        
        guard mag1 > 0 && mag2 > 0 else { return 0.0 }
        
        return dotProduct / (mag1 * mag2)
    }
    
    /// Verify voice against stored signature
    public func verify(audioData: [Float], against storedSignature: VoiceSignature) -> VoiceVerificationResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let liveSignature = extractSignature(from: audioData)
        let similarity = calculateSimilarity(between: liveSignature, and: storedSignature.vector)
        
        let duration = Double(audioData.count) / sampleRate
        let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        
        return VoiceVerificationResult(
            similarity: similarity,
            analysisDuration: duration,
            processingTimeMs: processingTime
        )
    }
    
    // MARK: - Feature Extraction Methods
    
    /// Extract 64 frequency band energies (log scale)
    /// Features 1-64
    private func extractFrequencyBandEnergies(frames: [[Float]]) -> [Float] {
        guard !frames.isEmpty else { return [Float](repeating: 0, count: frequencyBandCount) }
        
        var bandEnergies = [Float](repeating: 0, count: frequencyBandCount)
        var frameCount = 0
        
        for frame in frames {
            let spectrum = computeSpectrum(frame: frame)
            let energies = computeBandEnergies(spectrum: spectrum)
            
            // Accumulate energies across frames
            for i in 0..<frequencyBandCount {
                bandEnergies[i] += energies[i]
            }
            frameCount += 1
        }
        
        // Average and convert to log scale
        for i in 0..<frequencyBandCount {
            bandEnergies[i] = log10(max(bandEnergies[i] / Float(frameCount), 1e-10))
        }
        
        // Normalize
        return normalizeFeatureGroup(bandEnergies)
    }
    
    /// Extract 32 zero crossing rate features
    /// Features 65-96
    private func extractZeroCrossingRates(audio: [Float]) -> [Float] {
        let windowSize = audio.count / zeroCrossingWindows
        var zcrValues: [Float] = []
        
        for i in 0..<zeroCrossingWindows {
            let start = i * windowSize
            let end = min(start + windowSize, audio.count)
            guard end > start else { continue }
            
            let window = Array(audio[start..<end])
            let zcr = calculateZeroCrossingRate(window)
            zcrValues.append(zcr)
        }
        
        // Pad if necessary
        while zcrValues.count < zeroCrossingWindows {
            zcrValues.append(0)
        }
        
        return normalizeFeatureGroup(Array(zcrValues.prefix(zeroCrossingWindows)))
    }
    
    /// Extract 32 RMS energy features
    /// Features 97-128
    private func extractRMSEnergies(audio: [Float]) -> [Float] {
        let windowSize = audio.count / rmsWindowCount
        var rmsValues: [Float] = []
        
        for i in 0..<rmsWindowCount {
            let start = i * windowSize
            let end = min(start + windowSize, audio.count)
            guard end > start else { continue }
            
            let window = Array(audio[start..<end])
            var rms: Float = 0
            vDSP_measqv(window, 1, &rms, vDSP_Length(window.count))
            rms = sqrt(rms)
            rmsValues.append(rms)
        }
        
        // Convert to dB and pad if necessary
        var dbValues = rmsValues.map { 20 * log10(max($0, 1e-10)) }
        while dbValues.count < rmsWindowCount {
            dbValues.append(-80.0) // Silence floor
        }
        
        return normalizeFeatureGroup(Array(dbValues.prefix(rmsWindowCount)))
    }
    
    /// Extract 32 spectral centroid features
    /// Features 129-160
    private func extractSpectralCentroids(frames: [[Float]]) -> [Float] {
        guard !frames.isEmpty else { return [Float](repeating: 0, count: centroidWindowCount) }
        
        // Group frames into windows
        let framesPerWindow = max(1, frames.count / centroidWindowCount)
        var centroids: [Float] = []
        
        for i in 0..<centroidWindowCount {
            let startFrame = i * framesPerWindow
            let endFrame = min(startFrame + framesPerWindow, frames.count)
            guard endFrame > startFrame else { continue }
            
            var windowCentroids: [Float] = []
            for j in startFrame..<endFrame {
                let spectrum = computeSpectrum(frame: frames[j])
                let centroid = calculateSpectralCentroid(spectrum: spectrum)
                windowCentroids.append(centroid)
            }
            
            // Average centroid for this window
            let avgCentroid = windowCentroids.reduce(0, +) / Float(windowCentroids.count)
            centroids.append(avgCentroid)
        }
        
        // Pad if necessary
        while centroids.count < centroidWindowCount {
            centroids.append(centroids.last ?? 0)
        }
        
        return normalizeFeatureGroup(Array(centroids.prefix(centroidWindowCount)))
    }
    
    /// Extract 32 delta features (rate of change)
    /// Features 161-192
    private func extractDeltaFeatures(from features: [Float]) -> [Float] {
        let baseFeatureCount = 128 // First 128 features for delta calculation
        let featuresToUse = min(features.count, baseFeatureCount)
        let windowSize = featuresToUse / deltaFeatureCount
        
        var deltas: [Float] = []
        
        for i in 0..<deltaFeatureCount {
            let startIdx = i * windowSize
            let endIdx = min(startIdx + windowSize, featuresToUse - 1)
            guard endIdx > startIdx else {
                deltas.append(0)
                continue
            }
            
            // Calculate average rate of change in this window
            var totalDelta: Float = 0
            var count = 0
            for j in startIdx..<endIdx {
                totalDelta += features[j + 1] - features[j]
                count += 1
            }
            
            deltas.append(count > 0 ? totalDelta / Float(count) : 0)
        }
        
        return normalizeFeatureGroup(deltas)
    }
    
    // MARK: - Helper Methods
    
    private func normalizeAudio(_ audio: [Float]) -> [Float] {
        var maxAmplitude: Float = 0
        vDSP_maxv(audio, 1, &maxAmplitude, vDSP_Length(audio.count))
        
        guard maxAmplitude > 0 else { return audio }
        
        var normalized = [Float](repeating: 0, count: audio.count)
        var scale = 1.0 / maxAmplitude
        vDSP_vsmul(audio, 1, &scale, &normalized, 1, vDSP_Length(audio.count))
        
        return normalized
    }
    
    private func applyPreEmphasis(_ audio: [Float], coefficient: Float = 0.97) -> [Float] {
        var emphasized = [Float](repeating: 0, count: audio.count)
        emphasized[0] = audio[0]
        
        for i in 1..<audio.count {
            emphasized[i] = audio[i] - coefficient * audio[i - 1]
        }
        
        return emphasized
    }
    
    private func frameAudio(_ audio: [Float]) -> [[Float]] {
        var frames: [[Float]] = []
        var start = 0
        
        while start + frameSize <= audio.count {
            let end = start + frameSize
            let frame = Array(audio[start..<end])
            
            // Apply window
            var windowedFrame = [Float](repeating: 0, count: frameSize)
            vDSP_vmul(frame, 1, window, 1, &windowedFrame, 1, vDSP_Length(frameSize))
            
            frames.append(windowedFrame)
            start += hopSize
        }
        
        return frames
    }
    
    private func computeSpectrum(frame: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [Float](repeating: 0, count: fftSize / 2) }
        
        // Copy frame to real buffer
        realBuffer = frame
        imagBuffer = [Float](repeating: 0, count: fftSize)
        
        // Perform FFT
        vDSP_DFT_Execute(setup, realBuffer, imagBuffer, &realBuffer, &imagBuffer)
        
        // Compute magnitude spectrum (only first half)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize / 2 {
            magnitudes[i] = sqrt(realBuffer[i] * realBuffer[i] + imagBuffer[i] * imagBuffer[i])
        }
        
        return magnitudes
    }
    
    private func computeBandEnergies(spectrum: [Float]) -> [Float] {
        let binResolution = Float(sampleRate) / Float(fftSize)
        var energies = [Float](repeating: 0, count: frequencyBandCount)
        
        for (bandIdx, centerFreq) in frequencyBands.enumerated() {
            // Find frequency range for this band
            let lowFreq = bandIdx > 0 ? frequencyBands[bandIdx - 1] : 0
            let highFreq = bandIdx < frequencyBands.count - 1 ? frequencyBands[bandIdx + 1] : Float(sampleRate / 2.0)
            
            let lowBin = Int(lowFreq / binResolution)
            let highBin = min(Int(highFreq / binResolution), spectrum.count - 1)
            
            // Sum energy in this band
            var bandEnergy: Float = 0
            for bin in lowBin...highBin where bin < spectrum.count {
                bandEnergy += spectrum[bin] * spectrum[bin]
            }
            
            energies[bandIdx] = bandEnergy
        }
        
        return energies
    }
    
    private func calculateZeroCrossingRate(_ audio: [Float]) -> Float {
        guard audio.count > 1 else { return 0 }
        
        var crossings: Float = 0
        for i in 1..<audio.count {
            if (audio[i] >= 0 && audio[i-1] < 0) || (audio[i] < 0 && audio[i-1] >= 0) {
                crossings += 1
            }
        }
        
        return crossings / Float(audio.count - 1)
    }
    
    private func calculateSpectralCentroid(spectrum: [Float]) -> Float {
        let binResolution = Float(sampleRate) / Float(fftSize)
        
        var sumWeighted: Float = 0
        var sumMagnitude: Float = 0
        
        for (bin, magnitude) in spectrum.enumerated() {
            let frequency = Float(bin) * binResolution
            sumWeighted += frequency * magnitude
            sumMagnitude += magnitude
        }
        
        guard sumMagnitude > 0 else { return 0 }
        return sumWeighted / sumMagnitude
    }
    
    private func normalizeFeatureGroup(_ features: [Float]) -> [Float] {
        var mean: Float = 0
        var std: Float = 0
        
        // Calculate mean
        vDSP_meanv(features, 1, &mean, vDSP_Length(features.count))
        
        // Calculate std
        var meanVector = [Float](repeating: mean, count: features.count)
        var diff = [Float](repeating: 0, count: features.count)
        vDSP_vsub(meanVector, 1, features, 1, &diff, 1, vDSP_Length(features.count))
        vDSP_measqv(diff, 1, &std, vDSP_Length(features.count))
        std = sqrt(std)
        
        // Normalize (z-score)
        var normalized = [Float](repeating: 0, count: features.count)
        if std > 1e-10 {
            var invStd = 1.0 / std
            vDSP_vsmul(diff, 1, &invStd, &normalized, 1, vDSP_Length(features.count))
        }
        
        return normalized
    }
    
    private func normalizeVector(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_measqv(vector, 1, &sumSquares, vDSP_Length(vector.count))
        
        let magnitude = sqrt(sumSquares * Float(vector.count))
        guard magnitude > 1e-10 else { return vector }
        
        var normalized = [Float](repeating: 0, count: vector.count)
        var scale = 1.0 / magnitude
        vDSP_vsmul(vector, 1, &scale, &normalized, 1, vDSP_Length(vector.count))
        
        return normalized
    }
}