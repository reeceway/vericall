import Foundation

struct User: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    let displayName: String?
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case phoneNumber = "phone_number"
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
    let expiresIn: Int
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
        case expiresIn = "expires_in"
    }
}

struct OTPRequest: Codable {
    let phoneNumber: String
    
    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
    }
}

struct OTPVerifyRequest: Codable {
    let phoneNumber: String
    let code: String
    let devicePublicKey: String?
    
    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case code
        case devicePublicKey = "device_public_key"
    }
}

struct OTPResponse: Codable {
    let success: Bool
    let message: String
}
