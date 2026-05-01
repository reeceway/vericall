import Foundation
import Combine

// MARK: - WebSocket Service
@MainActor
class WebSocketService: NSObject, ObservableObject {
    static let shared = WebSocketService()
    
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private enum WebSocketAuthMode: String {
        case queryParam = "query-param"
        case authMessage = "auth-message"
    }
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectDelay: TimeInterval = 1.0
    private var isReconnecting = false
    private var isSwitchingAuthMode = false
    private var authMode: WebSocketAuthMode = .queryParam
    private var authTokenForSession: String?
    private var attemptedAuthMessageFallback = false
    
    private var signalContinuation: AsyncStream<CallSignal>.Continuation?
    
    var incomingSignals: AsyncStream<CallSignal> {
        AsyncStream { continuation in
            self.signalContinuation = continuation
        }
    }
    
    private override init() {
        super.init()
    }
    
    // MARK: - Connection
    func connect() {
        connect(using: authMode)
    }
    
    private func connect(using mode: WebSocketAuthMode) {
        guard webSocketTask == nil || webSocketTask?.state == .completed else {
            print("[WebSocketService] Already connected or connecting")
            return
        }
        
        connectionStatus = .connecting
        
        // Get auth token first
        guard let token = getAuthToken() else {
            print("[WebSocketService] ❌ No auth token in UserDefaults - cannot connect")
            connectionStatus = .error("Not authenticated")
            return
        }
        authTokenForSession = token
        authMode = mode
        
        print("[WebSocketService] ✅ Found auth token: \(token.prefix(20))...")
        
        let wsURLString: String
        switch mode {
        case .queryParam:
            guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                connectionStatus = .error("Failed to encode auth token")
                return
            }
            wsURLString = Constants.wsBaseURL + "/ws?token=\(encodedToken)"
        case .authMessage:
            wsURLString = Constants.wsBaseURL + "/ws"
        }
        
        guard let url = URL(string: wsURLString) else {
            connectionStatus = .error("Invalid WebSocket URL")
            print("[WebSocketService] ❌ Invalid URL")
            return
        }
        
        print("[WebSocketService] 📡 Connecting to: \(Constants.wsBaseURL)/ws [\(mode.rawValue)]")
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.delegate = self
        
        webSocketTask?.resume()
        
        // Start receiving messages
        receiveMessage()
    }
    
    private func getAuthToken() -> String? {
        // Use UserDefaults for auth token (simpler for now)
        // In production, migrate to Keychain with proper async handling
        return UserDefaults.standard.string(forKey: "authToken")
    }
    
    func disconnect() {
        print("[WebSocketService] Disconnecting")
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionStatus = .disconnected
        reconnectAttempts = 0
        isSwitchingAuthMode = false
        authMode = .queryParam
        authTokenForSession = nil
        attemptedAuthMessageFallback = false
    }
    
    // MARK: - Reconnection
    private func scheduleReconnect() {
        guard !isReconnecting, reconnectAttempts < maxReconnectAttempts else {
            if reconnectAttempts >= maxReconnectAttempts {
                connectionStatus = .error("Max reconnection attempts reached")
                print("[WebSocketService] Max reconnection attempts reached")
            }
            return
        }
        
        isReconnecting = true
        reconnectAttempts += 1
        
        connectionStatus = .reconnecting(attempt: reconnectAttempts)
        print("[WebSocketService] Reconnecting... attempt \(reconnectAttempts)")
        
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
                    self.receiveMessage()
                    
                case .failure(let error):
                    print("[WebSocketService] Receive error: \(error)")
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
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageType = json["type"] as? String {
            
            if messageType == "error",
               let message = json["message"] as? String,
               shouldFallbackToAuthMessage(for: message) {
                fallbackToAuthMessageMode()
                return
            }
            
            // Route VoIP call signaling messages
            if messageType.hasPrefix("voip:") {
                guard Constants.preferredCallProvider != .twilioVoice else {
                    print("[WebSocketService] Ignoring legacy VoIP signaling while Twilio is active: \(messageType)")
                    return
                }
                if messageType != "voip:audio" &&
                    messageType != "voip:ai-audio" &&
                    messageType != "voip:sdp-offer" &&
                    messageType != "voip:sdp-answer" &&
                    messageType != "voip:ice-candidate" {
                    print("[WebSocketService] VoIP message: \(messageType)")
                }
                Task { @MainActor in
                    VoIPCallService.shared.handleSignalingMessage(json, type: messageType)
                }
                return
            }
            
            if messageType.hasPrefix("native_call:") {
                print("[WebSocketService] Ignoring legacy native call message while Twilio is active: \(messageType)")
                return
            }
        }
        
        do {
            let signal = try JSONDecoder().decode(CallSignal.self, from: data)
            signalContinuation?.yield(signal)
        } catch {
            print("[WebSocketService] Failed to decode signal: \(error)")
        }
    }
    
    private func shouldFallbackToAuthMessage(for errorMessage: String) -> Bool {
        guard authMode == .queryParam else { return false }
        guard !attemptedAuthMessageFallback else { return false }
        
        let normalized = errorMessage.lowercased()
        return normalized.contains("expected auth message")
    }
    
    private func fallbackToAuthMessageMode() {
        guard authMode == .queryParam else { return }
        guard !attemptedAuthMessageFallback else { return }
        
        print("[WebSocketService] Server expects auth payload. Retrying with auth-message mode.")
        attemptedAuthMessageFallback = true
        authMode = .authMessage
        isSwitchingAuthMode = true
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionStatus = .disconnected
        
        connect(using: .authMessage)
    }
    
    private func sendAuthMessageIfNeeded() async throws {
        guard authMode == .authMessage else { return }
        guard let token = authTokenForSession else { return }
        
        let payload: [String: Any] = [
            "type": "auth",
            "token": token
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode auth message")
        }
        
        try await webSocketTask?.send(.string(jsonString))
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
    
    func sendRaw(message: [String: Any]) async throws {
        guard connectionStatus.isConnected else {
            print("[WebSocketService] Cannot send - not connected")
            throw CallError.webSocketDisconnected
        }
        
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode raw message")
        }
        
        if let messageType = message["type"] as? String,
           messageType != "voip:audio",
           messageType != "voip:ai-audio",
           messageType != "voip:sdp-offer",
           messageType != "voip:sdp-answer",
           messageType != "voip:ice-candidate" {
            print("[WebSocketService] Sending: \(jsonString.prefix(200))")
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
            print("[WebSocketService] Connected!")
            self.connectionStatus = .connected
            self.reconnectAttempts = 0
            if self.authMode == .authMessage {
                try? await self.sendAuthMessageIfNeeded()
            }
        }
    }
    
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            print("[WebSocketService] Closed with code: \(closeCode)")
            if self.isSwitchingAuthMode {
                self.isSwitchingAuthMode = false
                return
            }
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
                print("[WebSocketService] Error: \(error)")
                if self.isSwitchingAuthMode {
                    self.isSwitchingAuthMode = false
                    return
                }
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
