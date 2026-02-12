import Foundation

// MARK: - Call Model
struct Call: Identifiable, Codable, Equatable {
    let id: String
    let callerId: String
    let callerName: String
    let recipientId: String
    let recipientName: String
    let direction: CallDirection
    var state: CallState
    var startedAt: Date?
    var endedAt: Date?
    var isVerified: Bool
    
    var duration: TimeInterval {
        guard let startedAt = startedAt else { return 0 }
        let endDate = endedAt ?? Date()
        return endDate.timeIntervalSince(startedAt)
    }
    
    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Call State
enum CallState: String, Codable, CaseIterable {
    case idle = "idle"
    case dialing = "dialing"
    case ringing = "ringing"
    case connecting = "connecting"
    case connected = "connected"
    case held = "held"
    case ended = "ended"
    case failed = "failed"
    case declined = "declined"
    case missed = "missed"
    
    var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .dialing: return "Dialing..."
        case .ringing: return "Ringing..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .held: return "On Hold"
        case .ended: return "Ended"
        case .failed: return "Failed"
        case .declined: return "Declined"
        case .missed: return "Missed"
        }
    }
}

// MARK: - Call Direction
enum CallDirection: String, Codable, CaseIterable {
    case incoming = "incoming"
    case outgoing = "outgoing"
    
    var displayText: String {
        switch self {
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        }
    }
}

// MARK: - Call Signal Types
enum CallSignalType: String, Codable {
    case initiate = "call.initiate"
    case offer = "call.offer"
    case answer = "call.answer"
    case iceCandidate = "call.ice_candidate"
    case accept = "call.accept"
    case reject = "call.reject"
    case end = "call.end"
    case hold = "call.hold"
    case resume = "call.resume"
    case mute = "call.mute"
    case unmute = "call.unmute"
case heartbeat = "call.heartbeat"
}

// MARK: - Call Signal
struct CallSignal: Codable {
    let type: CallSignalType
    let callId: String
    let fromUserId: String
    let toUserId: String
    let timestamp: Date
    let payload: CallSignalPayload
    let signature: String?
    let voiceThumbprint: [Float]?
}

// MARK: - Call Signal Payload
struct CallSignalPayload: Codable {
    let sdp: String?
    let iceCandidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int32?
    let reason: String?
    let isMuted: Bool?
    let nonce: String?  // For replay attack prevention
    let deviceSignature: String?  // Device authentication signature

    init(
        sdp: String? = nil,
        iceCandidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil,
        reason: String? = nil,
        isMuted: Bool? = nil,
        nonce: String? = nil,
        deviceSignature: String? = nil
    ) {
        self.sdp = sdp
        self.iceCandidate = iceCandidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.reason = reason
        self.isMuted = isMuted
        self.nonce = nonce
        self.deviceSignature = deviceSignature
    }
}

// MARK: - Contact Model
struct Contact: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let phoneNumber: String?
    let email: String?
    var isVerified: Bool
    var avatarUrl: String?
    var lastContactedAt: Date?
    
    var displayName: String {
        name.isEmpty ? (phoneNumber ?? "Unknown") : name
    }
    
    var initials: String {
        let components = name.split(separator: " ")
        if components.count > 1 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
}

// MARK: - Call History Entry
struct CallHistoryEntry: Identifiable, Codable {
    let id: String
    let call: Call
    let timestamp: Date
    var isRead: Bool
}

// MARK: - Connection Status
enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case error(String)
    
    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))..."
        case .error:
            return "Connection Error"
        }
    }
    
    var color: String {
        switch self {
        case .disconnected:
            return "gray"
        case .connecting, .reconnecting:
            return "orange"
        case .connected:
            return "green"
        case .error:
            return "red"
        }
    }
    
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

// MARK: - Call Error
enum CallError: Error, LocalizedError {
    case invalidState
    case networkError(String)
    case signalingError(String)
    case authenticationError
    case userNotFound
    case callRejected
    case callFailed(String)
    case webSocketDisconnected
    case invalidSignature
    
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Invalid call state"
        case .networkError(let message):
            return "Network error: \(message)"
        case .signalingError(let message):
            return "Signaling error: \(message)"
        case .authenticationError:
            return "Authentication failed"
        case .userNotFound:
            return "User not found"
        case .callRejected:
            return "Call was rejected"
        case .callFailed(let message):
            return "Call failed: \(message)"
        case .webSocketDisconnected:
            return "WebSocket disconnected"
        case .invalidSignature:
            return "Invalid call signature"
        }
    }
}
