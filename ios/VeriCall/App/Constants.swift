import Foundation
import SwiftUI

enum Constants {
    static let appName = "Vicall"
    static let callKitDisplayName = "Vicall"
    static let requireCompanyAccessCode = true
    static let sendCompanyAccessCodeToBackend = false
    static let companyAccessCodeUserDefaultsKey = "vicall.company_access_code"
    static let pendingAccessContextUserDefaultsKey = "vicall.pending_access_context"
    static let activeOrganizationContextUserDefaultsKey = "vicall.active_organization_context"

    static let apiBaseURL = "https://vericall-api.fly.dev"
    static let wsBaseURL = "wss://vericall-api.fly.dev"
    static let twilioVoiceBaseURL = "https://vericall-twilio-voice.fly.dev"
    static let preferredCallProvider: CallProviderKind = .twilioVoice
    static let enableDeviceDebugEvents = false
    static let companyAccessCodeValidationEndpoint = "/access/validate"
    static let accessGrantRequestOTPEndpoint = "/access/request-otp"
    static let accessGrantVerifyOTPEndpoint = "/access/verify-otp"
    static let accountDeletionPrepareEndpoint = "/account/delete/prepare"
    static let accountDeletionExecuteEndpoint = "/account/delete/execute"
    static let twilioVoiceTokenEndpoint = "/calls/twilio-token"
    static let twilioVoiceDeviceBindingEndpoint = "/calls/device-binding"
    static let twilioConferenceInviteEndpoint = "/calls/conference-invite"
    static let twilioAIAudioLatestEndpoint = "/calls/ai-audio/latest"
    static let twilioVoiceAppToParam = "identity"
    static let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.vicall.app"
    #if DEBUG
    static let twilioVoiceIdentitySuffix = "_dev2"
    #else
    static let twilioVoiceIdentitySuffix = "_prod1"
    #endif

    static var twilioPushEnvironment: String {
        apnsEnvironment == "production" ? "production" : "development"
    }

    static var apnsEnvironment: String {
        #if targetEnvironment(simulator)
        return "development"
        #else
        if let profileValue = provisioningProfileValue(for: "aps-environment")?.lowercased(),
           !profileValue.isEmpty {
            return profileValue
        }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
        #endif
    }

    static func twilioIdentity(forPhoneNumber phoneNumber: String?) -> String? {
        guard let phoneNumber else { return nil }
        let digits = canonicalPhoneDigits(phoneNumber)
        guard !digits.isEmpty else { return nil }
        return "user_\(digits)\(twilioVoiceIdentitySuffix)"
    }

