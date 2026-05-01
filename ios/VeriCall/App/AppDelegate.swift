import UIKit
import PushKit
import UserNotifications

enum CallDebugReporter {
    private static let localTraceKey = "vicall.call_debug_trace"
    private static let maxLocalTraceEvents = 200

    static func post(_ event: String, details: [String: String] = [:]) {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }

        var enrichedDetails = details
        enrichedDetails["device_name"] = UIDevice.current.name
        enrichedDetails["system_version"] = UIDevice.current.systemVersion
        enrichedDetails["app_state"] = appState
        enrichedDetails["timestamp"] = ISO8601DateFormatter().string(from: Date())

        persistLocalTrace(event: event, details: enrichedDetails)

        guard Constants.enableDeviceDebugEvents || UserDefaults.standard.bool(forKey: "vicall.enable_device_debug_events") else {
            return
        }
        guard let url = URL(string: "\(Constants.twilioVoiceBaseURL)/debug/device-event") else {
            return
        }

        let identity = Constants.preferredTwilioIdentity()
        let payload: [String: Any] = [
            "event": event,
            "identity": identity,
            "details": enrichedDetails
        ]

        Task.detached {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                _ = try await URLSession.shared.data(for: request)
            } catch {
                print("[CallDebug] Failed to post \(event): \(error)")
            }
        }
    }

    static func recentLocalTrace() -> [[String: String]] {
        UserDefaults.standard.array(forKey: localTraceKey) as? [[String: String]] ?? []
    }

    private static func persistLocalTrace(event: String, details: [String: String]) {
        var entry = details
        entry["event"] = event

        var trace = recentLocalTrace()
        trace.append(entry)
        if trace.count > maxLocalTraceEvents {
            trace.removeFirst(trace.count - maxLocalTraceEvents)
        }
        UserDefaults.standard.set(trace, forKey: localTraceKey)

        let compactDetails = details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("[CallTrace] \(event) \(compactDetails)")
    }
}

/// AppDelegate owns push registration for:
/// - general app notifications
/// - Twilio VoIP invite delivery via PushKit/APNs
class AppDelegate: NSObject, UIApplicationDelegate {
    
    let pushRegistry = PKPushRegistry(queue: .main)
    private var isScreenshotMode: Bool { AppStoreScreenshotKind.current() != nil }
    private var isVideoDemoMode: Bool { VideoDemoKind.current() != nil }
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        print("[AppDelegate] App launched")
        CallDebugReporter.post("app_launched")

        if isScreenshotMode || isVideoDemoMode {
            Task { @MainActor in
                NotificationService.shared.setupNotificationCategories()
            }
            print("[AppDelegate] Screenshot/video demo mode active — skipping push and Twilio bootstrap")
            return true
        }

        Task { @MainActor in
            NotificationService.shared.setupNotificationCategories()
            await NotificationService.shared.traceCurrentSettings(context: "launch_before_request")
        }
        
        bootstrapCallServices()
        registerForPushNotifications(application)
        registerForVoIPPush()

        Task { @MainActor in
            await registerTwilioIfPossible(context: "app_launch")
        }
        
        return true
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !isScreenshotMode else { return }
        print("[AppDelegate] App became active")
        CallDebugReporter.post("app_became_active")
        
        Task { @MainActor in
            if UserDefaults.standard.string(forKey: "authToken") != nil {
                if !WebSocketService.shared.connectionStatus.isConnected {
                    print("[AppDelegate] Reconnecting WebSocket...")
                    WebSocketService.shared.connect()
                }

                await FirebasePushService.shared.sendPendingToken()
                await registerTwilioIfPossible(context: "became_active")
            }
        }
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        print("[AppDelegate] App will resign active")
        CallDebugReporter.post("app_will_resign_active")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        guard !isScreenshotMode else { return }
        print("[AppDelegate] App will enter foreground")
        CallDebugReporter.post("app_will_enter_foreground")

        Task { @MainActor in
            await registerTwilioIfPossible(context: "will_enter_foreground")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        guard !isScreenshotMode else { return }
        print("[AppDelegate] App entered background")
        CallDebugReporter.post("app_entered_background")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("[AppDelegate] App will terminate")
        CallDebugReporter.post("app_will_terminate")
    }
    
