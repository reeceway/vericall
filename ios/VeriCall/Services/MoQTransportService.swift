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
        stop() // Ensure clean slate
        
        print("[MoQ] Connecting to \(endpoint)...")
        state = .connecting
        
        let parameters = createQUICParameters()
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
        
        // In QUIC, we can send on the main connection (as a stream) or create sub-streams.
        // For simplicity and low latency, we'll send as a message on the main connection context
        // marked as "idempotent" if possible, or just standard messaging.
        // Network.framework QUIC maps `send` to QUIC streams automatically.
        
        connection.send(content: data, completion: .contentProcessed { error in
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
        
        state = .disconnected
    }
    
    // MARK: - Internal Handling
    
    private func createQUICParameters() -> NWParameters {
        let parameters = NWParameters.quic(alpn: appProtocols)
        
        // Security configuration (TLS 1.3 is built-in to QUIC)
        // For local P2P dev without signed certs, we might need to trust self-signed.
        // In production, use proper Identity.
        
        if let securityOptions = parameters.defaultProtocolStack.applicationProtocols[0] as? NWProtocolTLS.Options {
             sec_protocol_options_set_verify_block(securityOptions.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                 // TRUST ALL CERTIFICATES FOR LOCAL P2P DEMO
                 // TODO: Implement proper trust logic with DeviceCrypto keys
                 let _ = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                 sec_protocol_verify_complete(true)
             }, .main)
        }
        
        return parameters
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
        
        // Receive loop
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = content, !data.isEmpty {
                // Pass audio data to handler
                self.onAudioDataReceived?(data)
            }
            
            if let error = error {
                print("[MoQ] Receive Error: \(error)")
                return
            }
            
            if isComplete {
                print("[MoQ] Peer closed connection")
                self.stop()
                return
            }
            
            // Continue receiving
            self.startReceiving()
        }
    }
    
    // MARK: - Helpers
    
    private func getDeviceName() -> String {
        return UserDefaults.standard.string(forKey: "userName") ?? UIDevice.current.name
    }
}

extension MoQTransportService.ConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
