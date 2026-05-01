import Foundation
import Combine
import UIKit
import Security

@MainActor
class AuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var accountDeletionNotice: String?

    private let keychain = KeychainService.shared
    private let api = APIService.shared
    private let crypto = DeviceCrypto.shared

    // MARK: - Check Existing Auth

    func checkExistingAuth() async {
        do {
            let accessToken = try await keychain.retrieveString(
                service: "VeriCall",
                account: Constants.KeychainKeys.accessToken
            )
            
            // Also store in UserDefaults for WebSocket access
            UserDefaults.standard.set(accessToken, forKey: "authToken")

            let user = try await keychain.retrieveCodable(
                User.self,
                service: "VeriCall",
                account: Constants.KeychainKeys.userData
            )

            self.currentUser = user
            self.isAuthenticated = true
            self.accountDeletionNotice = nil

            // Restore userId in UserDefaults (needed for voice enrollment)
            if !user.id.isEmpty {
                UserDefaults.standard.set(user.id, forKey: "userId")
            }
            UserDefaults.standard.set(user.phoneNumber, forKey: "userPhoneNumber")

            // Connect WebSocket after auth check succeeds
            WebSocketService.shared.connect()
            AIAnalysisService.shared.warmUpModels()
            refreshExistingSessionInBackground(existingAccessToken: accessToken, phoneNumber: user.phoneNumber)
        } catch {
            // No existing auth found
            self.isAuthenticated = false
            self.currentUser = nil
        }
    }

    // MARK: - Login Flow

    func validateCompanyAccessCode(phoneNumber: String? = nil, code: String) async throws -> AccessCodeValidationResponse {
        let normalizedCode = Constants.normalizedCompanyAccessCode(code)
        guard !normalizedCode.isEmpty else {
            Constants.clearStoredCompanyAccessCode()
            throw APIError.httpError(403, "Company access code is required")
        }

        do {
            let validation = try await api.validateCompanyAccessCode(normalizedCode, phoneNumber: phoneNumber)
            guard validation.valid else {
                Constants.clearStoredCompanyAccessCode()
                throw APIError.httpError(403, validation.message ?? "Invalid company access code")
            }

            Constants.storeCompanyAccessCode(normalizedCode)
            if let context = validation.accessContext {
                Constants.storePendingAccessContext(context)
            } else {
                Constants.clearPendingAccessContext()
            }
            return validation
        } catch let apiError as APIError {
            if case .httpError(403, _) = apiError {
                Constants.clearStoredCompanyAccessCode()
            }
            throw apiError
        }
    }

    func requestOTP(phoneNumber: String, companyAccessCode: String? = nil) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            var accessGrantToken: String?
            var normalizedCompanyCode: String?

            if Constants.requireCompanyAccessCode {
                let normalizedCode = Constants.normalizedCompanyAccessCode(companyAccessCode ?? Constants.storedCompanyAccessCode())
                guard !normalizedCode.isEmpty else {
                    Constants.clearStoredCompanyAccessCode()
                    throw APIError.httpError(403, "Company access code is required")
                }
                normalizedCompanyCode = normalizedCode
                let pendingContext = try await refreshPendingAccessContext(
                    phoneNumber: phoneNumber,
                    companyAccessCode: normalizedCode
                )
                accessGrantToken = pendingContext?.grantToken
            }

            _ = try await api.requestOTP(
                phoneNumber: phoneNumber,
                companyAccessCode: Constants.sendCompanyAccessCodeToBackend ? normalizedCompanyCode : nil,
                accessGrantToken: accessGrantToken
            )
            prepareDeviceKeyForOTPVerification()
            return true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func verifyOTP(phoneNumber: String, code: String) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            let publicKey = try await preparedDevicePublicKey()

            var pendingAccessContext = Constants.storedPendingAccessContext()
            let response: AuthResponse
            do {
                response = try await api.verifyOTP(
                    phoneNumber: phoneNumber,
                    code: code,
                    devicePublicKey: publicKey,
                    accessGrantToken: pendingAccessContext?.grantToken
                )
            } catch let apiError as APIError where shouldRetryExpiredGrant(apiError) {
                let normalizedCode = Constants.normalizedCompanyAccessCode(Constants.storedCompanyAccessCode())
                guard !normalizedCode.isEmpty else {
                    throw apiError
                }
                pendingAccessContext = try await refreshPendingAccessContext(
                    phoneNumber: phoneNumber,
                    companyAccessCode: normalizedCode
                )
                response = try await api.verifyOTP(
                    phoneNumber: phoneNumber,
                    code: code,
                    devicePublicKey: publicKey,
                    accessGrantToken: pendingAccessContext?.grantToken
                )
            }

            // Store auth data
            try await storeAuth(response: response, phoneNumber: phoneNumber)
            if let pendingAccessContext {
                Constants.storeActiveOrganizationContext(pendingAccessContext)
                Constants.clearPendingAccessContext()
            }

            // Create local user from response
            let user = User(id: response.userId ?? "", phoneNumber: phoneNumber)
            self.currentUser = user
            self.isAuthenticated = true
            self.accountDeletionNotice = nil
            
            // Connect WebSocket with fresh token
            WebSocketService.shared.disconnect()  // Disconnect old connection if any
            WebSocketService.shared.connect()     // Connect with new token
            primePostVerificationServices(accessToken: response.accessToken)

            return true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Profile Setup

    func updateProfile(displayName: String) async throws {
        isLoading = true
        defer { isLoading = false }

        guard let token = try? await keychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        ) else {
            throw APIError.unauthorized
        }

        do {
            let user = try await api.updateProfile(displayName: displayName, accessToken: token)
            self.currentUser = user

            // Update stored user data
            try await keychain.saveCodable(
                user,
                service: "VeriCall",
                account: Constants.KeychainKeys.userData
            )
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Logout

    func logout() async {
        isLoading = true
        defer { isLoading = false }

        await clearLocalAuthState(user: currentUser)
        accountDeletionNotice = nil
        self.currentUser = nil
        self.isAuthenticated = false
    }

    // MARK: - Account Deletion

    func deleteAccount() async throws {
        isLoading = true
        defer { isLoading = false }

        guard let user = currentUser else {
            throw APIError.unauthorized
        }
        let accessToken = try await keychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        )

        do {
            let preparation = try await api.prepareAccountDeletion(
                phoneNumber: user.phoneNumber,
                userId: user.id.isEmpty ? nil : user.id,
                identity: Constants.preferredTwilioIdentity(),
                accessToken: accessToken
            )
            let deletionToken = preparation.deletionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let deletionToken, !deletionToken.isEmpty {
                _ = try await api.executeAccountDeletion(
                    deletionToken: deletionToken
                )
                await clearLocalAuthState(user: user)
                accountDeletionNotice = preparation.message ?? "Vicall account deleted. Your device data and active access were removed. Your MSP can reprovision you later if needed."
                self.currentUser = nil
                self.isAuthenticated = false
                return
            }

            if let manageURL = preparation.manageURL, let url = URL(string: manageURL) {
                await UIApplication.shared.open(url)
                await clearLocalAuthState(user: user)
                accountDeletionNotice = "Finish deleting your Vicall account in the secure browser page that just opened. If you leave that page before confirming, you can sign back in and try again."
                self.currentUser = nil
                self.isAuthenticated = false
                return
            }

            throw APIError.invalidResponse
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Private Helpers

    private func storeAuth(response: AuthResponse, phoneNumber: String) async throws {
        try await keychain.saveString(
            response.accessToken,
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )

        try await keychain.saveString(
            response.refreshToken,
            service: "VeriCall",
            account: Constants.KeychainKeys.refreshToken,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        
        // Also store in UserDefaults for WebSocket access
        UserDefaults.standard.set(response.accessToken, forKey: "authToken")

        // Store userId for voice enrollment keying
        if let userId = response.userId, !userId.isEmpty {
            UserDefaults.standard.set(userId, forKey: "userId")
        }
        UserDefaults.standard.set(phoneNumber, forKey: "userPhoneNumber")

        // Store user data locally
        let user = User(id: response.userId ?? "", phoneNumber: phoneNumber)
        try await keychain.saveCodable(
            user,
            service: "VeriCall",
            account: Constants.KeychainKeys.userData
        )
    }

    private func refreshPendingAccessContext(
        phoneNumber: String,
        companyAccessCode: String?
    ) async throws -> CompanyAccessContext? {
        let normalizedCode = Constants.normalizedCompanyAccessCode(companyAccessCode ?? Constants.storedCompanyAccessCode())
        guard !normalizedCode.isEmpty else {
            Constants.clearStoredCompanyAccessCode()
            throw APIError.httpError(403, "Company access code is required")
        }

        let validation = try await validateCompanyAccessCode(
            phoneNumber: phoneNumber,
            code: normalizedCode
        )
        return validation.accessContext ?? Constants.storedPendingAccessContext()
    }

    private func prepareDeviceKeyForOTPVerification() {
        let crypto = self.crypto
        Task.detached(priority: .utility) {
            do {
                _ = try await crypto.generateDeviceKeypair()
                print("[AuthService] Prepared device key while OTP was in flight")
            } catch {
                print("[AuthService] Device key pre-generation failed: \(error)")
            }
        }
    }

    private func preparedDevicePublicKey() async throws -> String {
        if await crypto.hasDeviceKey(), let publicKey = try? await crypto.getPublicKey() {
            return publicKey
        }
        return try await crypto.generateDeviceKeypair()
    }

    private func primePostVerificationServices(accessToken: String) {
        AIAnalysisService.shared.warmUpModels()
        Task { @MainActor [weak self] in
            await self?.refreshTwilioRegistrationIfPossible(accessToken: accessToken)
        }
    }

    private func refreshExistingSessionInBackground(existingAccessToken: String, phoneNumber: String) {
        Task { [weak self] in
            guard let self else { return }

            let tokenForTwilio: String
            do {
                let refreshToken = try await keychain.retrieveString(
                    service: "VeriCall",
                    account: Constants.KeychainKeys.refreshToken
                )
                let response = try await api.refreshToken(refreshToken)
                try await storeAuth(response: response, phoneNumber: phoneNumber)
                tokenForTwilio = response.accessToken
            } catch {
                tokenForTwilio = existingAccessToken
            }

            await refreshTwilioRegistrationIfPossible(accessToken: tokenForTwilio)
        }
    }

    private func shouldRetryExpiredGrant(_ error: APIError) -> Bool {
        guard case .httpError(403, let message) = error else {
            return false
        }

        let normalized = message.lowercased()
        return normalized.contains("invalid or expired access grant")
            || normalized.contains("invalid or expired grant")
    }

    private func refreshTwilioRegistrationIfPossible(accessToken: String) async {
        do {
            let identity = Constants.preferredTwilioIdentity()
            let response = try await api.fetchTwilioVoiceAccessToken(
                clientIdentity: identity,
                accessToken: accessToken
            )

            guard let deviceToken = UserDefaults.standard.data(forKey: "voipDeviceTokenData") else {
                print("[AuthService] Warmed Twilio token; no VoIP device token yet for registration")
                return
            }

            let deviceTokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
            do {
                try await api.syncTwilioVoiceBinding(
                    identity: identity,
                    voipToken: deviceTokenHex,
                    context: "post_auth"
                )
            } catch {
                print("[AuthService] Failed to sync Twilio Voice binding: \(error)")
            }
#if canImport(TwilioVoice)
            TwilioCallService.shared.registerForIncomingCalls(
                accessToken: response.token,
                deviceToken: deviceToken
            )
#endif
            print("[AuthService] Refreshed Twilio Voice registration for \(response.identity ?? identity)")
        } catch {
            print("[AuthService] Failed to refresh Twilio Voice registration: \(error)")
        }
    }

    private func clearLocalAuthState(user: User?) async {
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.accessToken)
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.refreshToken)
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.userData)
        try? await DeviceCrypto.shared.deleteDeviceKey()

        if let userId = user?.id, !userId.isEmpty {
            VoiceEnrollmentService.shared.deleteSignature(for: userId)
        }

        if let phoneNumber = user?.phoneNumber, !phoneNumber.isEmpty {
            VoiceEnrollmentService.shared.deleteSignature(for: phoneNumber)
        }

        AudioRecorder().deleteAllRecordings()
        await StorageService.shared.clearAllLocalData()

        let defaults = UserDefaults.standard
        [
            "authToken",
            "userId",
            "authUserId",
            "userPhoneNumber",
            "contactId",
            "voipDeviceTokenData",
            "voipDeviceTokenHex",
            "pendingPushToken_apns",
            "pendingPushToken_voip",
        ].forEach { defaults.removeObject(forKey: $0) }

        Constants.clearStoredCompanyAccessCode()
        Constants.clearPendingAccessContext()
        Constants.clearActiveOrganizationContext()
        await api.clearTwilioVoiceTokenCache()

        WebSocketService.shared.disconnect()
#if canImport(TwilioVoice)
        TwilioCallService.shared.disconnect()
#endif
    }
}
