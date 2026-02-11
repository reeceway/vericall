import Foundation
import UIKit

/// Firebase Cloud Messaging Service for VeriCall
/// This handles FCM token registration and push notification handling
/// 
/// To switch back to APNs:
/// 1. Rename this file to FirebasePushService_backup.swift
/// 2. Rename PushKitService_apns.swift back to use PushKit
/// 3. Update AppDelegate to use PushKit instead
@MainActor
class FirebasePushService: NSObject, ObservableObject {
    static let shared = FirebasePushService()
    
    @Published var fcmToken: String?
    @Published var isRegistered: Bool = false
    
    private override init() {
        super.init()
    }
    
    // MARK: - Token Management
    
    /// Called when we get the APNs token - we use this to get FCM token
    /// Firebase uses the APNs token to create an FCM token
    func handleAPNsToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[FirebasePush] APNs token received: \(token.prefix(20))...")
        
        // For now, we'll use the APNs token directly as our FCM token
        // When you add the Firebase SDK, this will be replaced with the actual FCM token
        self.fcmToken = token
        
        // Send to backend
        Task {
            await sendTokenToBackend(token: token, type: "fcm")
        }
    }
    
    /// Manually set FCM token (called by Firebase SDK when integrated)
    func setFCMToken(_ token: String) {
        print("[FirebasePush] FCM token set: \(token.prefix(20))...")
        self.fcmToken = token
        
        Task {
            await sendTokenToBackend(token: token, type: "fcm")
        }
    }
    
    // MARK: - Backend Registration
    
    private func sendTokenToBackend(token: String, type: String) async {
        guard let authToken = UserDefaults.standard.string(forKey: "authToken") else {
            print("[FirebasePush] No auth token, saving for later")
            UserDefaults.standard.set(token, forKey: "pendingFCMToken")
            return
        }
        
        guard let baseURL = URL(string: Constants.apiBaseURL) else { return }
        let url = baseURL.appendingPathComponent("devices/push-token")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "push_token": token,
            "token_type": type,
            "platform": "ios"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("[FirebasePush] Token registered: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 {
                    isRegistered = true
                    UserDefaults.standard.removeObject(forKey: "pendingFCMToken")
                }
            }
        } catch {
            print("[FirebasePush] Failed to register token: \(error)")
        }
    }
    
    /// Send any pending token after login
    func sendPendingToken() async {
        if let pendingToken = UserDefaults.standard.string(forKey: "pendingFCMToken") {
            print("[FirebasePush] Sending pending FCM token")
            await sendTokenToBackend(token: pendingToken, type: "fcm")
        }
    }
    
    // MARK: - Handle Push Notifications
    
    /// Handle a push notification payload
    func handlePushNotification(_ userInfo: [AnyHashable: Any]) {
        print("[FirebasePush] Received notification: \(userInfo)")
        
        // Extract type from either root or data dictionary
        let type = userInfo["type"] as? String ?? 
                   (userInfo["data"] as? [String: Any])?["type"] as? String
        
        guard let pushType = type else {
            print("[FirebasePush] No type in notification")
            return
        }
        
        switch pushType {
        case "native_call_handshake", "call_verification":
            handleCallVerificationPush(userInfo)
            
        case "outgoing_call_request":
            handleOutgoingCallRequest(userInfo)
            
        default:
            print("[FirebasePush] Unknown push type: \(pushType)")
        }
    }
    
    // MARK: - Call Handling
    
    private func handleCallVerificationPush(_ userInfo: [AnyHashable: Any]) {
        // Extract from root or data dictionary
        let data = userInfo["data"] as? [String: Any] ?? userInfo as? [String: Any] ?? [:]
        
        guard let callerPhone = data["caller_phone"] as? String ?? userInfo["caller_phone"] as? String else {
            print("[FirebasePush] No caller_phone in push payload")
            return
        }
        
        print("[FirebasePush] Handling call verification from: \(callerPhone)")
        
        let callerName = data["caller_name"] as? String ?? userInfo["caller_name"] as? String ?? callerPhone
        let callerId = data["caller_id"] as? String ?? userInfo["caller_id"] as? String ?? callerPhone
        let isVerified = parseBool(data["is_verified"] ?? userInfo["is_verified"]) ?? false
        let hasVoice = parseBool(data["has_voice_thumbprint"] ?? userInfo["has_voice_thumbprint"]) ?? false
        
        // Parse thumbprint
        var voiceThumbprint: [Float]? = nil
        if let thumbprintString = data["voice_thumbprint"] as? String ?? userInfo["voice_thumbprint"] as? String,
           let thumbprintData = thumbprintString.data(using: .utf8),
           let array = try? JSONDecoder().decode([Float].self, from: thumbprintData) {
            voiceThumbprint = array
        } else if let thumbprintArray = data["voice_thumbprint"] as? [Double] ?? userInfo["voice_thumbprint"] as? [Double] {
            voiceThumbprint = thumbprintArray.map { Float($0) }
        }
        
        // Show notification
        Task { @MainActor in
            await NotificationService.shared.showCallVerificationNotification(
                callerName: callerName,
                callerId: callerPhone,
                isDeviceVerified: isVerified,
                hasVoiceThumbprint: hasVoice
            )
        }
        
        // Wake NativeCallObserver to process handshake
        if let thumbprint = voiceThumbprint {
            Task { @MainActor in
                await NativeCallObserver.shared.handleReceivedHandshake(
                    fromUserId: callerId,
                    displayName: callerName,
                    voiceThumbprint: thumbprint,
                    phoneNumber: callerPhone
                )
            }
        }
    }
    
    private func handleOutgoingCallRequest(_ userInfo: [AnyHashable: Any]) {
        let data = userInfo["data"] as? [String: Any] ?? userInfo as? [String: Any] ?? [:]
        
        guard let targetPhone = data["target_phone"] as? String ?? userInfo["target_phone"] as? String else {
            print("[FirebasePush] No target_phone in push payload")
            return
        }
        
        print("[FirebasePush] Outgoing call request for: \(targetPhone)")
        
        Task { @MainActor in
            await NativeCallObserver.shared.triggerOutgoingHandshake(to: targetPhone)
        }
    }
    
    // MARK: - Helpers
    
    private func parseBool(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            return stringValue.lowercased() == "true"
        }
        if let intValue = value as? Int {
            return intValue != 0
        }
        return nil
    }
}
