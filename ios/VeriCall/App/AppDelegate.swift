import UIKit
import PushKit
import UserNotifications

/// AppDelegate handles push notifications
/// 
/// Currently using: Firebase Cloud Messaging (FCM) - FREE
/// To switch to direct APNs (requires $99 Apple Developer):
///   1. Uncomment the VoIP/PushKit code below
///   2. Rename backend push_apns.py to push.py
///   3. Configure APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_CONTENT secrets on Fly.io
class AppDelegate: NSObject, UIApplicationDelegate {
    
    // PushKit registry (kept for easy APNs switchback)
    let pushRegistry = PKPushRegistry(queue: .main)
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        print("[AppDelegate] App launched")
        
        // Register for push notifications (FCM uses APNs token)
        registerForPushNotifications(application)
        
        // OPTION: VoIP Push (uncomment to use APNs directly - requires $99 membership)
        // registerForVoIPPush()
        
        // Setup notification categories and request permission
        Task { @MainActor in
            NotificationService.shared.setupNotificationCategories()
            let granted = await NotificationService.shared.requestPermission()
            print("[AppDelegate] Notification permission granted: \(granted)")
            
            // Initialize NativeCallObserver to monitor calls
            _ = NativeCallObserver.shared
            print("[AppDelegate] NativeCallObserver initialized")
            
            // NOTE: WebSocket connection happens in AuthService.checkExistingAuth()
            // after we confirm user has valid auth token
        }
        
        return true
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("[AppDelegate] App became active")
        
        // Reconnect WebSocket when app becomes active (only if user has auth token)
        Task { @MainActor in
            if UserDefaults.standard.string(forKey: "authToken") != nil {
                if !WebSocketService.shared.connectionStatus.isConnected {
                    print("[AppDelegate] Reconnecting WebSocket...")
                    WebSocketService.shared.connect()
                }
                
                // Send any pending FCM token
                await FirebasePushService.shared.sendPendingToken()
            }
        }
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        print("[AppDelegate] App will resign active")
        // Keep WebSocket connected for background notifications
    }
    
    // MARK: - Push Notifications (FCM via APNs token)
    
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
        
        // Send to FirebasePushService (which sends to backend)
        Task { @MainActor in
            FirebasePushService.shared.handleAPNsToken(deviceToken)
        }
    }
    
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] Failed to register for APNs: \(error)")
    }
    
    // MARK: - Handle Remote Notifications (FCM)
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[AppDelegate] Received remote notification: \(userInfo)")
        
        // Handle through Firebase service
        Task { @MainActor in
            FirebasePushService.shared.handlePushNotification(userInfo)
        }
        
        completionHandler(.newData)
    }
    
    // MARK: - VoIP Push (PushKit) - COMMENTED OUT FOR FCM
    // Uncomment to use direct APNs instead of FCM
    /*
    private func registerForVoIPPush() {
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }
    */
}

// MARK: - PKPushRegistryDelegate (VoIP Push)
// COMMENTED OUT - Using FCM instead. Uncomment to use direct APNs.
/*
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
                // handleCallVerificationPush(userInfo)
                FirebasePushService.shared.handlePushNotification(userInfo)
                
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
    
    private func sendPushTokenToBackend(token: String, type: String) async {
        guard let authToken = UserDefaults.standard.string(forKey: "authToken") else {
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
*/
