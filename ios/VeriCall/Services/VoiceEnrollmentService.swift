import Foundation
import Security

/// Stores and retrieves speaker voiceprints (192-dim ECAPA embeddings) in the iOS Keychain.
///
/// Usage:
///   - Enroll: record ~5-10s audio, call `enroll(samples:forContact:)`
///   - Verify: `loadEmbedding(for:)` → pass to AIAnalysisService
///   - Delete: `deleteSignature(for:)`
final class VoiceEnrollmentService {

    static let shared = VoiceEnrollmentService()
    private let keychain = VoiceKeychainService()

    private init() {}

    // MARK: - Enroll

    /// Compute and store a speaker embedding from raw PCM samples.
    /// Requires at least 3s of audio (48,000 samples at 16kHz).
    func enroll(samples: [Float], forContact contactId: String) throws {
        guard samples.count >= AudioConfiguration.analysisWindowSamples else {
            throw EnrollmentError.insufficientAudio(
                required: AudioConfiguration.analysisWindowSamples,
                got: samples.count
            )
        }

        // Compute embeddings for each 3s window and average for a robust voiceprint
        let windowSize = AudioConfiguration.analysisWindowSamples  // 48,000 samples = 3s
        var embeddings: [[Float]] = []
        var offset = 0
        while offset + windowSize <= samples.count {
            if let emb = EmbedderWrapper.shared.embed(samples: Array(samples[offset..<(offset + windowSize)])) {
                embeddings.append(emb)
            }
            offset += windowSize
        }
        guard !embeddings.isEmpty else { throw EnrollmentError.embeddingFailed }

        // Mean-pool across windows
        var averaged = [Float](repeating: 0, count: AudioConfiguration.embeddingDim)
        for emb in embeddings {
            for i in 0..<AudioConfiguration.embeddingDim { averaged[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        for i in 0..<AudioConfiguration.embeddingDim { averaged[i] /= n }

        let signature = VoiceSignature(
            contactId: contactId,
            embedding: averaged,
            modelVersion: AudioConfiguration.voiceEmbedderVersion
        )
        try keychain.save(signature)
        print("[VoiceEnrollment] Enrolled contact: \(contactId) (\(embeddings.count) windows averaged, dim: \(averaged.count), model: \(AudioConfiguration.voiceEmbedderVersion))")
    }

    // MARK: - Load

    /// Load a stored 192-dim embedding for a contact. Returns nil if not enrolled.
    func loadEmbedding(for contactId: String) -> [Float]? {
        do {
            let signature = try keychain.load(for: contactId)
            if signature.embedding.count != AudioConfiguration.embeddingDim {
                print("[VoiceEnrollment] Invalid embedding size for \(contactId): \(signature.embedding.count)")
                return nil
            }
            if signature.modelVersion != AudioConfiguration.voiceEmbedderVersion {
                print("[VoiceEnrollment] Stored embedding for \(contactId) uses model \(signature.modelVersion), expected \(AudioConfiguration.voiceEmbedderVersion). Deleting stale voiceprint.")
                try? keychain.delete(for: contactId)
                return nil
            }
            return signature.embedding
        } catch {
            print("[VoiceEnrollment] No stored embedding for \(contactId): \(error)")
            return nil
        }
    }

    /// Check if a contact has a stored voiceprint.
    func isEnrolled(_ contactId: String) -> Bool {
        loadEmbedding(for: contactId) != nil
    }

    // MARK: - Delete

    func deleteSignature(for contactId: String) {
        try? keychain.delete(for: contactId)
    }
}

// MARK: - Errors

enum EnrollmentError: Error, LocalizedError {
    case insufficientAudio(required: Int, got: Int)
    case embeddingFailed

    var errorDescription: String? {
        switch self {
        case .insufficientAudio(let required, let got):
            return "Need at least \(required) samples (\(required/16000)s), got \(got)"
        case .embeddingFailed:
            return "Failed to compute voice embedding"
        }
    }
}

// MARK: - Keychain Backing

private final class VoiceKeychainService {

    private let service = "com.vericall.voiceprint"

    func save(_ sig: VoiceSignature) throws {
        let data = try JSONEncoder().encode(sig)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      sig.contactId,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceKeychainError.saveFailed(status)
        }
    }

    func load(for contactId: String) throws -> VoiceSignature {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  contactId,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw VoiceKeychainError.loadFailed(status)
        }
        return try JSONDecoder().decode(VoiceSignature.self, from: data)
    }

    func delete(for contactId: String) throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  contactId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceKeychainError.deleteFailed(status)
        }
    }
}

private enum VoiceKeychainError: Error {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}
