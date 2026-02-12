import Foundation
import AVFoundation
import Accelerate
import Combine

/// Streams audio between two peers via WebSocket relay.
///
/// Architecture:
///  - Uses a SINGLE AVAudioEngine for both mic capture and speaker playback
///  - Captures mic -> resamples to 16 kHz mono Float32 -> base64 -> WebSocket
///  - Receives remote audio -> decodes -> plays through AVAudioPlayerNode
///  - Exposes both local and remote audio buffers for voice verification
@MainActor
final class AudioStreamService: ObservableObject {

    static let shared = AudioStreamService()

    // MARK: - Callbacks
    var onAudioConnected: (() -> Void)?

    // MARK: - State
    @Published var isStreaming = false
    @Published var isMuted = false
    @Published var isSpeakerOn = false

    // MARK: - Single audio engine (capture + playback combined)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    // Target format for network transmission (16kHz mono Float32)
    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1
    private var transmitFormat: AVAudioFormat!

    // Playback format - 16kHz incoming data
    private var playbackInputFormat: AVAudioFormat!

    // Resampling for capture (mic rate -> 16kHz)
    private var captureConverter: AVAudioConverter?

    // Audio capture buffer (local mic) for voice verification
    let captureQueue = DispatchQueue(label: "com.vericall.audioStream.cap")
    private(set) var captureBuffer: [Float] = []
    private let maxCaptureDuration: Double = 10.0

    // Remote audio buffer - stores decoded PCM from the other party
    let remoteQueue = DispatchQueue(label: "com.vericall.audioStream.remote")
    private(set) var remoteBuffer: [Float] = []

    // Playback queue for thread-safe player scheduling
    private let playbackQueue = DispatchQueue(label: "com.vericall.audioStream.play")

    // Jitter buffer: accumulate incoming packets before playing
    // At 16kHz Float32, 1600 samples = 100ms worth of audio
    private var jitterData = Data()
    private let jitterThreshold = 1600 * MemoryLayout<Float>.size  // ~100ms

    // Audio gain: keep moderate to avoid overwhelming iOS AEC
    // Earpiece mode + voiceChat provides built-in echo cancellation
    // v3.0: Boost to 3.0 linear to match WavLM training levels (RMS ~0.1), clamped at 1.0
    private let captureGain: Float = 3.0
    private let playbackGain: Float = 3.0

    private var hasNotifiedAudioConnected = false

    // Cached call info for sending from background thread
    // (avoids accessing @MainActor VoIPCallService from captureQueue)
    private var cachedCallId: String?
    private var cachedRemoteUserId: String?

    // WebSocket ref
    private let ws = WebSocketService.shared

    // New RTP / Opus components
    private var rtpReceiver: RTPReceiver?
    private var opusDecoder: OpusDecoder?
    @Published var useRTP: Bool = false {
        didSet {
            if useRTP {
                startRTP()
            } else {
                stopRTP()
            }
        }
    }

    private init() {
        transmitFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
        playbackInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
    }

    // MARK: - Setup / Teardown

    func setup() {
        hasNotifiedAudioConnected = false
        captureBuffer.removeAll()
        remoteBuffer.removeAll()
        jitterData = Data()
        cachedCallId = nil
        cachedRemoteUserId = nil
    }

    func tearDown() {
        stopStreaming()
        stopRTP()
        hasNotifiedAudioConnected = false
        captureBuffer.removeAll()
        remoteBuffer.removeAll()
        jitterData = Data()
        cachedCallId = nil
        cachedRemoteUserId = nil
    }

    // MARK: - Start Streaming

    func startStreaming() {
        guard !isStreaming else {
            print("[AudioStream] Already streaming, ignoring duplicate start")
            return
        }

        // Cache call info so background threads don't need MainActor access
        if let call = VoIPCallService.shared.currentCall {
            cachedCallId = call.id
            cachedRemoteUserId = call.remoteUserId
            print("[AudioStream] Cached call info: callId=\(call.id), remoteUserId=\(call.remoteUserId)")
        } else {
            print("[AudioStream] WARNING: No current call when starting stream!")
        }

        configureAudioSession()
        startEngine()

        isStreaming = true
        print("[AudioStream] Streaming started")
    }

    func startLocalCapture() {
        guard !isStreaming else { return }
        print("[AudioStream] Starting local capture (Lab Mode)")
        
        // No call info needed for local lab
        cachedCallId = nil
        cachedRemoteUserId = nil
        
        configureAudioSession()
        startEngine()
        
        isStreaming = true
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false

        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        stopRTP()

        engine = nil
        playerNode = nil
        captureConverter = nil

        print("[AudioStream] Streaming stopped")
    }

