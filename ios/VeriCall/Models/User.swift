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
        // Handle dates that may or may not have timezone suffix
        // Backend sends "2026-01-15T10:30:00.123456" (no Z) which fails with .iso8601
        self.createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        self.updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
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
    let membershipId: String?
    let organizationId: String?
    let organizationName: String?
    let mspId: String?
    let mspName: String?
    let accessCodeId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case deviceId = "device_id"
        case expiresIn = "expires_in"
        case membershipId = "membership_id"
        case organizationId = "organization_id"
        case organizationName = "organization_name"
        case mspId = "msp_id"
        case mspName = "msp_name"
        case accessCodeId = "access_code_id"
    }
}

struct OTPRequest: Codable {
    let phoneNumber: String
    let companyAccessCode: String?
    let accessGrantToken: String?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case companyAccessCode = "access_code"
        case accessGrantToken = "access_grant_token"
    }

    init(phoneNumber: String, companyAccessCode: String? = nil, accessGrantToken: String? = nil) {
        self.phoneNumber = phoneNumber
        self.companyAccessCode = companyAccessCode
        self.accessGrantToken = accessGrantToken
    }
}

struct OTPVerifyRequest: Codable {
    let phoneNumber: String
    let otp: String
    let publicKey: String?
    let accessGrantToken: String?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case otp
        case publicKey = "public_key"
        case accessGrantToken = "access_grant_token"
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

struct AccessCodeValidationResponse: Codable {
    let valid: Bool
    let message: String?
    let organizationId: String?
    let organizationName: String?
    let mspId: String?
    let mspName: String?
    let accessCodeId: String?
    let grantToken: String?
    let seatPriceCents: Int?

    enum CodingKeys: String, CodingKey {
        case valid
        case message
        case organizationId = "organization_id"
        case organizationName = "organization_name"
        case mspId = "msp_id"
        case mspName = "msp_name"
        case accessCodeId = "access_code_id"
        case grantToken = "grant_token"
        case seatPriceCents = "seat_price_cents"
    }

    var accessContext: CompanyAccessContext? {
        guard
            let organizationId,
            let organizationName,
            let mspId,
            let mspName,
            let accessCodeId
        else {
            return nil
        }
        return CompanyAccessContext(
            organizationId: organizationId,
            organizationName: organizationName,
            mspId: mspId,
            mspName: mspName,
            accessCodeId: accessCodeId,
            membershipId: nil,
            grantToken: grantToken,
            seatPriceCents: seatPriceCents
        )
    }
}

struct CompanyAccessContext: Codable {
    let organizationId: String
    let organizationName: String
    let mspId: String
    let mspName: String
    let accessCodeId: String
    var membershipId: String?
    var grantToken: String?
    let seatPriceCents: Int?

    enum CodingKeys: String, CodingKey {
        case organizationId = "organization_id"
        case organizationName = "organization_name"
        case mspId = "msp_id"
        case mspName = "msp_name"
        case accessCodeId = "access_code_id"
        case membershipId = "membership_id"
        case grantToken = "grant_token"
        case seatPriceCents = "seat_price_cents"
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

struct TwilioVoiceAccessTokenResponse: Codable {
    let token: String
    let identity: String?
    let expiresIn: Int?
    let membershipId: String?
    let organizationId: String?
    let mspId: String?

    enum CodingKeys: String, CodingKey {
        case token
        case identity
        case expiresIn = "expires_in"
        case membershipId = "membership_id"
        case organizationId = "organization_id"
        case mspId = "msp_id"
    }
}

struct TwilioConferenceInviteResponse: Codable {
    let callSid: String
    let from: String
    let to: String
    let room: String

    enum CodingKeys: String, CodingKey {
        case callSid = "call_sid"
        case from
        case to
        case room
    }
}

struct TwilioAIAudioMirrorResponse: Codable {
    let session: String
    let sampleRate: Int
    let remoteCursor: Int
    let localCursor: Int
    let remotePCM16Base64: String?
    let localPCM16Base64: String?
    let remoteSamples: Int
    let localSamples: Int
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case session
        case sampleRate = "sample_rate"
        case remoteCursor = "remote_cursor"
        case localCursor = "local_cursor"
        case remotePCM16Base64 = "remote_pcm16_base64"
        case localPCM16Base64 = "local_pcm16_base64"
        case remoteSamples = "remote_samples"
        case localSamples = "local_samples"
        case active
    }
}

struct AccountDeletionPreparationResponse: Codable {
    let mode: String
    let deletionToken: String?
    let manageURL: String?
    let expiresAt: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case deletionToken = "deletion_token"
        case manageURL = "manage_url"
        case expiresAt = "expires_at"
        case message
    }
}

struct AccountDeletionResponse: Codable {
    let status: String
    let deactivatedMemberships: Int
    let organizations: [String]
    let deviceBindingRemoved: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case deactivatedMemberships = "deactivated_memberships"
        case organizations
        case deviceBindingRemoved = "device_binding_removed"
    }
}
