import Foundation
import Combine

// MARK: - Supporting Types
struct CallerInfo: Codable {
    let id: String
    let displayName: String?
    let verified: Bool?
}

struct ICECandidate: Codable {
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int32?
}

enum WebSocketEvent {
    case connected
    case disconnected
    case authenticated(userId: String)
    case callIncoming(callId: String, caller: CallerInfo)
    case callAnswered(callId: String)
    case callEnded(callId: String)
    case iceCandidate(callId: String, candidate: ICECandidate)
    case sdpOffer(callId: String, sdp: String)
    case sdpAnswer(callId: String, sdp: String)
    case error(message: String)
}

class CallWebSocketService: NSObject, ObservableObject {
    static let shared = CallWebSocketService()
    
    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var currentUserId: String?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let baseURL = Constants.wsBaseURL
    private var cancellables = Set<AnyCancellable>()
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    
    var eventPublisher = PassthroughSubject<WebSocketEvent, Never>()
    
    // MARK: - Connection
    
    func connect() {
        guard let url = URL(string: baseURL) else {
            eventPublisher.send(.error(message: "Invalid WebSocket URL"))
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        
        webSocketTask?.resume()
        receiveMessage()
    }
    
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        isAuthenticated = false
    }
    
    // MARK: - Authentication
    
    func authenticate(token: String) {
        let message: [String: Any] = [
            "type": "authenticate",
            "token": token
        ]
        send(message: message)
    }
    
    // MARK: - Call Signaling (Client → Server)
    
    func sendCallInitiate(recipientId: String, signature: String) {
        let message: [String: Any] = [
            "type": "call:initiate",
            "recipientId": recipientId,
            "signature": signature
        ]
        send(message: message)
    }
    
    func sendCallAnswer(callId: String) {
        let message: [String: Any] = [
            "type": "call:answer",
            "callId": callId
        ]
        send(message: message)
    }
    
    func sendCallEnd(callId: String) {
        let message: [String: Any] = [
            "type": "call:end",
            "callId": callId
        ]
        send(message: message)
    }
    
    func sendICECandidate(callId: String, candidate: ICECandidate) {
        let message: [String: Any] = [
            "type": "call:ice-candidate",
            "callId": callId,
            "candidate": [
                "sdp_mline_index": candidate.sdpMLineIndex as Any,
                "sdp_mid": candidate.sdpMid as Any,
                "candidate": candidate.candidate as Any
            ]
        ]
        send(message: message)
    }
    
    func sendSDPOffer(callId: String, sdp: String) {
        let message: [String: Any] = [
            "type": "call:sdp-offer",
            "callId": callId,
            "sdp": sdp
        ]
        send(message: message)
    }
    
    func sendSDPAnswer(callId: String, sdp: String) {
        let message: [String: Any] = [
            "type": "call:sdp-answer",
            "callId": callId,
            "sdp": sdp
        ]
        send(message: message)
    }
    
    // MARK: - Messaging
    
    private func send(message: [String: Any]) {
        guard isConnected else { return }
        
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        
        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.eventPublisher.send(.error(message: error.localizedDescription))
                }
            }
        }
    }
    
    // MARK: - Receiving (Server → Client)
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue listening
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.isAuthenticated = false
                    self?.eventPublisher.send(.error(message: error.localizedDescription))
                    self?.scheduleReconnect()
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            switch type {
            case "authenticated":
                if let userId = json["userId"] as? String {
                    self?.isAuthenticated = true
                    self?.currentUserId = userId
                    self?.eventPublisher.send(.authenticated(userId: userId))
                }
                
            case "call:incoming":
                if let callId = json["callId"] as? String,
                   let callerData = json["caller"] as? [String: Any],
                   let callerJSON = try? JSONSerialization.data(withJSONObject: callerData),
                   let caller = try? JSONDecoder().decode(CallerInfo.self, from: callerJSON) {
                    self?.eventPublisher.send(.callIncoming(callId: callId, caller: caller))
                }
                
            case "call:answered":
                if let callId = json["callId"] as? String {
                    self?.eventPublisher.send(.callAnswered(callId: callId))
                }
                
            case "call:ended":
                if let callId = json["callId"] as? String {
                    self?.eventPublisher.send(.callEnded(callId: callId))
                }
                
            case "call:ice-candidate":
                if let callId = json["callId"] as? String,
                   let candidateData = json["candidate"] as? [String: Any],
                   let candidateJSON = try? JSONSerialization.data(withJSONObject: candidateData),
                   let candidate = try? JSONDecoder().decode(ICECandidate.self, from: candidateJSON) {
                    self?.eventPublisher.send(.iceCandidate(callId: callId, candidate: candidate))
                }
                
            case "call:sdp-offer":
                if let callId = json["callId"] as? String,
                   let sdp = json["sdp"] as? String {
                    self?.eventPublisher.send(.sdpOffer(callId: callId, sdp: sdp))
                }
                
            case "call:sdp-answer":
                if let callId = json["callId"] as? String,
                   let sdp = json["sdp"] as? String {
                    self?.eventPublisher.send(.sdpAnswer(callId: callId, sdp: sdp))
                }
                
            case "error":
                if let message = json["message"] as? String {
                    self?.eventPublisher.send(.error(message: message))
                }
                
            default:
                break
            }
        }
    }
    
    // MARK: - Reconnection
    
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            eventPublisher.send(.error(message: "Max reconnection attempts reached"))
            return
        }
        
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 2.0, 30.0) // Exponential backoff
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
            self?.reconnectTimer = nil
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension CallWebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.reconnectAttempts = 0
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isAuthenticated = false
            self.scheduleReconnect()
        }
    }
}
