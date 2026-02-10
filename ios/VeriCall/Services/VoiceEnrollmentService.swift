import Foundation
import AVFoundation
import Combine

/// Handles voice enrollment for new contacts
/// Records 5 phrases, extracts signatures, and stores securely in Keychain
public final class VoiceEnrollmentService: ObservableObject {
    
    // MARK: - Published State
    @Published public private(set) var state: EnrollmentState = .notStarted
    @Published public private(set) var progress: EnrollmentProgress
    @Published public private(set) var currentAudioLevel: Float = 0.0
    @Published public private(set) var audioSpectrum: [Float] = []
    
    // MARK: - Private Properties
    private let audioEngine = AVAudioEngine()
    private let verifier = LocalVoiceVerifier()
    private var audioBuffer: [Float] = []
    private var phraseSignatures: [[Float]] = []
    
    private let totalPhrases = 5
    private var currentPhraseIndex = 0
    private var recordingStartTime: Date?
    private var timer: Timer?
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Constants
    private let phraseDuration: TimeInterval = AudioConfiguration.enrollmentPhraseDuration
    private let sampleRate = AudioConfiguration.sampleRate
    
    // MARK: - Enrollment Prompts
    public let enrollmentPrompts = [
        "Say: My voice is my password",
        "Say: Verify me with my voice",
        "Say: This is my secure identity",
        "Say: VeriCall authenticates me",
        "Say: Trust my voice signature"
    ]
    
    public init() {
        self.progress = EnrollmentProgress(
            currentPhrase: 0,
            totalPhrases: 5,
            recordingProgress: 0.0,
            isProcessing: false
        )
    }
    
    // MARK: - Public Methods
    
    /// Get the current user's voice signature from Keychain
    public func getVoiceSignature() -> [Float]? {
        return try? getOwnVoiceSignatureFromKeychain()
    }
    
    /// Save the final voice signature to Keychain for the current user
    public func saveVoiceSignatureToKeychain(contactId: String) async throws {
        guard let signature = getFinalSignature(contactId: contactId) else {
            throw EnrollmentError.processingFailed
        }
        
        let keychainService = VoiceKeychainService()
        try keychainService.saveSignature(signature)
        
        // Also save as "self" for easy retrieval during calls
        let selfSignature = VoiceSignature(
            vector: signature.vector,
            contactId: "self",
            phraseCount: signature.phraseCount
        )
        try keychainService.saveSignature(selfSignature)
        
        print("[VoiceEnrollmentService] Voice signature saved to Keychain for contact: \(contactId)")
    }
    
    /// Start enrollment process
    public func startEnrollment() async throws {
        // Request microphone permission
        let authorized = await requestMicrophonePermission()
        guard authorized else {
            throw EnrollmentError.microphonePermissionDenied
        }
        
        await MainActor.run {
            self.state = .notStarted
            self.currentPhraseIndex = 0
            self.phraseSignatures.removeAll()
            self.updateProgress()
        }
    }
    
