import Foundation
import UserNotifications

/// Service for showing local notifications for call verification status
@MainActor
class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private override init() {
        super.init()
        notificationCenter.delegate = self
    }
    
    // MARK: - Permission
    
    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge, .providesAppNotificationSettings]
            )
            return granted
        } catch {
            print("[NotificationService] Permission error: \(error)")
            return false
        }
    }
    
    // MARK: - Call Verification Notification
    
    /// Show a notification for incoming call verification status
    func showCallVerificationNotification(
        callerName: String,
        callerId: String,
        isDeviceVerified: Bool,
        hasVoiceThumbprint: Bool
    ) async {
        let content = UNMutableNotificationContent()
        
        if isDeviceVerified && hasVoiceThumbprint {
            // Fully verified caller
            content.title = "✓ Verified Caller"
            content.body = "\(callerName) is calling - Device & Voice verified"
            content.sound = .default
            content.categoryIdentifier = "VERIFIED_CALL"
        } else if isDeviceVerified {
            // Device verified only
            content.title = "✓ Device Verified"
            content.body = "\(callerName) is calling - Device verified, voice pending"
            content.sound = .default
            content.categoryIdentifier = "PARTIAL_VERIFIED_CALL"
        } else {
            // Unverified caller
            content.title = "⚠️ Unverified Caller"
            content.body = "\(callerName) is calling - Could not verify identity"
            content.sound = UNNotificationSound.defaultCritical
            content.categoryIdentifier = "UNVERIFIED_CALL"
            content.interruptionLevel = .critical
        }
        
        // Add caller info to userInfo for handling taps
        content.userInfo = [
            "type": "call_verification",
            "callerId": callerId,
            "callerName": callerName,
            "isVerified": isDeviceVerified,
            "hasVoiceThumbprint": hasVoiceThumbprint
        ]
        
        // Create request with immediate delivery
        let request = UNNotificationRequest(
            identifier: "call_verification_\(callerId)",
            content: content,
            trigger: nil // Deliver immediately
        )
        
        do {
            try await notificationCenter.add(request)
            print("[NotificationService] Showed verification notification for \(callerName)")
        } catch {
            print("[NotificationService] Failed to show notification: \(error)")
        }
    }
    
    /// Show real-time voice match update notification during a call
    func showVoiceMatchNotification(
        callerName: String,
        matchPercentage: Double,
        callId: String
    ) async {
        let content = UNMutableNotificationContent()
        
        // matchPercentage comes in as 0-100 from NativeCallObserver
        let pct = Int(matchPercentage)

        if matchPercentage >= 75 {
            // Good voice match
            content.title = "Voice Verified"
            content.body = "\(callerName)'s voice matches - \(pct)% confidence"
            content.categoryIdentifier = "VOICE_VERIFIED"
        } else if matchPercentage >= 55 {
            // Uncertain match
            content.title = "Voice Uncertain"
            content.body = "\(callerName)'s voice partially matches - \(pct)%"
            content.categoryIdentifier = "VOICE_UNCERTAIN"
        } else {
            // Voice mismatch - WARNING
            content.title = "VOICE MISMATCH"
            content.body = "Voice does NOT match \(callerName)'s profile - \(pct)%"
            content.sound = UNNotificationSound.defaultCritical
            content.categoryIdentifier = "VOICE_MISMATCH"
            content.interruptionLevel = .critical
        }
        
        content.userInfo = [
            "type": "voice_match",
            "callId": callId,
            "callerName": callerName,
            "matchPercentage": matchPercentage
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_match_\(callId)",
            content: content,
            trigger: nil
        )
        
        do {
            try await notificationCenter.add(request)
        } catch {
            print("[NotificationService] Failed to show voice match notification: \(error)")
        }
    }
    
    /// Remove call verification notification (when call is answered/declined)
    func removeCallNotification(for callerId: String) {
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: ["call_verification_\(callerId)"]
        )
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: ["call_verification_\(callerId)"]
        )
    }
    
    /// Remove voice match notification
    func removeVoiceMatchNotification(for callId: String) {
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: ["voice_match_\(callId)"]
        )
    }
    
    // MARK: - Setup Notification Categories
    
    func setupNotificationCategories() {
        // Verified call actions
        let answerAction = UNNotificationAction(
            identifier: "ANSWER_CALL",
            title: "Answer",
            options: [.foreground]
        )
        
        let declineAction = UNNotificationAction(
            identifier: "DECLINE_CALL",
            title: "Decline",
            options: [.destructive]
        )
        
        // Categories
        let verifiedCategory = UNNotificationCategory(
            identifier: "VERIFIED_CALL",
            actions: [answerAction, declineAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        let partialCategory = UNNotificationCategory(
            identifier: "PARTIAL_VERIFIED_CALL",
            actions: [answerAction, declineAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        let unverifiedCategory = UNNotificationCategory(
            identifier: "UNVERIFIED_CALL",
            actions: [answerAction, declineAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        let voiceVerifiedCategory = UNNotificationCategory(
            identifier: "VOICE_VERIFIED",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        let voiceUncertainCategory = UNNotificationCategory(
            identifier: "VOICE_UNCERTAIN",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        let voiceMismatchCategory = UNNotificationCategory(
            identifier: "VOICE_MISMATCH",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        notificationCenter.setNotificationCategories([
            verifiedCategory,
            partialCategory,
            unverifiedCategory,
            voiceVerifiedCategory,
            voiceUncertainCategory,
            voiceMismatchCategory
        ])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show notification even when app is in foreground
        return [.banner, .sound, .badge]
    }
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        
        guard let type = userInfo["type"] as? String else { return }
        
        switch type {
        case "call_verification":
            await handleCallNotificationResponse(response, userInfo: userInfo)
        case "voice_match":
            // Voice match notifications don't have actions
            break
        default:
            break
        }
    }
    
    @MainActor
    private func handleCallNotificationResponse(
        _ response: UNNotificationResponse,
        userInfo: [AnyHashable: Any]
    ) {
        guard let callerId = userInfo["callerId"] as? String else { return }
        
        switch response.actionIdentifier {
        case "ANSWER_CALL":
            // Answer the call - CallManager handles this through CallKit
            print("[NotificationService] User tapped Answer for caller: \(callerId)")
            
        case "DECLINE_CALL":
            // Decline the call
            print("[NotificationService] User tapped Decline for caller: \(callerId)")
            
        case UNNotificationDefaultActionIdentifier:
            // User tapped on the notification body - open app
            print("[NotificationService] Notification tapped for caller: \(callerId)")
            
        default:
            break
        }
    }
}
