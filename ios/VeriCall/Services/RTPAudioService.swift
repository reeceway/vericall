import Foundation
import Network
import AVFoundation
import Accelerate
import Combine

/// RTP (UDP) Audio Service for ultra-low latency phone-to-phone conversation.
/// This is separate from MoQ - RTP handles the "human conversation" path.
/// MoQ handles the "AI analysis" path.
@MainActor
final class RTPAudioService: ObservableObject {
    
    static let shared = RTPAudioService()
    
    // MARK: - Published State
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    
    // MARK: - Configuration
    private let rtpPort: UInt16 = 5004  // Standard RTP port
    private var localPort: UInt16?
    
    // MARK: - Network
    private var rtpSocket: NWListener?
    private var peerConnection: NWConnection?
    private var peerEndpoint: NWEndpoint?
    
    // MARK: - Audio Engine (separate from MoQ)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    // RTP uses 48kHz stereo for best voice quality, 20ms packets
    private let rtpSampleRate: Double = 48_000
    private let rtpChannels: AVAudioChannelCount = 1  // Mono for voice efficiency
    private var rtpFormat: AVAudioFormat!
    
    // Capture converter (system rate -> RTP rate)
    private var captureConverter: AVAudioConverter?
    
    // MARK: - Audio Processing
    private let captureQueue = DispatchQueue(label: "com.vericall.rtp.capture")
    private let playbackQueue = DispatchQueue(label: "com.vericall.rtp.playback")
    
    // Opus decoder for incoming RTP audio (phone conversation)
    private var opusDecoder: OpusDecoder?

    // 20ms frame size at 48kHz
    private let frameDurationMs: Int = 20
    private var frameSize: Int { Int(rtpSampleRate * Double(frameDurationMs) / 1000) }
    
