import Foundation
import CryptoKit
import LocalAuthentication

enum DeviceCryptoError: Error {
    case keyGenerationFailed
    case keyNotFound
    case signingFailed
    case biometricsNotAvailable
    case invalidKeyData
}

actor DeviceCrypto {
    static let shared = DeviceCrypto()
    
    private let tag = "com.vericall.device_key"
    private let service = "com.vericall.keys"
    
    private init() {}
    
    // MARK: - Key Generation
    
    func generateDeviceKeypair() async throws -> String {
        // Delete any existing key
        try? await deleteDeviceKey()
        
        // Generate new P-256 key pair in Secure Enclave
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error = error?.takeRetainedValue() {
                throw DeviceCryptoError.keyGenerationFailed
            }
            throw DeviceCryptoError.keyGenerationFailed
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceCryptoError.keyGenerationFailed
        }
        
        // Export public key as base64
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw DeviceCryptoError.keyGenerationFailed
        }
        
        let publicKeyBase64 = (publicKeyData as Data).base64EncodedString()
        
        // Store the private key reference is already done by SecKeyCreateRandomKey with isPermanent
        // But we also store a flag in keychain to confirm existence
        try? await KeychainService.shared.saveString("true", service: service, account: "device_key_exists")
        
        return publicKeyBase64
    }
    
    // MARK: - Key Retrieval
    
    func getPublicKey() async throws -> String {
        guard let privateKey = try await getPrivateKey() else {
            throw DeviceCryptoError.keyNotFound
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceCryptoError.keyNotFound
        }
        
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw DeviceCryptoError.invalidKeyData
        }
        
        return (publicKeyData as Data).base64EncodedString()
    }
    
    func getPrivateKey() async throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw DeviceCryptoError.invalidStatus(status)
        }
        
        return result as! SecKey
    }
    
    // MARK: - Signing
    
    func sign(data: Data) async throws -> Data {
        guard let privateKey = try await getPrivateKey() else {
            throw DeviceCryptoError.keyNotFound
        }
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            throw DeviceCryptoError.signingFailed
        }
        
        return signature as Data
    }
    
    // MARK: - Cleanup
    
    func deleteDeviceKey() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        
        SecItemDelete(query as CFDictionary)
        try? await KeychainService.shared.delete(service: service, account: "device_key_exists")
    }
    
    func hasDeviceKey() async -> Bool {
        do {
            _ = try await getPrivateKey()
            return true
        } catch {
            return false
        }
    }
}

// Helper extension for error handling
extension DeviceCrypto {
    private func errorFromOSStatus(_ status: OSStatus) -> Error {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return NSError(domain: "DeviceCrypto", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
