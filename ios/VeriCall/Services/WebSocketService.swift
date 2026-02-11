import Foundation
import Combine

// MARK: - WebSocket Service
@MainActor
class WebSocketService: NSObject, ObservableObject {
    static let shared = WebSocketService()
    
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectDelay: TimeInterval = 1.0
    private var isReconnecting = false
    
    private let wsBaseURL: String
    private let authToken: String?
    
    private var signalContinuation: AsyncStream<CallSignal>.Continuation?
    
    var incomingSignals: AsyncStream<CallSignal> {
        AsyncStream { continuation in
            self.signalContinuation = continuation
        }
    }
    
    private override init() {
        // Constants from other agents
        self.wsBaseURL = "wss://api.vericall.example.com/ws" // Replace with actual wsBaseURL
        self.authToken = nil // TODO: Get from secure storage
        super.init()
    }
    
    // MARK: - Connection
    func connect() {
        guard webSocketTask == nil || webSocketTask?.state == .completed else {
            return // Already connected or connecting
        }
        
        connectionStatus = .connecting
        
        guard let url = URL(string: wsBaseURL) else {
            connectionStatus = .error("Invalid WebSocket URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        // Add auth token if available
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.delegate = self
        
        webSocketTask?.resume()
        
        // Start receiving messages
        receiveMessage()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionStatus = .disconnected
        reconnectAttempts = 0
    }
    
    // MARK: - Reconnection
    private func scheduleReconnect() {
        guard !isReconnecting, reconnectAttempts < maxReconnectAttempts else {
            if reconnectAttempts >= maxReconnectAttempts {
                connectionStatus = .error("Max reconnection attempts reached")
            }
            return
        }
        
        isReconnecting = true
        reconnectAttempts += 1
        
        connectionStatus = .reconnecting(attempt: reconnectAttempts)
        
        let delay = min(reconnectDelay * pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            await MainActor.run {
                self.isReconnecting = false
                self.connect()
            }
        }
    }
    
    // MARK: - Message Handling
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    // Continue receiving
                    self.receiveMessage()
                    
                case .failure(let error):
                    print("WebSocket receive error: \(error)")
                    self.connectionStatus = .error(error.localizedDescription)
                    self.scheduleReconnect()
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            handleBinaryMessage(data)
        @unknown default:
            break
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        handleBinaryMessage(data)
    }
    
    private func handleBinaryMessage(_ data: Data) {
        // First try to parse as generic JSON to check message type
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageType = json["type"] as? String {
            
            // Handle native call handshake messages
            if messageType.hasPrefix("native_call:") {
                Task { @MainActor in
                    await handleNativeCallMessage(json: json, type: messageType)
                }
                return
            }
        }
        
        // Otherwise decode as CallSignal
        do {
            let signal = try JSONDecoder().decode(CallSignal.self, from: data)
            signalContinuation?.yield(signal)
        } catch {
            print("Failed to decode signal: \(error)")
        }
    }
    
    @MainActor
    private func handleNativeCallMessage(json: [String: Any], type: String) async {
        let observer = NativeCallObserver.shared
        
        switch type {
        case "native_call:handshake":
            // Someone is calling us and sent their thumbprint
            if let fromUserId = json["fromUserId"] as? String,
               let thumbprint = json["voiceThumbprint"] as? [Double],
               let phoneNumber = json["phoneNumber"] as? String {
                let floatThumbprint = thumbprint.map { Float($0) }
                let displayName = json["displayName"] as? String
                await observer.handleReceivedHandshake(
                    fromUserId: fromUserId,
                    displayName: displayName,
                    voiceThumbprint: floatThumbprint,
                    phoneNumber: phoneNumber
                )
            }
            
        case "native_call:request_thumbprint":
            // They're requesting our thumbprint
            if let fromUserId = json["fromUserId"] as? String,
               let phoneNumber = json["phoneNumber"] as? String {
                await observer.handleThumbprintRequest(fromUserId: fromUserId, phoneNumber: phoneNumber)
            }
            
        case "native_call:handshake_response":
            // Response to our outgoing call handshake
            if let fromUserId = json["fromUserId"] as? String,
               let thumbprint = json["voiceThumbprint"] as? [Double],
               let phoneNumber = json["phoneNumber"] as? String {
                let floatThumbprint = thumbprint.map { Float($0) }
                let displayName = json["displayName"] as? String
                await observer.handleReceivedHandshake(
                    fromUserId: fromUserId,
                    displayName: displayName,
                    voiceThumbprint: floatThumbprint,
                    phoneNumber: phoneNumber
                )
            }
            
        default:
            print("[WebSocketService] Unknown native call message type: \(type)")
        }
    }
    
    // MARK: - Send Signal
    func sendSignal(_ signal: CallSignal) async throws {
        guard connectionStatus.isConnected else {
            throw CallError.webSocketDisconnected
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(signal)
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode signal")
        }
        
        try await webSocketTask?.send(.string(jsonString))
    }
    
    
    // MARK: - Send Raw Message (for native call handshakes)
    func sendRaw(message: [String: Any]) async throws {
        guard connectionStatus.isConnected else {
            throw CallError.webSocketDisconnected
        }
        
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode raw message")
        }
        
        try await webSocketTask?.send(.string(jsonString))
    }

    func sendHeartbeat() async throws {
        let heartbeat = CallSignal(
            type: .heartbeat,
            callId: "",
            fromUserId: "current_user_id",
            toUserId: "",
            timestamp: Date(),
            payload: CallSignalPayload(),
            signature: nil,
            voiceThumbprint: nil
        )
        
        try await sendSignal(heartbeat)
    }
}

// MARK: - URLSessionWebSocketDelegate
extension WebSocketService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            print("WebSocket connected")
            self.connectionStatus = .connected
            self.reconnectAttempts = 0
        }
    }
    
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            print("WebSocket closed with code: \(closeCode)")
            self.connectionStatus = .disconnected
            self.scheduleReconnect()
        }
    }
    
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            Task { @MainActor in
                print("WebSocket error: \(error)")
                self.connectionStatus = .error(error.localizedDescription)
                self.scheduleReconnect()
            }
        }
    }
}

// MARK: - Heartbeat Manager
class WebSocketHeartbeatManager {
    static let shared = WebSocketHeartbeatManager()
    
    private var timer: Timer?
    private let interval: TimeInterval = 30.0
    private let webSocketService = WebSocketService.shared
    
    private init() {}
    
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                try? await self?.webSocketService.sendHeartbeat()
            }
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
