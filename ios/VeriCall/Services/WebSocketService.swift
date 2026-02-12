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
        
        print("[WebSocketService] ✅ Found auth token: \(token.prefix(20))...")
        
        // Use Constants for the WebSocket URL + add /ws path with token as query param
        let wsURLString = Constants.wsBaseURL + "/ws?token=\(token)"
        guard let url = URL(string: wsURLString) else {
            connectionStatus = .error("Invalid WebSocket URL")
            print("[WebSocketService] ❌ Invalid URL")
            return
        }
        
        print("[WebSocketService] 📡 Connecting to: \(Constants.wsBaseURL)/ws")
        
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
            print("[WebSocketService] Received: \(text.prefix(200))")
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
            
            // Route VoIP call signaling messages
            if messageType.hasPrefix("voip:") {
                print("[WebSocketService] VoIP message: \(messageType)")
                Task { @MainActor in
                    VoIPCallService.shared.handleSignalingMessage(json, type: messageType)
                }
                return
            }
            
            if messageType.hasPrefix("native_call:") {
                print("[WebSocketService] Native call message: \(messageType)")
                Task { @MainActor in
                    await handleNativeCallMessage(json: json, type: messageType)
                }
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
    
    @MainActor
    private func handleNativeCallMessage(json: [String: Any], type: String) async {
        let observer = NativeCallObserver.shared
        let notificationService = NotificationService.shared
        
        switch type {
        case "native_call:handshake":
            // Someone is calling us and sent THEIR voiceprint
            // We can now verify THEIR voice during the call
            print("[WebSocketService] ✅ Received HANDSHAKE (caller's voiceprint)")
            if let fromUserId = json["fromUserId"] as? String,
               let phoneNumber = json["phoneNumber"] as? String {
                
                var floatThumbprint: [Float]? = nil
                if let thumbprint = json["voiceThumbprint"] as? [Double] {
                    floatThumbprint = thumbprint.map { Float($0) }
                } else if let thumbprint = json["voiceThumbprint"] as? [NSNumber] {
                    floatThumbprint = thumbprint.map { Float(truncating: $0) }
                }
                
                let displayName = json["displayName"] as? String
                
                print("[WebSocketService] 📞 Call from: \\(displayName ?? phoneNumber)")
                
                // Show notification immediately
                await notificationService.showCallVerificationNotification(
                    callerName: displayName ?? phoneNumber,
                    callerId: fromUserId,
                    isDeviceVerified: true,
                    hasVoiceThumbprint: floatThumbprint != nil
                )
                
                if let thumbprint = floatThumbprint {
                    print("[WebSocketService] ✅ Got \\(thumbprint.count) value voiceprint")
                    await observer.handleReceivedHandshake(
                        fromUserId: fromUserId,
                        displayName: displayName,
                        voiceThumbprint: thumbprint,
                        phoneNumber: phoneNumber
                    )
                } else {
                    print("[WebSocketService] ⚠️ Handshake had no voiceprint")
                }
            }
            
        case "native_call:request_thumbprint":
            print("[WebSocketService] Received thumbprint request")
            if let fromUserId = json["fromUserId"] as? String,
               let phoneNumber = json["phoneNumber"] as? String {
                await observer.handleThumbprintRequest(fromUserId: fromUserId, phoneNumber: phoneNumber)
            }
            
        case "native_call:handshake_response":
            // This is when the other party sends THEIR voiceprint back to us
            // Now we can verify THEIR voice during the call
            print("[WebSocketService] ✅ Received handshake RESPONSE (their voiceprint)")
            if let fromUserId = json["fromUserId"] as? String {
                
                var floatThumbprint: [Float]? = nil
                if let thumbprint = json["voiceThumbprint"] as? [Double] {
                    floatThumbprint = thumbprint.map { Float($0) }
                } else if let thumbprint = json["voiceThumbprint"] as? [NSNumber] {
                    floatThumbprint = thumbprint.map { Float(truncating: $0) }
                }
                
                let displayName = json["displayName"] as? String
                let phoneNumber = json["phoneNumber"] as? String ?? "Unknown"
                
                if let thumbprint = floatThumbprint {
                    print("[WebSocketService] ✅ Got \\(thumbprint.count) value voiceprint from \\(displayName ?? fromUserId)")
                    // Process as incoming handshake - this will start voice verification
                    await observer.handleReceivedHandshake(
                        fromUserId: fromUserId,
                        displayName: displayName,
                        voiceThumbprint: thumbprint,
                        phoneNumber: phoneNumber
                    )
                } else {
                    print("[WebSocketService] ⚠️ Handshake response had no voiceprint")
                }
            }
            
        case "native_call:matched":
            // Matching pool found our call partner - handshakes will be sent separately
            let matchedName = json["matched_name"] as? String ?? "Unknown"
            print("[WebSocketService] Matching pool matched us with \(matchedName)")
            
        case "native_call:waiting":
            // We're in the matching pool waiting for the other party
            print("[WebSocketService] Added to matching pool - waiting for other VeriCall user...")
            
        case "native_call:call_ended":
            // Other party ended the call
            print("[WebSocketService] Other party ended the call")
            
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
    
    func sendRaw(message: [String: Any]) async throws {
        guard connectionStatus.isConnected else {
            print("[WebSocketService] Cannot send - not connected")
            throw CallError.webSocketDisconnected
        }
        
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode raw message")
        }
        
        print("[WebSocketService] Sending: \(jsonString.prefix(200))")
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