    private func registerForPushNotifications(_ application: UIApplication) {
        if VideoDemoKind.current() != nil {
            print("[AppDelegate] Skipping APNs permission prompt in video demo mode")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            print("[AppDelegate] Push permission granted: \(granted)")
            CallDebugReporter.post(
                "notification_permission_request_finished",
                details: [
                    "granted": granted ? "true" : "false",
                    "error": error.map { String(describing: $0) } ?? "none"
                ]
            )
            if let error = error {
                print("[AppDelegate] Push permission error: \(error)")
            }

            Task { @MainActor in
                await NotificationService.shared.traceCurrentSettings(context: "launch_after_request")
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
        UserDefaults.standard.set(deviceToken, forKey: "apnsDeviceTokenData")
        UserDefaults.standard.set(token, forKey: "apnsDeviceTokenHex")
        
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
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[AppDelegate] Received remote notification: \(userInfo)")
        
        Task { @MainActor in
            FirebasePushService.shared.handlePushNotification(userInfo)
        }
        
        completionHandler(.newData)
    }
    
    private func registerForVoIPPush() {
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        CallDebugReporter.post("voip_push_registry_configured")
    }

    @MainActor
    private func bootstrapCallServices() {
        _ = VoIPCallService.shared
        print("[AppDelegate] Twilio/CallKit services bootstrapped")
        CallDebugReporter.post("call_services_bootstrapped")
    }

    @MainActor
    private func registerTwilioIfPossible(context: String = "manual") async {
        guard let authToken = UserDefaults.standard.string(forKey: "authToken"), !authToken.isEmpty else {
            CallDebugReporter.post("twilio_register_skipped", details: ["context": context, "reason": "missing_auth_token"])
            return
        }
        guard let deviceToken = UserDefaults.standard.data(forKey: "voipDeviceTokenData") else {
            CallDebugReporter.post("twilio_register_skipped", details: ["context": context, "reason": "missing_voip_token"])
            return
        }
        let identity = Constants.preferredTwilioIdentity()
        guard isStableTwilioIdentity(identity) else {
            CallDebugReporter.post("twilio_register_skipped", details: ["context": context, "reason": "unstable_identity", "identity": identity])
            return
        }
        let deviceTokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        await syncTwilioVoiceBinding(token: deviceTokenHex, context: context)

        do {
            let response = try await APIService.shared.fetchTwilioVoiceAccessToken(
                clientIdentity: identity,
                accessToken: authToken
            )
#if canImport(TwilioVoice)
            TwilioCallService.shared.registerForIncomingCalls(
                accessToken: response.token,
                deviceToken: deviceToken
            )
#endif
            print("[AppDelegate] Twilio Voice registration refreshed")
            CallDebugReporter.post("twilio_register_requested", details: ["context": context, "identity": response.identity ?? identity])
        } catch {
            print("[AppDelegate] Failed to register Twilio Voice: \(error)")
            CallDebugReporter.post("twilio_register_request_failed", details: ["context": context, "error": String(describing: error)])
        }
    }

    private func isStableTwilioIdentity(_ identity: String) -> Bool {
        Constants.isPhoneTwilioIdentity(identity)
    }
}

// MARK: - PKPushRegistryDelegate (VoIP Push)
extension AppDelegate: PKPushRegistryDelegate {
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] VoIP push token: \(token)")
        CallDebugReporter.post("voip_push_token_updated", details: ["token_suffix": String(token.suffix(8))])
        UserDefaults.standard.set(pushCredentials.token, forKey: "voipDeviceTokenData")
        UserDefaults.standard.set(token, forKey: "voipDeviceTokenHex")
        
        Task {
            await sendPushTokenToBackend(token: token, type: "voip")
            await registerTwilioIfPossible(context: "voip_token_updated")
        }
    }
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // CRITICAL (iOS 13+): this delegate method MUST synchronously call
        // CXProvider.reportNewIncomingCall before returning, otherwise iOS
        // terminates the app and (after a few violations) stops delivering
        // VoIP pushes to this bundle id entirely. We created PKPushRegistry
        // with queue: .main, so we are already on the main thread — use
        // assumeIsolated to call into @MainActor code synchronously instead
        // of bouncing through Task { @MainActor in ... }, which would make
        // the whole chain async and break the contract.
        print("[AppDelegate] Twilio VoIP push received: \(payload.dictionaryPayload)")
        CallDebugReporter.post("voip_push_received")
        MainActor.assumeIsolated {
#if canImport(TwilioVoice)
            TwilioCallService.shared.handleNotification(payload.dictionaryPayload, completion: completion)
#else
            completion()
#endif
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType
    ) {
        // Legacy (pre-iOS 11) variant. Kept for API completeness but the
        // completion-bearing overload above is what iOS actually calls on
        // every supported OS. Still must be synchronous for the same reason.
        print("[AppDelegate] Twilio VoIP push received without completion: \(payload.dictionaryPayload)")
        CallDebugReporter.post("voip_push_received_legacy")
        MainActor.assumeIsolated {
#if canImport(TwilioVoice)
            TwilioCallService.shared.handleNotification(payload.dictionaryPayload)
#endif
        }
    }
    
    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        print("[AppDelegate] VoIP push token invalidated")
        CallDebugReporter.post("voip_push_token_invalidated")
        UserDefaults.standard.removeObject(forKey: "voipDeviceTokenData")
        UserDefaults.standard.removeObject(forKey: "voipDeviceTokenHex")
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

    private func syncTwilioVoiceBinding(token: String, context: String) async {
        guard let baseURL = URL(string: Constants.twilioVoiceBaseURL) else { return }
        let url = baseURL.appendingPathComponent("calls/device-binding")
        let identity = Constants.preferredTwilioIdentity()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "identity": identity,
            "voip_token": token,
            "platform": "ios",
            "context": context
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                CallDebugReporter.post(
                    "twilio_voice_binding_sync",
                    details: [
                        "identity": identity,
                        "context": context,
                        "status": "\(httpResponse.statusCode)",
                        "token_suffix": String(token.suffix(8))
                    ]
                )
            }
        } catch {
            CallDebugReporter.post(
                "twilio_voice_binding_sync_failed",
                details: ["identity": identity, "context": context, "error": String(describing: error)]
            )
        }
    }
}
