import Foundation
import AVFoundation
import Accelerate
import Combine
import Network

/// Streams audio between two peers via QUIC P2P (MoQ).
///
/// Architecture:
///  - Uses a SINGLE AVAudioEngine for both mic capture and speaker playback
///  - Captures mic -> Raw PCM Float32 (16kHz) -> QUIC Stream (MoQTransportService)
///  - Receives QUIC Stream -> Raw PCM Float32 -> plays through AVAudioPlayerNode
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
    @Published var isP2PConnected = false

    // MARK: - Single audio engine (capture + playback combined)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    // Target format for playback/analysis (16kHz mono Float32)
    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1
    private var workFormat: AVAudioFormat!
    
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
    
    // Audio gain
    private let captureGain: Float = 3.0
    private let playbackGain: Float = 3.0
    
    // Transport
    let transport = MoQTransportService.shared
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        workFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
        
        setupTransportObservations()
    }

    // MARK: - Setup / Teardown

    func setup() {
        captureBuffer.removeAll()
        remoteBuffer.removeAll()
        
        // Start listening for P2P connections
        transport.startListening()
        
        // Handle incoming data
        transport.onAudioDataReceived = { [weak self] data in
            self?.handleIncomingAudio(data)
        }
    }

    func tearDown() {
        stopStreaming()
        transport.stop()
        captureBuffer.removeAll()
        remoteBuffer.removeAll()
    }

    private func setupTransportObservations() {
        transport.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isP2PConnected = state.isConnected
                if state.isConnected {
                    print("[AudioStream] P2P Connected via QUIC")
                    self?.onAudioConnected?()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Peer Connection
    
    /// Connect to a peer (called by signaling when we know the endpoint)
    func connectToPeer(endpoint: NWEndpoint) {
        transport.connect(to: endpoint)
    }
    
    /// Helper to connect via Bonjour name
    func connectToPeer(callerName: String) {
        print("[AudioStream] Connecting to peer named: \(callerName)")
        let endpoint = NWEndpoint.service(name: callerName, type: "_vericall._udp", domain: "local", interface: nil)
        connectToPeer(endpoint: endpoint)
    }
    
    /// Connect to a specific Host and Port (WAN P2P)
    func connectToPeer(host: String, port: UInt16) {
        transport.connect(toHost: host, port: port)
    }

    // MARK: - Start Streaming

    func startStreaming() {
        guard !isStreaming else { return }

        configureAudioSession()
        startEngine()

        isStreaming = true
        print("[AudioStream] Streaming started")
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false

        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()

        engine = nil
        playerNode = nil
        captureConverter = nil

        print("[AudioStream] Streaming stopped")
    }

    // MARK: - Receive Remote Audio

    /// Called when data arrives via QUIC (MoQ path - AI analysis ONLY)
    /// NOTE: Audio is NOT played through speaker here - RTP handles phone conversation
    private func handleIncomingAudio(_ data: Data) {
        // MoQ path: Store audio for AI verification/analysis ONLY
        // RTP path handles the actual phone conversation playback
        
        remoteQueue.async { [weak self] in
            guard let self else { return }
            
            // Convert Data -> [Float]
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0 else { return }
            
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { buf in
                data.copyBytes(to: buf)
            }
            
            // Remove DC offset
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
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth]
            )
            try session.setPreferredIOBufferDuration(0.005) // 5ms buffer for ultra-low latency P2P
            try session.setActive(true)
        } catch {
            print("[AudioStream] Audio session error: \(error)")
        }
    }

    // MARK: - Audio Engine

    private func startEngine() {
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()

        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: workFormat)

        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Converter: Mic Format -> 16kHz
        if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != targetChannels {
            captureConverter = AVAudioConverter(from: inputFormat, to: workFormat)
        }

        // Tap Mic
        inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureQueue.async {
                self.handleCapturedAudio(buffer)
            }
        }

        do {
            try eng.start()
            player.play()
            self.engine = eng
            self.playerNode = player
            print("[AudioStream] Engine started")
        } catch {
            print("[AudioStream] Failed to start engine: \(error)")
        }
    }

    // MARK: - Capture Handling

    private func handleCapturedAudio(_ buffer: AVAudioPCMBuffer) {
        // Resample
        let finalBuffer: AVAudioPCMBuffer
        if let conv = captureConverter {
            guard let converted = convertBuffer(buffer, using: conv) else { return }
            finalBuffer = converted
        } else {
            finalBuffer = buffer
        }

        // Store for Verification
        if let channelData = finalBuffer.floatChannelData?[0] {
            let count = Int(finalBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
            captureBuffer.append(contentsOf: samples)
            let maxSamples = Int(maxCaptureDuration * targetSampleRate)
            if captureBuffer.count > maxSamples {
                captureBuffer.removeFirst(captureBuffer.count - maxSamples)
            }
        }

        // Send via MoQ
        if !isMuted {
            let data = pcmBufferToDataWithGain(finalBuffer, gain: captureGain)
            transport.sendAudio(data)
        }
    }
    
    // MARK: - Playback
    
    private func enqueueForPlayback(_ data: Data) {
        guard let player = playerNode, let eng = engine, eng.isRunning else { return }
        
        let frameCount = UInt32(data.count / MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: workFormat,
            frameCapacity: frameCount
        ) else { return }
        
        buffer.frameLength = frameCount
        
        // Apply Gain and Copy
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            
            // Allow applying gain during copy if needed, but we apply at capture source
            // So just copy direct
            memcpy(buffer.floatChannelData![0], src, data.count)
        }
        
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    // MARK: - Conversion Helpers

    private func convertBuffer(_ input: AVAudioPCMBuffer, using conv: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetSampleRate / input.format.sampleRate
        let outputFrameCount = UInt32(Double(input.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: workFormat,
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
        return output
    }
    
    private func pcmBufferToDataWithGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> Data {
        guard let channelData = buffer.floatChannelData?[0] else { return Data() }
        let count = Int(buffer.frameLength)
        var amplified = [Float](repeating: 0, count: count)
        var g = gain
        vDSP_vsmul(channelData, 1, &g, &amplified, 1, vDSP_Length(count))
        
        // Hard clamp
        for i in 0..<count {
            if amplified[i] > 1.0 { amplified[i] = 1.0 }
            else if amplified[i] < -1.0 { amplified[i] = -1.0 }
        }
        
        return amplified.withUnsafeBytes { Data($0) }
    }
}
