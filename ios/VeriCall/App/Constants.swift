import Foundation
import SwiftUI

enum Constants {
    static let apiBaseURL = "https://vericall-api.fly.dev"
    static let wsBaseURL = "wss://vericall-api.fly.dev"

    // Feature flags
    static let enableBiometricAuth = false
    static let demoMode = false

    // Keychain keys
    enum KeychainKeys {
        static let accessToken = "vericall.access_token"
        static let refreshToken = "vericall.refresh_token"
        static let userData = "vericall.user_data"
        static let devicePrivateKey = "vericall.device_private_key"
    }

    // Notifications
    enum Notifications {
        static let callHistoryUpdated = Notification.Name("vericall.call_history_updated")
    }

    // Demo codes
    static let demoVerificationCode = "123456"

    // Colors
    enum Colors {
        static let verifiedGreen = Color.green
        static let error = Color.red
        static let warning = Color.orange
    }
}

// MARK: - Custom Colors
extension Color {
    static let veriBlue = Color(red: 0.1, green: 0.4, blue: 0.95)
    static let veriDark = Color(red: 0.02, green: 0.05, blue: 0.1)
    static let veriLightBlue = Color(red: 0.4, green: 0.7, blue: 1.0)
    static let veriGray = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let veriBackground = Color(red: 0.98, green: 0.98, blue: 1.0)
    static let glassBackground = Color.white.opacity(0.1)
}

// MARK: - Global Button Styles
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
