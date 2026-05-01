import Foundation
import UserNotifications
import UIKit

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
        if VideoDemoKind.current() != nil {
            print("[NotificationService] Skipping notification permission prompt in video demo mode")
            return false
        }

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

    func traceCurrentSettings(context: String) async {
        let settings = await notificationCenter.notificationSettings()
        CallDebugReporter.post(
            "notification_settings",
            details: [
                "context": context,
                "authorization": settings.authorizationStatus.debugName,
                "alert_setting": settings.alertSetting.debugName,
                "sound_setting": settings.soundSetting.debugName,
                "badge_setting": settings.badgeSetting.debugName,
                "lock_screen_setting": settings.lockScreenSetting.debugName,
                "notification_center_setting": settings.notificationCenterSetting.debugName,
                "banner_setting": settings.alertStyle.debugName,
                "time_sensitive": settings.timeSensitiveSetting.debugName
            ]
        )
    }
    
    // MARK: - Call Verification Notification
    
    /// Show a notification for incoming call verification status
    func showCallVerificationNotification(
        callerName: String,
        callerId: String,
        isDeviceVerified: Bool,
        hasVoiceThumbprint: Bool = false
    ) async {
        let content = UNMutableNotificationContent()

        if isDeviceVerified {
            // Device verified - caller has Vicall
            content.title = "✓ Device Verified"
            content.body = "\(callerName) is calling - \(Constants.appName) user verified"
            content.sound = .default
            content.categoryIdentifier = "VERIFIED_CALL"
        } else {
            // Unverified caller
            content.title = "⚠️ Unverified Caller"
            content.body = "\(callerName) is calling - Could not verify identity"
            content.sound = .default
            content.categoryIdentifier = "UNVERIFIED_CALL"
            content.interruptionLevel = .active
        }

        // Add caller info to userInfo for handling taps
        content.userInfo = [
            "type": "call_verification",
            "callerId": callerId,
            "callerName": callerName,
            "isVerified": isDeviceVerified
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
    
    /// Remove call verification notification (when call is answered/declined)
    func removeCallNotification(for callerId: String) {
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: ["call_verification_\(callerId)"]
        )
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: ["call_verification_\(callerId)"]
        )
    }

    func showLiveSpoofAlert(
        callId: String,
        severity: LiveSpoofAlertSeverity
    ) async {
        let settings = await notificationCenter.notificationSettings()
        let content = UNMutableNotificationContent()
        content.title = severity.notificationTitle
        content.body = severity.notificationBody(appName: Constants.appName)
        content.sound = .default
        content.interruptionLevel = severity.interruptionLevel
        content.relevanceScore = severity.relevanceScore
        content.threadIdentifier = "live_spoof_alert_\(callId)"
        content.targetContentIdentifier = callId
        content.categoryIdentifier = "LIVE_SPOOF_ALERT"
        content.userInfo = [
            "type": "live_spoof_alert",
            "callId": callId,
            "severity": severity.rawValue
        ]

        let requestIdentifier = "live_spoof_alert_\(severity.rawValue)_\(callId)"
        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: nil
        )

        CallDebugReporter.post(
            "live_spoof_notification_attempt",
            details: [
                "callId": callId,
                "severity": severity.rawValue,
                "requestId": requestIdentifier,
                "app_state": appStateDescription(),
                "title": severity.notificationTitle,
                "authorization": settings.authorizationStatus.debugName,
                "alert_setting": settings.alertSetting.debugName,
                "sound_setting": settings.soundSetting.debugName,
                "badge_setting": settings.badgeSetting.debugName,
                "time_sensitive": settings.timeSensitiveSetting.debugName,
                "interruption": severity.interruptionLevel.debugName,
                "relevance": String(format: "%.2f", severity.relevanceScore)
            ]
        )

        do {
            try await notificationCenter.add(request)
            CallDebugReporter.post(
                "live_spoof_notification_add_success",
                details: [
                    "callId": callId,
                    "severity": severity.rawValue,
                    "requestId": requestIdentifier,
                    "app_state": appStateDescription()
                ]
            )
            print("[NotificationService] Showed live spoof alert \(severity.rawValue) for \(callId)")
        } catch {
            CallDebugReporter.post(
                "live_spoof_notification_add_failed",
                details: [
                    "callId": callId,
                    "severity": severity.rawValue,
                    "requestId": requestIdentifier,
                    "error": String(describing: error),
                    "app_state": appStateDescription()
                ]
            )
            print("[NotificationService] Failed to show live spoof alert: \(error)")
        }
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

        let liveSpoofAlertCategory = UNNotificationCategory(
            identifier: "LIVE_SPOOF_ALERT",
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
            voiceMismatchCategory,
            liveSpoofAlertCategory
        ])
    }

    private func appStateDescription() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

enum LiveSpoofAlertSeverity: String {
    case suspectedSynthetic
    case flaggedSynthetic

    var notificationTitle: String {
        switch self {
        case .suspectedSynthetic:
            return "Likely synthetic voice"
        case .flaggedSynthetic:
            return "Highly likely synthetic voice"
        }
    }

    func notificationBody(appName: String) -> String {
        switch self {
        case .suspectedSynthetic:
            return "Do not trust this voice. \(appName) is detecting likely synthetic audio."
        case .flaggedSynthetic:
            return "Do not trust this voice. \(appName) flagged it as highly likely synthetic."
        }
    }

    var callKitTitle: String {
        notificationTitle
    }

    var buzzCount: Int {
        switch self {
        case .suspectedSynthetic:
            return 1
        case .flaggedSynthetic:
            return 4
        }
    }

    var feedbackType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .suspectedSynthetic:
            return .warning
        case .flaggedSynthetic:
            return .error
        }
    }

    var interruptionLevel: UNNotificationInterruptionLevel {
        .active
    }

    var relevanceScore: Double {
        switch self {
        case .suspectedSynthetic:
            return 0.85
        case .flaggedSynthetic:
            return 1.0
        }
    }
}

private extension UNAuthorizationStatus {
    var debugName: String {
        switch self {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}

private extension UNNotificationSetting {
    var debugName: String {
        switch self {
        case .notSupported: return "not_supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }
}

private extension UNAlertStyle {
    var debugName: String {
        switch self {
        case .none: return "none"
        case .banner: return "banner"
        case .alert: return "alert"
        @unknown default: return "unknown"
        }
    }
}

private extension UNNotificationInterruptionLevel {
    var debugName: String {
        switch self {
        case .passive: return "passive"
        case .active: return "active"
        case .timeSensitive: return "time_sensitive"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        CallDebugReporter.post(
            "notification_will_present_foreground",
            details: [
                "requestId": notification.request.identifier,
                "category": notification.request.content.categoryIdentifier
            ]
        )
        // Show notification even when app is in foreground
        return [.banner, .list, .sound, .badge]
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
        case "live_spoof_alert":
            CallDebugReporter.post(
                "live_spoof_notification_opened",
                details: [
                    "callId": userInfo["callId"] as? String ?? "unknown",
                    "severity": userInfo["severity"] as? String ?? "unknown"
                ]
            )
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
