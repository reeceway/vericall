import SwiftUI

@main
struct VeriCallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService()
    private let screenshotKind = AppStoreScreenshotKind.current()
    private let videoDemoKind = VideoDemoKind.current()

    var body: some Scene {
        WindowGroup {
            Group {
                if let screenshotKind {
                    AppStoreScreenshotView(kind: screenshotKind)
                } else if let videoDemoKind {
                    VideoDemoView(kind: videoDemoKind)
                        .environmentObject(authService)
                } else {
                    RootView()
                        .environmentObject(authService)
                        .onAppear {
                            registerPendingPushTokens()
                        }
                        .onOpenURL { url in
                            if Constants.storeCompanyAccessCode(from: url) {
                                print("[VeriCallApp] Stored company access code from invite URL")
                            }
                        }
                    }
            }
        }
    }
    
    private func registerPendingPushTokens() {
        // If we have pending tokens from before login, register them now
        if authService.isAuthenticated {
            if let apnsToken = UserDefaults.standard.string(forKey: "pendingPushToken_apns") {
                Task {
                    await registerPushToken(token: apnsToken, type: "apns")
                    UserDefaults.standard.removeObject(forKey: "pendingPushToken_apns")
                }
            }
            if let voipToken = UserDefaults.standard.string(forKey: "pendingPushToken_voip") {
                Task {
                    await registerPushToken(token: voipToken, type: "voip")
                    UserDefaults.standard.removeObject(forKey: "pendingPushToken_voip")
                }
            }
        }
    }
    
    private func registerPushToken(token: String, type: String) async {
        guard let authToken = UserDefaults.standard.string(forKey: "authToken"),
              let baseURL = URL(string: Constants.apiBaseURL) else { return }
        
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
            let (_, _) = try await URLSession.shared.data(for: request)
        } catch {
            print("[VeriCallApp] Failed to register push token: \(error)")
        }
    }
}
