import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case decodingError(Error)
    case networkError(Error)
    case unauthorized
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return message.isEmpty ? "Server returned error \(code)" : message
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .unauthorized:
            return "Session expired. Please log in again."
        }
    }
}

actor APIService {
    static let shared = APIService()
    
    private let session: URLSession
    private let baseURL: String
    private var cachedTwilioVoiceToken: CachedTwilioVoiceToken?

    private struct CachedTwilioVoiceToken {
        let key: String
        let response: TwilioVoiceAccessTokenResponse
        let expiresAt: Date
    }
    
    private init() {
        self.baseURL = Constants.apiBaseURL
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Request OTP
    
    func requestOTP(
        phoneNumber: String,
        companyAccessCode: String? = nil,
        accessGrantToken: String? = nil
    ) async throws -> OTPResponse {
        let useGrantProxy = !(accessGrantToken ?? "").isEmpty
        let endpoint = useGrantProxy
            ? "\(Constants.twilioVoiceBaseURL)\(Constants.accessGrantRequestOTPEndpoint)"
            : "\(baseURL)/auth/request-otp"

        let request = OTPRequest(
            phoneNumber: phoneNumber,
            companyAccessCode: companyAccessCode,
            accessGrantToken: accessGrantToken
        )
        let body = try JSONEncoder().encode(request)
        
        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }

    func validateCompanyAccessCode(_ code: String, phoneNumber: String?) async throws -> AccessCodeValidationResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.companyAccessCodeValidationEndpoint)"

        struct AccessCodeValidationRequest: Codable {
            let code: String
            let phoneNumber: String?

            enum CodingKeys: String, CodingKey {
                case code
                case phoneNumber = "phone_number"
            }
        }

        let request = AccessCodeValidationRequest(code: code, phoneNumber: phoneNumber)
        let body = try JSONEncoder().encode(request)

        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }
    
    // MARK: - Verify OTP
    
    func verifyOTP(
        phoneNumber: String,
        code: String,
        devicePublicKey: String?,
        accessGrantToken: String? = nil
    ) async throws -> AuthResponse {
        let useGrantProxy = !(accessGrantToken ?? "").isEmpty
        let endpoint = useGrantProxy
            ? "\(Constants.twilioVoiceBaseURL)\(Constants.accessGrantVerifyOTPEndpoint)"
            : "\(baseURL)/auth/verify-otp"

        let request = OTPVerifyRequest(
            phoneNumber: phoneNumber,
            otp: code,
            publicKey: devicePublicKey,
            accessGrantToken: accessGrantToken
        )
        let body = try JSONEncoder().encode(request)
        
        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }
    
    // MARK: - Refresh Token
    
    func refreshToken(_ refreshToken: String) async throws -> AuthResponse {
        let endpoint = "\(baseURL)/auth/refresh"
        
        struct RefreshRequest: Codable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
            }
        }
        
        let request = RefreshRequest(refreshToken: refreshToken)
        let body = try JSONEncoder().encode(request)
        
        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }
    
    // MARK: - Update Profile
    
    func updateProfile(displayName: String, accessToken: String) async throws -> User {
        let endpoint = "\(baseURL)/users/me"
        
        struct UpdateRequest: Codable {
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
        
        let request = UpdateRequest(displayName: displayName)
        let body = try JSONEncoder().encode(request)
        
        return try await makeRequest(
            endpoint: endpoint,
            method: "PATCH",
            body: body,
            accessToken: accessToken
        )
    }
    
    // MARK: - Sync Contacts

    /// Syncs phone numbers with backend and returns which ones are VeriCall users.
    /// Returns a list of matching phone numbers (normalized).
    func syncContacts(phoneNumbers: [String], accessToken: String) async throws -> [String] {
        let endpoint = "\(baseURL)/contacts/sync"

        struct SyncRequest: Codable {
            let contacts: [String]
        }

        struct SyncedContact: Codable {
            let phoneNumber: String
            let name: String?
            let publicKeyFingerprint: String

            enum CodingKeys: String, CodingKey {
                case phoneNumber = "phone_number"
                case name
                case publicKeyFingerprint = "public_key_fingerprint"
            }
        }

        struct SyncResponse: Codable {
            let contacts: [SyncedContact]
        }

        let request = SyncRequest(contacts: phoneNumbers)
        let body = try JSONEncoder().encode(request)

        let response: SyncResponse = try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            accessToken: accessToken
        )

        return response.contacts.map { $0.phoneNumber }
    }
    
    
    // MARK: - Lookup VeriCall User by Phone Number
    func lookupVeriCallUser(phoneNumber: String, accessToken: String) async throws -> User? {
        let body = try JSONEncoder().encode(["phone_number": phoneNumber])
        
        do {
            let response: UserLookupResponse = try await makeRequest(
                endpoint: baseURL + "/users/lookup",
                method: "POST",
                body: body,
                accessToken: accessToken
            )
            return response.user
        } catch {
            // User not found - not a VeriCall user
            return nil
        }
    }

    // MARK: - Twilio Voice

    func fetchTwilioVoiceAccessToken(clientIdentity: String?, accessToken: String) async throws -> TwilioVoiceAccessTokenResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.twilioVoiceTokenEndpoint)"
        let identity = clientIdentity ?? ""
        let cacheKey = [
            identity,
            Constants.twilioPushEnvironment,
            Constants.appBundleIdentifier
        ].joined(separator: "|")

        if let cached = cachedTwilioVoiceToken,
           cached.key == cacheKey,
           cached.expiresAt > Date() {
            return cached.response
        }

        struct TokenRequest: Codable {
            let identity: String
            let pushEnvironment: String
            let bundleIdentifier: String

            enum CodingKeys: String, CodingKey {
                case identity
                case pushEnvironment = "push_environment"
                case bundleIdentifier = "bundle_identifier"
            }
        }

        let body = try JSONEncoder().encode(
            TokenRequest(
                identity: identity,
                pushEnvironment: Constants.twilioPushEnvironment,
                bundleIdentifier: Constants.appBundleIdentifier
            )
        )

        let response: TwilioVoiceAccessTokenResponse = try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            accessToken: accessToken
        )
        let ttl = max(response.expiresIn ?? 3600, 0)
        if ttl > 120 {
            cachedTwilioVoiceToken = CachedTwilioVoiceToken(
                key: cacheKey,
                response: response,
                expiresAt: Date().addingTimeInterval(TimeInterval(ttl - 90))
            )
        }
        return response
    }

    func syncTwilioVoiceBinding(identity: String, voipToken: String, context: String) async throws {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.twilioVoiceDeviceBindingEndpoint)"

        struct BindingRequest: Codable {
            let identity: String
            let voipToken: String
            let platform: String
            let context: String

            enum CodingKeys: String, CodingKey {
                case identity
                case voipToken = "voip_token"
                case platform
                case context
            }
        }

        struct BindingResponse: Codable {
            let status: String
        }

        let body = try JSONEncoder().encode(
            BindingRequest(
                identity: identity,
                voipToken: voipToken,
                platform: "ios",
                context: context
            )
        )

        let _: BindingResponse = try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }

    func clearTwilioVoiceTokenCache() {
        cachedTwilioVoiceToken = nil
    }

    func inviteTwilioConferenceClient(
        to targetIdentity: String,
        from callerIdentity: String,
        room: String,
        accessToken: String
    ) async throws -> TwilioConferenceInviteResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.twilioConferenceInviteEndpoint)"

        struct InviteRequest: Codable {
            let to: String
            let fromIdentity: String
            let room: String

            enum CodingKeys: String, CodingKey {
                case to
                case fromIdentity = "from_identity"
                case room
            }
        }

        let body = try JSONEncoder().encode(
            InviteRequest(
                to: targetIdentity,
                fromIdentity: callerIdentity,
                room: room
            )
        )

        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            accessToken: accessToken
        )
    }

    func fetchTwilioAIAudioMirror(
        sessionKey: String,
        mirrorToken: String,
        remoteCursor: Int,
        localCursor: Int,
        accessToken: String
    ) async throws -> TwilioAIAudioMirrorResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.twilioAIAudioLatestEndpoint)"
        guard var components = URLComponents(string: endpoint) else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionKey),
            URLQueryItem(name: "remote_cursor", value: String(max(remoteCursor, 0))),
            URLQueryItem(name: "local_cursor", value: String(max(localCursor, 0)))
        ]
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mirrorToken, forHTTPHeaderField: "X-Vicall-Audio-Mirror-Token")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "Unknown error"
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode, message)
        }

        do {
            return try JSONDecoder().decode(TwilioAIAudioMirrorResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Account Deletion

    func prepareAccountDeletion(
        phoneNumber: String,
        userId: String?,
        identity: String,
        accessToken: String
    ) async throws -> AccountDeletionPreparationResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.accountDeletionPrepareEndpoint)"

        struct DeleteAccountRequest: Codable {
            let phoneNumber: String
            let userId: String?
            let identity: String

            enum CodingKeys: String, CodingKey {
                case phoneNumber = "phone_number"
                case userId = "user_id"
                case identity
            }
        }

        let body = try JSONEncoder().encode(
            DeleteAccountRequest(
                phoneNumber: phoneNumber,
                userId: userId,
                identity: identity
            )
        )

        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            accessToken: accessToken
        )
    }

    func executeAccountDeletion(
        deletionToken: String
    ) async throws -> AccountDeletionResponse {
        let endpoint = "\(Constants.twilioVoiceBaseURL)\(Constants.accountDeletionExecuteEndpoint)"

        struct DeleteAccountExecutionRequest: Codable {
            let deletionToken: String

            enum CodingKeys: String, CodingKey {
                case deletionToken = "deletion_token"
            }
        }

        let body = try JSONEncoder().encode(
            DeleteAccountExecutionRequest(deletionToken: deletionToken)
        )

        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }
    
// MARK: - Generic Request
    
    private func makeRequest<T: Decodable>(
        endpoint: String,
        method: String,
        body: Data? = nil,
        requiresAuth: Bool = true,
        accessToken: String? = nil
    ) async throws -> T {
        
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = body
        }
        
        let (data, response): (Data, URLResponse)
        
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        // Handle HTTP errors
        if !(200...299).contains(httpResponse.statusCode) {
            let message = Self.extractErrorMessage(from: data) ?? "Unknown error"
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode, message)
        }
        
        // Decode response
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let message = stringValue(from: object) {
                return message
            }
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    private static func stringValue(from object: Any) -> String? {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dictionary = object as? [String: Any] {
            for key in ["detail", "message", "error"] {
                if let value = dictionary[key], let message = stringValue(from: value) {
                    return message
                }
            }
        }

        if let array = object as? [Any] {
            let messages = array.compactMap { stringValue(from: $0) }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }

        return nil
    }
}
