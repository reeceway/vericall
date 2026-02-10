import Foundation
import Combine
import Security

/// Manages real-time voice verification during active calls
/// Coordinates audio capture, signature extraction, and matching
public final class VoiceVerificationService: ObservableObject {
    
    // MARK: - Published State
    @Published public private(set) var verificationState: VerificationState = .idle
    @Published public private(set) var currentResult: VoiceVerificationResult?
    @Published public private(set) var isVerifying = false
    
    // MARK: - Services
    private let audioCaptureService = AudioCaptureService()
    private let verifier = LocalVoiceVerifier()
    private let keychainService = VoiceKeychainService()
    
    // MARK: - Properties
    private var storedSignature: VoiceSignature?
    private var verificationCancellable: AnyCancellable?
    private var contactId: String?
    
    // Track recent results for smoothing
    private var recentResults: [Float] = []
    private let smoothingWindowSize = 3
    
    // MARK: - Initialization
    public init() {
        audioCaptureService.delegate = self
    }
    
    deinit {
        stopVerification()
    }
    
    // MARK: - Public Methods
    
    /// Start verification for a specific contact using stored signature
    public func startVerification(for contactId: String) async throws {
        // Load stored signature from Keychain
        guard let signature = try? keychainService.loadSignature(for: contactId) else {
            throw VerificationError.noStoredSignature
        }

        try await startVerification(with: signature, contactId: contactId)
    }
    
    /// Start verification with received voice thumbprint (from incoming call)
    public func startVerification(withExternalThumbprint receivedThumbprint: [Float], contactId: String? = nil) async throws {
        let signature = VoiceSignature(
            vector: receivedThumbprint,
            contactId: contactId ?? "unknown",
            phraseCount: 5
        )
        
        try await startVerification(with: signature, contactId: contactId)
    }
    
    /// Internal method to start verification with a signature
    private func startVerification(with signature: VoiceSignature, contactId: String?) async throws {
        self.contactId = contactId
        self.storedSignature = signature
        self.recentResults.removeAll()
        try await audioCaptureService.startCapture()
        
        await MainActor.run {
            self.verificationState = .capturing
            self.isVerifying = true
        }
        
        print("[VoiceVerificationService] Started verification for contact: \(contactId)")
    }
    
    /// Stop verification
    public func stopVerification() {
        audioCaptureService.stopCapture()
        
        DispatchQueue.main.async { [weak self] in
            self?.verificationState = .idle
            self?.isVerifying = false
            self?.currentResult = nil
            self?.recentResults.removeAll()
        }
        
        print("[VoiceVerificationService] Stopped verification")
    }
    
    /// Pause verification
    public func pauseVerification() {
        audioCaptureService.pauseCapture()
        DispatchQueue.main.async { [weak self] in
            self?.verificationState = .idle
        }
    }
    
    /// Resume verification
    public func resumeVerification() throws {
        try audioCaptureService.resumeCapture()
        DispatchQueue.main.async { [weak self] in
            self?.verificationState = .capturing
        }
    }
    
    /// Check if a contact has a stored voice signature
    public func hasSignature(for contactId: String) async -> Bool {
        (try? keychainService.loadSignature(for: contactId)) != nil
    }
    
    /// Get audio level for UI visualization
    public var currentAudioLevel: Float {
        audioCaptureService.currentAudioLevel
    }
    
    /// Get audio spectrum for UI visualization
    public var audioSpectrum: [Float] {
        audioCaptureService.audioSpectrum
    }
    
    // MARK: - Private Methods
    
    private func processVerificationChunk(_ audioChunk: [Float]) {
        guard let storedSignature = storedSignature else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.verificationState = .analyzing
        }
        
        // Extract signature and compare (this happens on background queue)
        let result = verifier.verify(audioData: audioChunk, against: storedSignature)
        
        // Apply temporal smoothing
        let smoothedSimilarity = applySmoothing(result.similarity)
        
        // Create smoothed result
        let smoothedResult = VoiceVerificationResult(
            similarity: smoothedSimilarity,
            analysisDuration: result.analysisDuration,
            processingTimeMs: result.processingTimeMs
        )
        
        DispatchQueue.main.async { [weak self] in
            self?.currentResult = smoothedResult
            self?.verificationState = .result(smoothedResult)
        }
        
        print("[VoiceVerificationService] Match: \(Int(smoothedSimilarity * 100))% (processed in \(String(format: "%.1f", result.processingTimeMs))ms)")
    }
    
    private func applySmoothing(_ newValue: Float) -> Float {
        recentResults.append(newValue)
        
        // Keep only recent values
        if recentResults.count > smoothingWindowSize {
            recentResults.removeFirst()
        }
        
        // Simple moving average
        let sum = recentResults.reduce(0, +)
        return sum / Float(recentResults.count)
    }
}

// MARK: - Audio Capture Delegate
extension VoiceVerificationService: AudioCaptureDelegate {
    public func audioCaptureService(_ service: AudioCaptureService, didCaptureChunk chunk: [Float]) {
        processVerificationChunk(chunk)
    }
}

// MARK: - Keychain Service
public final class VoiceKeychainService {
    
    private let serviceIdentifier = "com.vericall.voicesignature"
    
    /// Save voice signature to Keychain
    public func saveSignature(_ signature: VoiceSignature) throws {
        let data = try JSONEncoder().encode(signature)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: signature.contactId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceKeychainError.saveFailed(status)
        }
        
        print("[VoiceKeychainService] Saved signature for contact: \(signature.contactId)")
    }
    
    /// Load voice signature from Keychain
    public func loadSignature(for contactId: String) throws -> VoiceSignature {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: contactId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            throw VoiceKeychainError.loadFailed(status)
        }
        
        guard let data = result as? Data else {
            throw VoiceKeychainError.invalidData
        }
        
        let signature = try JSONDecoder().decode(VoiceSignature.self, from: data)
        print("[VoiceKeychainService] Loaded signature for contact: \(contactId)")
        return signature
    }
    
    /// Delete voice signature from Keychain
    public func deleteSignature(for contactId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: contactId
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceKeychainError.deleteFailed(status)
        }
        
        print("[VoiceKeychainService] Deleted signature for contact: \(contactId)")
    }
    
    /// Check if signature exists
    public func signatureExists(for contactId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: contactId,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

// MARK: - Errors
public enum VerificationError: Error, LocalizedError {
    case noStoredSignature
    case audioCaptureFailed
    case verificationInProgress
    case processingFailed
    
    public var errorDescription: String? {
        switch self {
        case .noStoredSignature:
            return "No voice signature found for this contact. Please complete enrollment first."
        case .audioCaptureFailed:
            return "Failed to capture audio during call"
        case .verificationInProgress:
            return "Verification is already in progress"
        case .processingFailed:
            return "Voice processing failed"
        }
    }
}

public enum VoiceKeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save voice signature (status: \(status))"
        case .loadFailed(let status):
            return "Failed to load voice signature (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete voice signature (status: \(status))"
        case .invalidData:
            return "Invalid signature data in Keychain"
        }
    }
}