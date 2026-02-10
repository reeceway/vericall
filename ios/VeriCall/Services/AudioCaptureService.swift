import Foundation
import AVFoundation
import Combine

/// Captures real-time audio during active phone calls
/// Provides audio chunks for voice verification
public final class AudioCaptureService: ObservableObject {
    
    // MARK: - Published State
    @Published public private(set) var isCapturing = false
    @Published public private(set) var currentAudioLevel: Float = 0.0
    @Published public private(set) var audioSpectrum: [Float] = []
    
    // MARK: - Delegates
    public weak var delegate: AudioCaptureDelegate?
    
    // MARK: - Private Properties
    private let audioEngine = AVAudioEngine()
    private var captureBuffer: [Float] = []
    private var processingTimer: Timer?
    
    private let chunkDuration: TimeInterval = AudioConfiguration.verificationChunkDuration
    private let sampleRate = AudioConfiguration.sampleRate
    private let chunkSamples: Int
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    public init() {
        self.chunkSamples = Int(chunkDuration * sampleRate)
    }
    
    deinit {
        stopCapture()
    }
    
    // MARK: - Public Methods
    
    /// Start capturing audio during a call
    public func startCapture() async throws {
        guard !isCapturing else { return }
        
        // Request permission
        let authorized = await requestMicrophonePermission()
        guard authorized else {
            throw CaptureError.microphonePermissionDenied
        }
        
        // Setup audio engine
        try setupAudioEngine()
        
        // Reset buffer
        captureBuffer.removeAll()
        
        // Start engine
        try audioEngine.start()
        
        await MainActor.run {
            self.isCapturing = true
        }
        
        // Start processing timer (every 3 seconds)
        DispatchQueue.main.async { [weak self] in
            self?.startProcessingTimer()
        }
        
        print("[AudioCaptureService] Started capturing audio")
    }
    
    /// Stop capturing audio
    public func stopCapture() {
        processingTimer?.invalidate()
        processingTimer = nil
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        
        captureBuffer.removeAll()
        
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            self?.currentAudioLevel = 0.0
            self?.audioSpectrum = []
        }
        
        print("[AudioCaptureService] Stopped capturing audio")
    }
    
    /// Pause capture temporarily
    public func pauseCapture() {
        audioEngine.pause()
        processingTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
        }
    }
    
    /// Resume capture
    public func resumeCapture() throws {
        guard !audioEngine.isRunning else { return }
        try audioEngine.start()
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = true
            self?.startProcessingTimer()
        }
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
        
        // Install tap with larger buffer for efficiency
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        // Configure audio session for call recording
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
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
        
        // Add to capture buffer
        captureBuffer.append(contentsOf: samples)
        
        // Limit buffer size to prevent memory issues (keep last 10 seconds)
        let maxSamples = Int(10 * sampleRate)
        if captureBuffer.count > maxSamples {
            captureBuffer.removeFirst(captureBuffer.count - maxSamples)
        }
        
        // Calculate audio level for visualization
        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(min(samples.count, 1024)))
        rms = sqrt(rms)
        
        // Calculate spectrum for visualization
        let spectrum = calculateSpectrum(samples)
        
        DispatchQueue.main.async { [weak self] in
            self?.currentAudioLevel = min(rms * 10, 1.0)
            self?.audioSpectrum = spectrum
        }
    }
    
    private func calculateSpectrum(_ samples: [Float]) -> [Float] {
        let fftSize = 256
        guard samples.count >= fftSize else { return [Float](repeating: 0, count: 16) }
        
        let frame = Array(samples.prefix(fftSize))
        var windowed = [Float](repeating: 0, count: fftSize)
        let window = vDSP.window(ofLength: fftSize, using: .hanningDenormalized)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        
        guard let fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            return [Float](repeating: 0, count: 16)
        }
        
        var real = windowed
        var imag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        
        vDSP_DFT_Execute(fftSetup, real, imag, &outReal, &outImag)
        vDSP_DFT_DestroySetupD(fftSetup)
        
        // Return 16 frequency bins
        var magnitudes = [Float](repeating: 0, count: 16)
        let binsPerBucket = fftSize / 2 / 16
        
        for i in 0..<16 {
            var sum: Float = 0
            for j in 0..<binsPerBucket {
                let idx = i * binsPerBucket + j
                let mag = sqrt(outReal[idx] * outReal[idx] + outImag[idx] * outImag[idx])
                sum += mag
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
    
    private func startProcessingTimer() {
        processingTimer?.invalidate()
        processingTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.processChunk()
        }
    }
    
    private func processChunk() {
        guard captureBuffer.count >= chunkSamples else {
            print("[AudioCaptureService] Insufficient audio for chunk: \(captureBuffer.count) samples")
            return
        }
        
        // Extract chunk from buffer
        let chunk = Array(captureBuffer.prefix(chunkSamples))
        
        // Notify delegate
        delegate?.audioCaptureService(self, didCaptureChunk: chunk)
        
        // Remove processed samples (keep overlap for smooth transitions)
        let overlapSamples = Int(0.5 * sampleRate) // 0.5 second overlap
        let samplesToRemove = chunkSamples - overlapSamples
        if captureBuffer.count > samplesToRemove {
            captureBuffer.removeFirst(samplesToRemove)
        }
    }
}

// MARK: - Audio Capture Delegate
public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureService(_ service: AudioCaptureService, didCaptureChunk chunk: [Float])
}

// MARK: - Capture Errors
public enum CaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case audioEngineSetupFailed
    case captureInProgress
    case captureNotRunning
    
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for audio capture"
        case .audioEngineSetupFailed:
            return "Failed to setup audio capture engine"
        case .captureInProgress:
            return "Audio capture is already in progress"
        case .captureNotRunning:
            return "Audio capture is not running"
        }
    }
}