import Foundation

struct User: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    var displayName: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case phoneNumber = "phone_number"
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, phoneNumber: String, displayName: String? = nil) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let userId: String?
    let deviceId: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case deviceId = "device_id"
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
    let otp: String
    let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case otp
        case publicKey = "public_key"
    }
}

struct OTPResponse: Codable {
    let message: String
    let phoneNumber: String?

    enum CodingKeys: String, CodingKey {
        case message
        case phoneNumber = "phone_number"
    }
}

// MARK: - User Lookup Response
struct UserLookupResponse: Codable {
    let user: User?
    let found: Bool
}

// MARK: - Contact Sync Response
struct ContactSyncResponse: Codable {
    let users: [User]
}