    static func twilioIdentity(forUserId userId: String?) -> String? {
        guard let userId else { return nil }
        if isTwilioClientIdentity(userId) {
            return userId
        }
        let sanitized = userId.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "_"
        }
        let identity = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !identity.isEmpty else { return nil }
        return "user_\(identity)"
    }

    static func isTwilioClientIdentity(_ value: String?) -> Bool {
        guard let value = normalizedTwilioIdentity(value), value.hasPrefix("user_") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isPhoneTwilioIdentity(_ value: String?) -> Bool {
        guard let value, isTwilioClientIdentity(value) else { return false }
        return phoneDigits(fromTwilioIdentity: value) != nil
    }

    static func phoneNumber(fromTwilioIdentity identity: String?) -> String? {
        guard let digits = phoneDigits(fromTwilioIdentity: identity) else { return nil }
        return "+" + digits
    }

    static func phoneDigits(fromTwilioIdentity identity: String?) -> String? {
        guard let identity = normalizedTwilioIdentity(identity), isTwilioClientIdentity(identity) else { return nil }
        var suffix = String(identity.dropFirst("user_".count))
        if suffix.hasSuffix(twilioVoiceIdentitySuffix) {
            suffix.removeLast(twilioVoiceIdentitySuffix.count)
        }
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber) ? suffix : nil
    }

    static func canonicalPhoneDigits(_ phoneNumber: String?) -> String {
        guard let phoneNumber else { return "" }
        let digits = phoneNumber.filter(\.isNumber)
        if digits.count == 10 {
            return "1\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return digits
        }
        return digits
    }

    static func preferredTwilioIdentity() -> String {
        if let phoneIdentity = twilioIdentity(forPhoneNumber: UserDefaults.standard.string(forKey: "userPhoneNumber")) {
            return phoneIdentity
        }
        return "user_vericall_ios"
    }

    static func normalizedTwilioIdentity(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("client:") {
            value.removeFirst("client:".count)
        }
        return value
    }

    private static func provisioningProfileValue(for key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let profile = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
            return nil
        }

        let keyMarker = "<key>\(key)</key>"
        guard let keyRange = profile.range(of: keyMarker) else { return nil }
        let tail = profile[keyRange.upperBound...]
        guard let stringStart = tail.range(of: "<string>"),
              let stringEnd = tail.range(of: "</string>") else {
            return nil
        }

        let value = tail[stringStart.upperBound..<stringEnd.lowerBound]
        return String(value)
    }

    static func normalizedCompanyAccessCode(_ code: String) -> String {
        let dashVariants = CharacterSet(charactersIn: "-_\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

        let normalized = code
            .uppercased()
            .unicodeScalars
            .map { scalar -> String in
                if dashVariants.contains(scalar) {
                    return "-"
                }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return ""
                }
                return String(scalar)
            }
            .joined()

        return normalized
            .unicodeScalars
            .filter { allowed.contains($0) }
            .prefix(64)
            .map(String.init)
            .joined()
    }

    @discardableResult
    static func storeCompanyAccessCode(_ code: String) -> Bool {
        let normalized = normalizedCompanyAccessCode(code)
        guard !normalized.isEmpty else { return false }
        UserDefaults.standard.set(normalized, forKey: companyAccessCodeUserDefaultsKey)
        return true
    }

    static func storedCompanyAccessCode() -> String {
        UserDefaults.standard.string(forKey: companyAccessCodeUserDefaultsKey) ?? ""
    }

    static func clearStoredCompanyAccessCode() {
        UserDefaults.standard.removeObject(forKey: companyAccessCodeUserDefaultsKey)
        clearPendingAccessContext()
    }

    @discardableResult
    static func storePendingAccessContext(_ context: CompanyAccessContext) -> Bool {
        do {
            let data = try JSONEncoder().encode(context)
            UserDefaults.standard.set(data, forKey: pendingAccessContextUserDefaultsKey)
            return true
        } catch {
            return false
        }
    }

    static func storedPendingAccessContext() -> CompanyAccessContext? {
        guard let data = UserDefaults.standard.data(forKey: pendingAccessContextUserDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CompanyAccessContext.self, from: data)
    }

    static func clearPendingAccessContext() {
        UserDefaults.standard.removeObject(forKey: pendingAccessContextUserDefaultsKey)
    }

    @discardableResult
    static func storeActiveOrganizationContext(_ context: CompanyAccessContext) -> Bool {
        var sanitized = context
        sanitized.grantToken = nil
        do {
            let data = try JSONEncoder().encode(sanitized)
            UserDefaults.standard.set(data, forKey: activeOrganizationContextUserDefaultsKey)
            return true
        } catch {
            return false
        }
    }

    static func storedActiveOrganizationContext() -> CompanyAccessContext? {
        guard let data = UserDefaults.standard.data(forKey: activeOrganizationContextUserDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CompanyAccessContext.self, from: data)
    }

    static func clearActiveOrganizationContext() {
        UserDefaults.standard.removeObject(forKey: activeOrganizationContextUserDefaultsKey)
    }

    static func activeVoiceAccountContext() -> CompanyAccessContext? {
        storedActiveOrganizationContext()
    }

    @discardableResult
    static func storeCompanyAccessCode(from url: URL) -> Bool {
        guard let code = companyAccessCode(from: url) else { return false }
        return storeCompanyAccessCode(code)
    }

    static func companyAccessCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryCode = components.queryItems?.first(where: { item in
            ["code", "access_code", "invite"].contains(item.name.lowercased())
        })?.value
        if let queryCode, !normalizedCompanyAccessCode(queryCode).isEmpty {
            return queryCode
        }

        if components.scheme == "vicall", components.host == "join" {
            let pathCode = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalizedCompanyAccessCode(pathCode).isEmpty ? nil : pathCode
        }

        if components.host == "join.vicall.app" {
            let pathCode = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalizedCompanyAccessCode(pathCode).isEmpty ? nil : pathCode
        }

        return nil
    }

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
