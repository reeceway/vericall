import Foundation
import Combine

// MARK: - WebSocket Service
@MainActor
class WebSocketService: ObservableObject {
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
    
    private init() {
        // Constants from other agents
        self.wsBaseURL = "wss://api.vericall.example.com/ws" // Replace with actual wsBaseURL
        self.authToken = nil // TODO: Get from secure storage
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
        do {
            let signal = try JSONDecoder().decode(CallSignal.self, from: data)
            signalContinuation?.yield(signal)
        } catch {
            print("Failed to decode signal: \(error)")
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
    
    func sendHeartbeat() async throws {
        let heartbeat = CallSignal(
            type: .heartbeat,
            callId: "",
            fromUserId: "current_user_id",
            toUserId: "",
            timestamp: Date(),
            payload: CallSignalPayload(),
            signature: nil
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
