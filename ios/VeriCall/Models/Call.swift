//
//  Call.swift
//  VeriCall
//
//  Call model for managing call state
//

import Foundation

enum CallStatus: String, Codable {
    case pending = "pending"
    case connecting = "connecting"
    case active = "active"
    case ended = "ended"
    case failed = "failed"
}

enum CallDirection: String, Codable {
    case incoming = "incoming"
    case outgoing = "outgoing"
}

struct Call: Identifiable, Codable {
    let id: String
    let callerId: String
    let callerPhoneNumber: String
    let callerName: String?
    let recipientId: String
    let recipientPhoneNumber: String
    let direction: CallDirection
    var status: CallStatus
    var startedAt: Date?
    var endedAt: Date?
    var isDeviceVerified: Bool
    var voiceMatchScores: [Double]
    
    enum CodingKeys: String, CodingKey {
        case id = "call_id"
        case callerId = "caller_id"
        case callerPhoneNumber = "caller_phone"
        case callerName = "caller_name"
        case recipientId = "recipient_id"
        case recipientPhoneNumber = "recipient_phone"
        case direction
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case isDeviceVerified = "caller_verified"
        case voiceMatchScores = "voice_match_scores"
    }
    
    var duration: TimeInterval {
        guard let start = startedAt else { return 0 }
        let end = endedAt ?? Date()
        return end.timeIntervalSince(start)
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var currentVoiceMatchScore: Double? {
        return voiceMatchScores.last
    }
    
    var averageVoiceMatchScore: Double {
        guard !voiceMatchScores.isEmpty else { return 0 }
        let sum = voiceMatchScores.reduce(0, +)
        return sum / Double(voiceMatchScores.count)
    }
}

// MARK: - Call History Entry
struct CallHistoryEntry: Identifiable, Codable {
    let id: String
    let callId: String
    let contactName: String?
    let phoneNumber: String
    let direction: CallDirection
    let status: CallStatus
    let timestamp: Date
    let duration: TimeInterval
    let wasVerified: Bool
    let averageVoiceMatch: Double?
    
    var displayName: String {
        return contactName ?? phoneNumber
    }
    
    var formattedTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
