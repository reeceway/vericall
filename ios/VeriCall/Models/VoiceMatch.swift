//
//  VoiceMatch.swift
//  VeriCall
//
//  Voice match model for real-time verification
//  Uses exact thresholds from TECH_SPEC.md
//

import Foundation

struct VoiceMatch: Codable {
    let score: Double
    let isMatch: Bool
    let isWarning: Bool
    let confidence: ConfidenceLevel
    let timestamp: Date
    
    enum ConfidenceLevel: String, Codable {
        case high = "high"
        case medium = "medium"
        case low = "low"
        
        var color: String {
            switch self {
            case .high:
                return "success"
            case .medium:
                return "warning"
            case .low:
                return "error"
            }
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decode(Double.self, forKey: .score)
        
        // Use exact thresholds from Constants
        let threshold = Double(Constants.voiceMatchThreshold)
        let warningThreshold = Double(Constants.voiceWarningThreshold)
        
        isMatch = score >= threshold
        isWarning = score < warningThreshold
        
        let confidenceString = try container.decode(String.self, forKey: .confidence)
        confidence = ConfidenceLevel(rawValue: confidenceString) ?? .low
        
        timestamp = Date()
    }
    
    init(score: Double) {
        self.score = score
        
        // Use exact thresholds from Constants (TECH_SPEC.md)
        let threshold = Double(Constants.voiceMatchThreshold)      // 0.75
        let warningThreshold = Double(Constants.voiceWarningThreshold)  // 0.55
        
        self.isMatch = score >= threshold
        self.isWarning = score < warningThreshold
        
        if score >= 0.9 {
            self.confidence = .high
        } else if score >= warningThreshold {
            self.confidence = .medium
        } else {
            self.confidence = .low
        }
        
        self.timestamp = Date()
    }
    
    var percentageString: String {
        return String(format: "%.0f%%", score * 100)
    }
    
    var statusDescription: String {
        if isMatch {
            return "Voice Verified"
        } else if isWarning {
            return "⚠️ Voice Mismatch"
        } else {
            return "Verifying..."
        }
    }
    
    /// Returns the appropriate color based on match status
    var statusColor: String {
        if isMatch {
            return Constants.Colors.verifiedGreen.description
        } else if isWarning {
            return Constants.Colors.error.description
        } else {
            return Constants.Colors.warning.description
        }
    }
}

// MARK: - API Response Model
struct VoiceVerifyResponse: Codable {
    let success: Bool
    let score: Double
    let isMatch: Bool
    let confidence: VoiceMatch.ConfidenceLevel
    
    enum CodingKeys: String, CodingKey {
        case success
        case score = "matchScore"
        case isMatch = "isMatch"
        case confidence
    }
}
