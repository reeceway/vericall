import Foundation

struct User: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    var displayName: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle id coming as either string or UUID
        if let stringId = try? container.decode(String.self, forKey: .id) {
            self.id = stringId
        } else {
            // Try decoding as any type and convert to string
            let anyId = try container.decode(AnyCodableValue.self, forKey: .id)
            self.id = anyId.stringValue
        }
        self.phoneNumber = try container.decode(String.self, forKey: .phoneNumber)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// Helper to decode values that might be UUID, string, int, etc.
private struct AnyCodableValue: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            stringValue = str
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            stringValue = String(double)
        } else {
            stringValue = ""
        }
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

// MARK: - Contact Sync Response (backend returns "contacts" array)
struct ContactSyncResponse: Codable {
    let contacts: [SyncedContact]?
    let users: [User]?

    // Backend returns ContactInfo objects, not full User objects
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
}

