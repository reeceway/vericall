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
            return "Error \(code): \(message)"
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
    
    private init() {
        self.baseURL = Constants.apiBaseURL
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Request OTP
    
    func requestOTP(phoneNumber: String) async throws -> OTPResponse {
        let endpoint = "\(baseURL)/auth/otp/request"
        
        let request = OTPRequest(phoneNumber: phoneNumber)
        let body = try JSONEncoder().encode(request)
        
        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            requiresAuth: false
        )
    }
    
    // MARK: - Verify OTP
    
    func verifyOTP(phoneNumber: String, code: String, devicePublicKey: String?) async throws -> AuthResponse {
        let endpoint = "\(baseURL)/auth/otp/verify"
        
        let request = OTPVerifyRequest(
            phoneNumber: phoneNumber,
            code: code,
            devicePublicKey: devicePublicKey
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
    
    func syncContacts(phoneNumbers: [String], accessToken: String) async throws -> [User] {
        let endpoint = "\(baseURL)/contacts/sync"
        
        struct SyncRequest: Codable {
            let contacts: [String]
        }
        
        struct SyncResponse: Codable {
            let users: [User]
        }
        
        let request = SyncRequest(contacts: phoneNumbers)
        let body = try JSONEncoder().encode(request)
        
        let response: SyncResponse = try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            accessToken: accessToken
        )
        
        return response.users
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
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
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
}