    /// Update cached remote user ID (called when we learn the real backend ID)
    func updateRemoteUserId(_ userId: String) {
        cachedRemoteUserId = userId
        print("[AudioStream] Updated cached remoteUserId: \(userId)")
    }

    // MARK: - Receive Remote Audio

    /// Called when a voip:audio message arrives from the remote user.
    func receiveAudioData(_ base64String: String) {
        guard let data = Data(base64Encoded: base64String) else { return }

        if !hasNotifiedAudioConnected {
            hasNotifiedAudioConnected = true
            Task { @MainActor in
                self.onAudioConnected?()
            }
        }

        // Boost incoming audio volume
        let boostedData = applyGainToData(data, gain: playbackGain)

        // Store remote audio for voice verification (use RAW data, not boosted)
        remoteQueue.async { [weak self] in
            guard let self else { return }
            let frameCount = data.count / MemoryLayout<Float>.size
            guard frameCount > 0 else { return }
            var samples = [Float](repeating: 0, count: frameCount)
            _ = samples.withUnsafeMutableBytes { buf in
                data.copyBytes(to: buf)
            }
            // Remove DC offset from received audio - network transmission
            // can accumulate DC bias that degrades voice feature extraction
            let mean = samples.reduce(0, +) / Float(samples.count)
            if abs(mean) > 0.001 {
                for i in 0..<samples.count {
                    samples[i] -= mean
                }
            }
            self.remoteBuffer.append(contentsOf: samples)
            let maxSamples = Int(self.maxCaptureDuration * self.targetSampleRate)
            if self.remoteBuffer.count > maxSamples {
                self.remoteBuffer.removeFirst(self.remoteBuffer.count - maxSamples)
            }
        }

        // Enqueue BOOSTED audio for playback via jitter buffer
        playbackQueue.async { [weak self] in
            self?.bufferAndPlay(boostedData)
        }
    }

    // MARK: - Controls

