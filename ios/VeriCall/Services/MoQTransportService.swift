import Foundation
import Network
import Combine
import UIKit

/// Manages P2P QUIC connections for high-quality audio streaming.
/// Replaces the legacy WebSocket relay and RTP implementation.
class MoQTransportService: ObservableObject {
    static let shared = MoQTransportService()
    
    // MARK: - Types
    
    enum ConnectionState {
        case disconnected
        case advertising
        case connecting
        case connected
        case failed(Error)
    }
    
    // MARK: - Published Properties
    
    @Published var state: ConnectionState = .disconnected
    @Published var peerName: String?
    
    // MARK: - Configuration
    
    private let serviceType = "_vericall._udp" // Bonjour service type
    private let appProtocols = ["vericall-audio-v1"]
    
    // MARK: - Network Objects
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private var audioStream: NWConnection? // Individual stream for audio data
    private let sendControlQueue = DispatchQueue(label: "com.vericall.moq.sendControl")
    private let maxPendingSendPackets = 8
    nonisolated(unsafe) private var pendingSendPackets = 0
    nonisolated(unsafe) private var droppedSendPackets = 0
    
    // MARK: - Callbacks
    
    var onAudioDataReceived: ((Data) -> Void)?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// The local port the listener is bound to (if listening)
    var localPort: UInt16? {
        listener?.port?.rawValue
    }
    
    /// Start advertising this device on the local network via Bonjour
    func startListening() {
        guard listener == nil else { return }
        
        do {
            let parameters = createQUICParameters()
            listener = try NWListener(using: parameters)
            
            // Advertise service
            listener?.service = NWListener.Service(name: getDeviceName(), type: serviceType)
            
            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleListenerStateChange(state)
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                print("[MoQ] New incoming connection from \(newConnection.endpoint)")
                self?.handleIncomingConnection(newConnection)
            }
            
            listener?.start(queue: .main)
            print("[MoQ] Listener started advertising \(getDeviceName())")
            
        } catch {
            print("[MoQ] Failed to create listener: \(error)")
            state = .failed(error)
        }
    }
    
    /// Connect to a specific peer endpoint (discovered via Bonjour or manual IP)
    func connect(to endpoint: NWEndpoint) {
        // Keep listener alive so peers can still route inbound media while we dial out.
        connection?.cancel()
        connection = nil
        
        print("[MoQ] Connecting to \(endpoint)...")
        state = .connecting
        
        let parameters = createQUICParameters()
        if let listenerPort = listener?.port {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("0.0.0.0"),
                port: listenerPort
            )
        }
        let newConnection = NWConnection(to: endpoint, using: parameters)
        
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state)
        }
        
        newConnection.start(queue: .main)
        self.connection = newConnection
    }
    
    /// Connect to a specific Host and Port (WAN P2P)
    func connect(toHost host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connect(to: endpoint)
    }
    
    /// Send audio data to the connected peer
    /// Uses a specialized message format or raw stream depending on requirements.
    /// For this version, we send raw data chunks.
    func sendAudio(_ data: Data) {
        guard let connection = connection, state.isConnected else { return }
        guard !data.isEmpty else { return }

        let shouldDrop = sendControlQueue.sync { () -> Bool in
            if pendingSendPackets >= maxPendingSendPackets {
                droppedSendPackets += 1
                return true
            }
            pendingSendPackets += 1
            return false
        }
        if shouldDrop {
            let dropped = sendControlQueue.sync { droppedSendPackets }
            if dropped % 50 == 0 {
                print("[MoQ] Dropping stale AI packet to protect latency (dropped=\(dropped))")
            }
            return
        }
        
        // In QUIC, we can send on the main connection (as a stream) or create sub-streams.
        // For simplicity and low latency, we'll send as a message on the main connection context
        // marked as "idempotent" if possible, or just standard messaging.
        // Network.framework QUIC maps `send` to QUIC streams automatically.
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.sendControlQueue.async {
                guard let self else { return }
                self.pendingSendPackets = max(0, self.pendingSendPackets - 1)
            }
            if let error = error {
                print("[MoQ] Send error: \(error)")
            }
        })
    }
    
    /// Stop all connections and listening
    func stop() {
        listener?.cancel()
        listener = nil
        
        connection?.cancel()
        connection = nil
        sendControlQueue.sync {
            pendingSendPackets = 0
            droppedSendPackets = 0
        }
        
        state = .disconnected
    }
    
    // MARK: - Internal Handling
    
    private func createQUICParameters() -> NWParameters {
        // QUIC currently fails with NoAuth in this environment; use UDP transport for reliability.
        print("[MoQ] Using UDP transport for AI stream")
        let udpParameters = NWParameters.udp
        udpParameters.allowFastOpen = true
        udpParameters.allowLocalEndpointReuse = true
        return udpParameters
    }
    
    private func handleListenerStateChange(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            print("[MoQ] Listener Ready on port \(localPort ?? 0)")
            if case .disconnected = state {
                state = .advertising
            }
        case .failed(let error):
            print("[MoQ] Listener Failed: \(error)")
            state = .failed(error)
        case .cancelled:
            print("[MoQ] Listener Cancelled")
            state = .disconnected
        default:
            break
        }
    }
    
    private func handleIncomingConnection(_ newConnection: NWConnection) {
        // Accept the connection
        self.connection = newConnection
        
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state)
        }
        
        newConnection.start(queue: .main)
    }
    
    private func handleConnectionStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            print("[MoQ] Connection Ready")
            state = .connected
            startReceiving()
            
        case .waiting(let error):
            print("[MoQ] Connection Waiting: \(error)")
            
        case .failed(let error):
            print("[MoQ] Connection Failed: \(error)")
            state = .failed(error)
            
        case .cancelled:
            print("[MoQ] Connection Cancelled")
            state = .disconnected
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        guard let connection = connection else { return }
        
        // UDP datagram receive loop.
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }
            
            if let data = content, !data.isEmpty {
                // Pass audio data to handler
                self.onAudioDataReceived?(data)
            }
            
            if let error = error {
                print("[MoQ] Receive Error: \(error)")
                self.state = .failed(error)
                return
            }

            // Continue receiving until the connection is cancelled/torn down.
            if self.connection != nil {
                self.startReceiving()
            }
        }
    }
    
    // MARK: - Helpers
    
    private func getDeviceName() -> String {
        let defaults = UserDefaults.standard
        if let userId = defaults.string(forKey: "authUserId"), !userId.isEmpty {
            let normalizedUser = userId.replacingOccurrences(of: "-", with: "").lowercased()
            let userPart = String(normalizedUser.prefix(8))
            let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? ""
            let normalizedVendor = vendorId.replacingOccurrences(of: "-", with: "").lowercased()
            let vendorPart = String(normalizedVendor.prefix(6))
            if !vendorPart.isEmpty {
                return "vc-\(userPart)-\(vendorPart)"
            }
            return "vc-\(userPart)"
        }

        if let cached = defaults.string(forKey: "vericallPeerServiceName"), !cached.isEmpty {
            return cached
        }

        let randomSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fallback = "vc-\(String(randomSuffix.prefix(12)))"
        defaults.set(fallback, forKey: "vericallPeerServiceName")
        return fallback
    }
}

extension MoQTransportService.ConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
