import Foundation
import Combine

@MainActor
class AuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let keychain = KeychainService.shared
    private let api = APIService.shared
    private let crypto = DeviceCrypto.shared

    // MARK: - Check Existing Auth

    func checkExistingAuth() async {
        do {
            _ = try await keychain.retrieveString(
                service: "VeriCall",
                account: Constants.KeychainKeys.accessToken
            )

            let user = try await keychain.retrieveCodable(
                User.self,
                service: "VeriCall",
                account: Constants.KeychainKeys.userData
            )

            // Validate token hasn't expired by trying to refresh
            do {
                let refreshToken = try await keychain.retrieveString(
                    service: "VeriCall",
                    account: Constants.KeychainKeys.refreshToken
                )
                let response = try await api.refreshToken(refreshToken)
                try await storeAuth(response: response, phoneNumber: user.phoneNumber)
            } catch {
                // Token refresh failed, but we'll let them continue with existing token
            }

            self.currentUser = user
            self.isAuthenticated = true
        } catch {
            // No existing auth found
            self.isAuthenticated = false
            self.currentUser = nil
        }
    }

    // MARK: - Login Flow

    func requestOTP(phoneNumber: String) async throws -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await api.requestOTP(phoneNumber: phoneNumber)
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
            // Generate device keypair
            let publicKey = try await crypto.generateDeviceKeypair()

            // Verify OTP with public key
            let response = try await api.verifyOTP(
                phoneNumber: phoneNumber,
                code: code,
                devicePublicKey: publicKey
            )

            // Store auth data
            try await storeAuth(response: response, phoneNumber: phoneNumber)

            // Create local user from response
            let user = User(id: response.userId ?? "", phoneNumber: phoneNumber)
            self.currentUser = user
            self.isAuthenticated = true

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

        // Clear keychain
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.accessToken)
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.refreshToken)
        try? await keychain.delete(service: "VeriCall", account: Constants.KeychainKeys.userData)

        self.currentUser = nil
        self.isAuthenticated = false
    }

    // MARK: - Private Helpers

    private func storeAuth(response: AuthResponse, phoneNumber: String) async throws {
        try await keychain.saveString(
            response.accessToken,
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        )

        try await keychain.saveString(
            response.refreshToken,
            service: "VeriCall",
            account: Constants.KeychainKeys.refreshToken
        )

        // Store user data locally
        let user = User(id: response.userId ?? "", phoneNumber: phoneNumber)
        try await keychain.saveCodable(
            user,
            service: "VeriCall",
            account: Constants.KeychainKeys.userData
        )
    }
}