    func setMicrophoneEnabled(_ enabled: Bool) {
        isMuted = !enabled
    }

    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use earpiece by default (NOT .defaultToSpeaker)
            // Earpiece provides much better echo cancellation because:
            //  - Speaker is quieter and directional (aimed at ear)
            //  - iOS AEC is specifically tuned for earpiece mode
            //  - Loudspeaker overwhelms AEC at high gain levels
            // User can toggle to speaker mode via setSpeaker()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth]
            )
            try session.setPreferredIOBufferDuration(0.02) // 20ms HW buffer
            try session.setActive(true)
            print("[AudioStream] Audio session configured (hw rate: \(session.sampleRate), buf: \(session.ioBufferDuration)s)")
        } catch {
            print("[AudioStream] Audio session error: \(error)")
        }
    }

    // MARK: - Single Engine (Capture + Playback)

    private func startEngine() {
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()

        // Attach player to the engine
        eng.attach(player)

        // Connect player to mixer at 16kHz - AVAudioEngine handles
        // sample rate conversion to hardware rate internally
        eng.connect(player, to: eng.mainMixerNode, format: playbackInputFormat)

        // Set up mic capture
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioStream] Mic input format: rate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)")

        // Create converter from mic format -> 16kHz mono if needed
        if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != targetChannels {
            captureConverter = AVAudioConverter(from: inputFormat, to: transmitFormat)
            print("[AudioStream] Created capture converter: \(inputFormat.sampleRate) -> \(targetSampleRate)")
        }

        // Install mic tap - 1024 frames for lower latency
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureQueue.async {
                self.handleCapturedAudio(buffer)
            }
        }

        // Start the engine
        do {
            try eng.start()
            player.play()
            self.engine = eng
            self.playerNode = player
            print("[AudioStream] Engine started (capture + playback)")
        } catch {
            print("[AudioStream] Failed to start engine: \(error)")
        }
    }

    // MARK: - Capture (Mic -> WebSocket)

    private func handleCapturedAudio(_ buffer: AVAudioPCMBuffer) {
        // Resample to 16kHz if needed
        let finalBuffer: AVAudioPCMBuffer
        if let conv = captureConverter {
            guard let converted = convertBuffer(buffer, using: conv) else { return }
            finalBuffer = converted
        } else {
            finalBuffer = buffer
        }

        // Store in capture buffer (for local voice verification)
        if let channelData = finalBuffer.floatChannelData?[0] {
            let count = Int(finalBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
            captureBuffer.append(contentsOf: samples)
            let maxSamples = Int(maxCaptureDuration * targetSampleRate)
            if captureBuffer.count > maxSamples {
                captureBuffer.removeFirst(captureBuffer.count - maxSamples)
            }
        }

        // Skip sending if muted
        guard !isMuted else { return }

        // Send every captured buffer - no throttling
        // Previously dropped every other buffer causing choppy audio
        guard let callId = cachedCallId, let remoteUserId = cachedRemoteUserId else {
            return
        }

        let data = pcmBufferToDataWithGain(finalBuffer, gain: captureGain)
        let base64 = data.base64EncodedString()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ws.sendRaw(message: [
                    "type": "voip:audio",
                    "callId": callId,
                    "toUserId": remoteUserId,
                    "audio": base64
                ])
            } catch {
                // Errors are expected occasionally
            }
        }
    }

    // MARK: - Jitter Buffer + Playback

    /// Accumulate incoming audio data and play in larger batches
    /// to smooth out network jitter and prevent playback gaps.
    private func bufferAndPlay(_ data: Data) {
        jitterData.append(data)

        // When we have enough data (~100ms), flush to the player
        guard jitterData.count >= jitterThreshold else { return }

        let playData = jitterData
        jitterData = Data()
        enqueueForPlayback(playData)
    }

    private func enqueueForPlayback(_ data: Data) {
        guard let player = playerNode, let eng = engine, eng.isRunning else {
            return
        }

        let frameCount = UInt32(data.count / MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackInputFormat,
            frameCapacity: frameCount
        ) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(buffer.floatChannelData![0], src, data.count)
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Conversion Helpers

    private func convertBuffer(_ input: AVAudioPCMBuffer, using conv: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetSampleRate / input.format.sampleRate
        let outputFrameCount = UInt32(Double(input.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: transmitFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var isDone = false
        conv.convert(to: output, error: &error) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            print("[AudioStream] Conversion error: \(error)")
            return nil
        }
        return output
    }

    private func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData?[0] else { return Data() }
        let count = Int(buffer.frameLength)
        return Data(bytes: channelData, count: count * MemoryLayout<Float>.size)
    }

    /// Convert PCM buffer to Data with gain applied
    private func pcmBufferToDataWithGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> Data {
        guard let channelData = buffer.floatChannelData?[0] else { return Data() }
        let count = Int(buffer.frameLength)
        var amplified = [Float](repeating: 0, count: count)
        var g = gain
        vDSP_vsmul(channelData, 1, &g, &amplified, 1, vDSP_Length(count))
        
        // No tanh compression - keep linear for AI model accuracy
        // Just hard clamp to prevent massive blowouts if gain > 1
        for i in 0..<count {
            if amplified[i] > 1.0 { amplified[i] = 1.0 }
            else if amplified[i] < -1.0 { amplified[i] = -1.0 }
        }
        
        return amplified.withUnsafeBytes { Data($0) }
    }

    /// Apply gain to raw Float32 audio data
    private func applyGainToData(_ data: Data, gain: Float) -> Data {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return data }
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { buf in
            data.copyBytes(to: buf)
        }
        var g = gain
        vDSP_vsmul(samples, 1, &g, &samples, 1, vDSP_Length(count))
        
        // No tanh - AI model needs linear audio
        for i in 0..<count {
             if samples[i] > 1.0 { samples[i] = 1.0 }
             else if samples[i] < -1.0 { samples[i] = -1.0 }
        }
        
        return samples.withUnsafeBytes { Data($0) }
    }

    // MARK: - RTP Mode Logic

    private func startRTP() {
        print("[AudioStream] Enabling RTP Mode (UDP 5004)...")
        rtpReceiver = RTPReceiver()
        opusDecoder = OpusDecoder(outputFormat: playbackInputFormat)
        
        rtpReceiver?.onOpusPacketReceived = { [weak self] packet in
            guard let self = self, let decoded = self.opusDecoder?.decode(packet: packet) else { return }
            self.handleDecodedRTPAudio(decoded)
        }
        rtpReceiver?.start()
    }
    
    private func stopRTP() {
        if rtpReceiver != nil {
            print("[AudioStream] Disabling RTP Mode")
        }
        rtpReceiver?.stop()
        rtpReceiver = nil
        opusDecoder = nil
    }

    private func handleDecodedRTPAudio(_ buffer: AVAudioPCMBuffer) {
        // Decoded buffer is already 16kHz mono Float32 (from playbackInputFormat)
        let data = pcmBufferToData(buffer)
        
        // 1. Playback
        playbackQueue.async { [weak self] in
            self?.enqueueForPlayback(data)
        }
        
        // 2. Push to remoteBuffer for Verification
        remoteQueue.async { [weak self] in
            guard let self = self else { return }
            let count = Int(buffer.frameLength)
            if let ptr = buffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: ptr, count: count))
                self.remoteBuffer.append(contentsOf: samples)
                
                // Keep buffer within limits
                let maxSamples = Int(self.maxCaptureDuration * self.targetSampleRate)
                if self.remoteBuffer.count > maxSamples {
                    self.remoteBuffer.removeFirst(self.remoteBuffer.count - maxSamples)
                }
            }
        }
    }
}