    /// Begin recording a phrase
    public func startRecordingPhrase() async throws {
        guard currentPhraseIndex < totalPhrases else {
            throw EnrollmentError.enrollmentComplete
        }
        
        // Reset buffer for new phrase
        audioBuffer.removeAll()
        
        // Setup and start audio engine
        try setupAudioEngine()
        
        await MainActor.run {
            self.recordingStartTime = Date()
            self.state = .recording(phraseIndex: self.currentPhraseIndex, progress: 0.0)
            self.startProgressTimer()
        }
        
        try audioEngine.start()
        
        // Schedule automatic stop after phraseDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + phraseDuration) { [weak self] in
            Task {
                await self?.finishRecordingPhrase()
            }
        }
    }
    
    /// Stop recording current phrase
    public func stopRecordingPhrase() async {
        await finishRecordingPhrase()
    }
    
    /// Get final averaged signature
    public func getFinalSignature(contactId: String) -> VoiceSignature? {
        guard phraseSignatures.count == totalPhrases else { return nil }
        
        // Average all phrase signatures
        var averagedVector = [Float](repeating: 0, count: LocalVoiceVerifier.featureDimension)
        
        for signature in phraseSignatures {
            for i in 0..<averagedVector.count {
                averagedVector[i] += signature[i]
            }
        }
        
        // Divide by count
        let count = Float(phraseSignatures.count)
        for i in 0..<averagedVector.count {
            averagedVector[i] /= count
        }
        
        // Re-normalize
        averagedVector = normalizeVector(averagedVector)
        
        return VoiceSignature(
            vector: averagedVector,
            contactId: contactId,
            phraseCount: totalPhrases
        )
    }
    
    /// Reset enrollment state
    public func reset() {
        stopAudioEngine()
        audioBuffer.removeAll()
        phraseSignatures.removeAll()
        currentPhraseIndex = 0
        timer?.invalidate()
        timer = nil
        
        state = .notStarted
        updateProgress()
    }
    
    // MARK: - Private Methods
    
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    private func setupAudioEngine() throws {
        audioEngine.stop()
        audioEngine.reset()
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        let frameLength = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength)
        
        // Copy samples
        for i in 0..<frameLength {
            samples[i] = channelData[i]
        }
        
        // Convert sample rate if needed
        if buffer.format.sampleRate != sampleRate {
            samples = resample(samples, from: buffer.format.sampleRate, to: sampleRate)
        }
        
        // Add to buffer
        audioBuffer.append(contentsOf: samples)
        
        // Calculate audio level for visualization
        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
        rms = sqrt(rms)
        
        // Calculate simple spectrum for visualization (FFT bins)
        let spectrum = calculateQuickSpectrum(samples)
        
        DispatchQueue.main.async { [weak self] in
            self?.currentAudioLevel = min(rms * 10, 1.0) // Scale for visualization
            self?.audioSpectrum = spectrum
        }
    }
    
    private func calculateQuickSpectrum(_ samples: [Float]) -> [Float] {
        let fftSize = 256
        guard samples.count >= fftSize else { return [Float](repeating: 0, count: 32) }
        
        let frame = Array(samples.prefix(fftSize))
        
        // Simple window and FFT
        var windowed = [Float](repeating: 0, count: fftSize)
        let window = vDSP.window(ofLength: fftSize, using: .hanningDenormalized)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        
        // Create FFT setup
        guard let fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            return [Float](repeating: 0, count: 32)
        }
        
        var real = windowed
        var imag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        
        vDSP_DFT_Execute(fftSetup, real, imag, &outReal, &outImag)
        vDSP_DFT_DestroySetupD(fftSetup)
        
        // Calculate magnitudes (first half only)
        var magnitudes = [Float](repeating: 0, count: 32)
        let binsPerBucket = fftSize / 2 / 32
        
        for i in 0..<32 {
            var sum: Float = 0
            for j in 0..<binsPerBucket {
                let idx = i * binsPerBucket + j
                sum += sqrt(outReal[idx] * outReal[idx] + outImag[idx] * outImag[idx])
            }
            magnitudes[i] = sum / Float(binsPerBucket)
        }
        
        return magnitudes
    }
    
    private func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        let ratio = targetRate / sourceRate
        let newLength = Int(Double(samples.count) * ratio)
        
        var resampled = [Float](repeating: 0, count: newLength)
        var source = samples
        var resampleRatio = Float(1.0 / ratio)
        
        vDSP_vgenp(&source, vDSP_Stride(1),
                   &resampled, vDSP_Stride(1),
                   &resampleRatio,
                   vDSP_Length(newLength),
                   vDSP_Length(samples.count))
        
        return resampled
    }
    
    private func finishRecordingPhrase() async {
        stopAudioEngine()
        timer?.invalidate()
        
        await MainActor.run {
            self.state = .processing(phraseIndex: self.currentPhraseIndex)
        }
        
        // Extract signature from recorded audio
        guard audioBuffer.count >= Int(sampleRate * 2) else { // At least 2 seconds
            await MainActor.run {
                self.state = .failed(EnrollmentError.insufficientAudio)
            }
            return
        }
        
        // Trim to target duration if too long
        let targetSamples = Int(phraseDuration * sampleRate)
        let audioToProcess = Array(audioBuffer.prefix(targetSamples))
        
        // Extract signature
        let signature = verifier.extractSignature(from: audioToProcess)
        phraseSignatures.append(signature)
        
        await MainActor.run {
            self.currentPhraseIndex += 1
            self.updateProgress()
            
            if self.currentPhraseIndex >= self.totalPhrases {
                self.state = .completed
            } else {
                self.state = .notStarted
            }
        }
    }
    
    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateRecordingProgress()
        }
    }
    
    private func updateRecordingProgress() {
        guard let startTime = recordingStartTime else { return }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / phraseDuration, 1.0)
        
        state = .recording(phraseIndex: currentPhraseIndex, progress: progress)
        updateProgress()
    }
    
    private func updateProgress() {
        let recordingProgress: Double
        switch state {
        case .recording(_, let progress):
            recordingProgress = progress
        default:
            recordingProgress = 0.0
        }
        
        progress = EnrollmentProgress(
            currentPhrase: currentPhraseIndex,
            totalPhrases: totalPhrases,
            recordingProgress: recordingProgress,
            isProcessing: false
        )
    }
    
    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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
    
    private func getOwnVoiceSignatureFromKeychain() throws -> [Float]? {
        let keychainService = VoiceKeychainService()
        // Try to load "self" signature first, otherwise use current user ID
        if let signature = try? keychainService.loadSignature(for: "self") {
            return signature.vector
        }
        return nil
    }
}

// MARK: - Enrollment Errors
public enum EnrollmentError: Error, LocalizedError {
    case microphonePermissionDenied
    case insufficientAudio
    case enrollmentComplete
    case processingFailed
    case audioEngineError(String)
    
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for voice enrollment"
        case .insufficientAudio:
            return "Not enough audio recorded. Please try again."
        case .enrollmentComplete:
            return "Enrollment is already complete"
        case .processingFailed:
            return "Failed to process voice signature"
        case .audioEngineError(let details):
            return "Audio engine error: \(details)"
        }
    }
}