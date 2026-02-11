import UIKit
import PushKit
import UserNotifications

/// AppDelegate handles push notifications and PushKit for VoIP
class AppDelegate: NSObject, UIApplicationDelegate {
    
    let pushRegistry = PKPushRegistry(queue: .main)
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        // Register for regular push notifications
        registerForPushNotifications(application)
        
        // Register for VoIP push notifications (wakes app even when terminated)
        registerForVoIPPush()
        
        // Setup notification categories
        Task { @MainActor in
            NotificationService.shared.setupNotificationCategories()
        }
        
        return true
    }
    
    // MARK: - Regular Push Notifications
    
    private func registerForPushNotifications(_ application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            print("[AppDelegate] Push permission granted: \(granted)")
            if let error = error {
                print("[AppDelegate] Push permission error: \(error)")
            }
            
            guard granted else { return }
            
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }
    
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] APNs device token: \(token)")
        
        // Store and send to backend
        Task {
            await sendPushTokenToBackend(token: token, type: "apns")
        }
    }
    
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] Failed to register for APNs: \(error)")
    }
    
    // Handle push notification received while app is running
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[AppDelegate] Received remote notification: \(userInfo)")
        
        // Handle call verification push
        if let type = userInfo["type"] as? String, type == "call_verification" {
            handleCallVerificationPush(userInfo)
        }
        
        completionHandler(.newData)
    }
    
    // MARK: - VoIP Push (PushKit)
    
    private func registerForVoIPPush() {
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }
    
    // MARK: - Handle Push Payloads
    
    private func handleCallVerificationPush(_ userInfo: [AnyHashable: Any]) {
        guard let callerPhone = userInfo["caller_phone"] as? String else {
            return
        }
        
        let callerName = userInfo["caller_name"] as? String ?? callerPhone
        let callerId = userInfo["caller_id"] as? String ?? callerPhone
        let isVerified = userInfo["is_verified"] as? Bool ?? false
        let hasVoice = userInfo["has_voice_thumbprint"] as? Bool ?? false
        
        // Parse thumbprint from push payload
        var voiceThumbprint: [Float]? = nil
        if let thumbprintArray = userInfo["voice_thumbprint"] as? [Double] {
            voiceThumbprint = thumbprintArray.map { Float($0) }
        } else if let thumbprintString = userInfo["voice_thumbprint"] as? String,
                  let data = thumbprintString.data(using: .utf8),
                  let array = try? JSONDecoder().decode([Float].self, from: data) {
            voiceThumbprint = array
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
    
    // MARK: - Send Token to Backend
    
    private func sendPushTokenToBackend(token: String, type: String) async {
        guard let authToken = UserDefaults.standard.string(forKey: "authToken") else {
            print("[AppDelegate] No auth token, will register push token after login")
            // Store for later
            UserDefaults.standard.set(token, forKey: "pendingPushToken_\(type)")
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
                print("[AppDelegate] Push token registered: \(httpResponse.statusCode)")
            }
        } catch {
            print("[AppDelegate] Failed to register push token: \(error)")
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension AppDelegate: PKPushRegistryDelegate {
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] VoIP push token: \(token)")
        
        // Store and send to backend
        Task {
            await sendPushTokenToBackend(token: token, type: "voip")
        }
    }
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        print("[AppDelegate] VoIP push received: \(payload.dictionaryPayload)")
        
        // VoIP push wakes the app - handle call verification
        let userInfo = payload.dictionaryPayload
        
        if let pushType = userInfo["type"] as? String {
            switch pushType {
            case "call_verification", "native_call_handshake":
                handleCallVerificationPush(userInfo)
                
            case "outgoing_call_request":
                // Someone is calling a VeriCall user - we need to send our handshake
                if let targetPhone = userInfo["target_phone"] as? String {
                    Task { @MainActor in
                        // Trigger outgoing handshake through NativeCallObserver
                        await NativeCallObserver.shared.triggerOutgoingHandshake(to: targetPhone)
                    }
                }
                
            default:
                break
            }
        }
        
        completion()
    }
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        print("[AppDelegate] VoIP push token invalidated")
    }
}