    // MARK: - Callbacks
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    
    private init() {
        rtpFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rtpSampleRate,
            channels: rtpChannels,
            interleaved: false
        )!
    }
    
    // MARK: - Public API
    
    var currentLocalPort: UInt16? {
        localPort
    }
    
    /// Start listening for incoming RTP connections
    func startListening() {
        guard rtpSocket == nil else { return }
        
        do {
            let params = NWParameters.udp
            params.allowFastOpen = true

            rtpSocket = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: rtpPort))
            rtpSocket?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.localPort = self?.rtpPort
                        print("[RTP] Listening on port \(self?.rtpPort ?? 0)")
                    case .failed(let error):
                        print("[RTP] Listener failed: \(error)")
                    default:
                        break
                    }
                }
            }

            rtpSocket?.newConnectionHandler = { [weak self] connection in
                print("[RTP] New peer connection")
                DispatchQueue.main.async {
                    self?.handlePeerConnection(connection)
                }
            }

            rtpSocket?.start(queue: .global(qos: .userInteractive))

        } catch {
            print("[RTP] Failed to create listener: \(error)")
        }
    }
    
    /// Connect to peer for RTP (ultra-low latency path)
    func connectToPeer(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(integerLiteral: port))
        peerEndpoint = endpoint
        
        let params = NWParameters.udp
        params.allowFastOpen = true
        
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("[RTP] Connected to peer \(host):\(port)")
                    self?.isConnected = true
                    self?.onConnected?()
                    self?.receiveAudioData()
                case .failed(let error):
                    print("[RTP] Connection failed: \(error)")
                    self?.isConnected = false
                case .cancelled:
                    self?.isConnected = false
                default:
                    break
                }
            }
        }
        
        peerConnection = conn
        conn.start(queue: .global(qos: .userInteractive))
    }
    
    /// Connect via Bonjour service discovery
    func connectToPeer(deviceName: String) {
        let endpoint = NWEndpoint.service(name: deviceName, type: "_vericall-rtp._udp", domain: "local", interface: nil)
        
        let params = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("[RTP] Connected to \(deviceName) via Bonjour")
                    self?.isConnected = true
                    self?.onConnected?()
                    self?.receiveAudioData()
                case .failed(let error):
                    print("[RTP] Bonjour connection failed: \(error)")
                    self?.isConnected = false
                default:
                    break
                }
            }
        }
        
        peerConnection = conn
        conn.start(queue: .global(qos: .userInteractive))
    }
    
    /// Start RTP audio streaming (phone-to-phone conversation)
    func startStreaming() {
        guard !isStreaming else { return }

        setupAudioSession()
        startAudioEngine()

        // Initialize Opus decoder for incoming audio
        opusDecoder = OpusDecoder(outputFormat: rtpFormat)

        isStreaming = true
        print("[RTP] Streaming started - ultra-low latency voice path active")
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
        opusDecoder = nil

        print("[RTP] Streaming stopped")
    }
    
    func disconnect() {
        stopStreaming()
        peerConnection?.cancel()
        peerConnection = nil
        peerEndpoint = nil
        isConnected = false
        onDisconnected?()
    }
    
    // MARK: - Private Methods
    
    private func handlePeerConnection(_ connection: NWConnection) {
        peerConnection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("[RTP] Peer connected")
                    self?.isConnected = true
                    self?.onConnected?()
                    self?.receiveAudioData()
                case .failed, .cancelled:
                    print("[RTP] Peer disconnected")
                    self?.isConnected = false
                    self?.onDisconnected?()
                default:
                    break
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    private func receiveAudioData() {
        peerConnection?.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data else {
                if let error = error {
                    print("[RTP] Receive error: \(error)")
                }
                return
            }
            
            // Decode Opus and play immediately (ultra-low latency path)
            self.playbackQueue.async {
                self.handleIncomingRTPPacket(data)
            }
            
            // Continue receiving
            if !isComplete {
                self.receiveAudioData()
            }
        }
    }
    
    private func handleIncomingRTPPacket(_ data: Data) {
        // Decode Opus to PCM using OpusDecoder
        guard let buffer = opusDecoder?.decode(packet: data) else { return }
        
        // Schedule for immediate playback
        if let player = playerNode, player.engine?.isRunning == true {
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use voice chat mode for lowest latency
            // Speaker option depends on isSpeakerOn setting
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
            if isSpeakerOn {
                options.insert(.defaultToSpeaker)
            }
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
            // Ultra-low buffer: 5ms for RTP voice path
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            print("[RTP] Audio session error: \(error)")
        }
    }
    
    private func startAudioEngine() {
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        
        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: rtpFormat)
        
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Setup converter if needed
        if inputFormat.sampleRate != rtpSampleRate || inputFormat.channelCount != rtpChannels {
            captureConverter = AVAudioConverter(from: inputFormat, to: rtpFormat)
        }
        
        // Install tap - capture and send via RTP
        let captureBlockSize = UInt32(frameSize)
        inputNode.installTap(onBus: 0, bufferSize: captureBlockSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.captureQueue.async {
                self.processAndSendAudio(buffer)
            }
        }
        
        do {
            try eng.start()
            player.play()
            self.engine = eng
            self.playerNode = player
            print("[RTP] Audio engine started at \(rtpSampleRate)Hz")
        } catch {
            print("[RTP] Failed to start engine: \(error)")
        }
    }
    
    private func processAndSendAudio(_ buffer: AVAudioPCMBuffer) {
        // Don't send audio if muted
        guard !isMuted else { return }

        // Convert to RTP format
        let finalBuffer: AVAudioPCMBuffer
        if let conv = captureConverter {
            guard let converted = convertBuffer(buffer, using: conv) else { return }
            finalBuffer = converted
        } else {
            finalBuffer = buffer
        }

        // Send raw PCM via UDP (ultra-low latency)
        // Convert buffer to Data and send
        guard let channelData = finalBuffer.floatChannelData?[0] else { return }
        let frameLength = Int(finalBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        // Convert samples to Data
        var data = Data()
        data.append(contentsOf: samples.withUnsafeBytes { Array($0) })

        // Send via UDP (ultra-low latency)
        sendRTPPacket(data)
    }
    
    private func sendRTPPacket(_ data: Data) {
        guard let conn = peerConnection else { return }
        
        conn.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[RTP] Send error: \(error)")
            }
        })
    }
    
    private func convertBuffer(_ input: AVAudioPCMBuffer, using conv: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = rtpSampleRate / input.format.sampleRate
        let outputFrameCount = UInt32(Double(input.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(pcmFormat: rtpFormat, frameCapacity: outputFrameCount) else { return nil }
        
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
}
