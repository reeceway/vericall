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
    static let veriBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let veriDark = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let veriGray = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let veriBackground = Color(red: 0.98, green: 0.98, blue: 1.0)
}
