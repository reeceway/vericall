import Foundation
import CryptoKit

// MARK: - Call Signaling
@MainActor
class CallSignaling {
    static let shared = CallSignaling()
    
    private let apiBaseURL: String
    
    private init() {
        // Constants from other agents
        self.apiBaseURL = "https://api.vericall.example.com" // Replace with actual apiBaseURL
    }
    
    // MARK: - Create Signals
    
    func createInitiateSignal(
        callId: String,
        toUserId: String,
        isVerified: Bool
    ) async throws -> CallSignal {
        let payload = CallSignalPayload()
        
        // Create signal data for signing
        let signalData = SignalData(
            type: CallSignalType.initiate.rawValue,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date().iso8601String,
            payloadHash: payload.hashValue.description
        )
        
        // Sign with device private key
        let signature = try await signSignalData(signalData)
        
        return CallSignal(
            type: .initiate,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: signature
        )
    }
    
    func createOfferSignal(
        callId: String,
        toUserId: String,
        sdp: String
    ) async throws -> CallSignal {
        let payload = CallSignalPayload(sdp: sdp)
        
        let signalData = SignalData(
            type: CallSignalType.offer.rawValue,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date().iso8601String,
            payloadHash: payload.hashValue.description
        )
        
        let signature = try await signSignalData(signalData)
        
        return CallSignal(
            type: .offer,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: signature
        )
    }
    
    func createAnswerSignal(
        callId: String,
        toUserId: String,
        sdp: String
    ) async throws -> CallSignal {
        let payload = CallSignalPayload(sdp: sdp)
        
        let signalData = SignalData(
            type: CallSignalType.answer.rawValue,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date().iso8601String,
            payloadHash: payload.hashValue.description
        )
        
        let signature = try await signSignalData(signalData)
        
        return CallSignal(
            type: .answer,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: signature
        )
    }
    
    func createAcceptSignal(
        callId: String,
        toUserId: String
    ) async throws -> CallSignal {
        let payload = CallSignalPayload()
        
        let signalData = SignalData(
            type: CallSignalType.accept.rawValue,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date().iso8601String,
            payloadHash: payload.hashValue.description
        )
        
        let signature = try await signSignalData(signalData)
        
        return CallSignal(
            type: .accept,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: signature
        )
    }
    
    func createRejectSignal(
        callId: String,
        toUserId: String,
        reason: String
    ) async -> CallSignal {
        let payload = CallSignalPayload(reason: reason)
        
        // Rejection signals can be unsigned for simplicity
        return CallSignal(
            type: .reject,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: nil
        )
    }
    
    func createEndSignal(
        callId: String,
        toUserId: String
    ) async -> CallSignal {
        let payload = CallSignalPayload()
        
        return CallSignal(
            type: .end,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: nil
        )
    }
    
    func createICECandidateSignal(
        callId: String,
        toUserId: String,
        candidate: String,
        sdpMid: String,
        sdpMLineIndex: Int32
    ) async -> CallSignal {
        let payload = CallSignalPayload(
            iceCandidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
        )
        
        return CallSignal(
            type: .iceCandidate,
            callId: callId,
            fromUserId: "current_user_id",
            toUserId: toUserId,
            timestamp: Date(),
            payload: payload,
            signature: nil
        )
    }
    
    // MARK: - Signing
    
    private func signSignalData(_ data: SignalData) async throws -> String {
        // Retrieve private key from secure storage
        guard let privateKey = await getDevicePrivateKey() else {
            throw CallError.authenticationError
        }
        
        // Create data to sign
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let dataToSign = try encoder.encode(data)
        
        // Sign using device private key (using P256 for example)
        let signature = try privateKey.signature(for: dataToSign)
        
        return signature.rawRepresentation.base64EncodedString()
    }
    
    // MARK: - Verification
    
    func verifySignal(_ signal: CallSignal) async -> Bool {
        guard let signatureString = signal.signature else {
            return false // No signature means unverified
        }
        
        do {
            // Reconstruct signal data
            let signalData = SignalData(
                type: signal.type.rawValue,
                callId: signal.callId,
                fromUserId: signal.fromUserId,
                toUserId: signal.toUserId,
                timestamp: signal.timestamp.iso8601String,
                payloadHash: signal.payload.hashValue.description
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let dataToVerify = try encoder.encode(signalData)
            
            // Decode signature
            guard let signatureData = Data(base64Encoded: signatureString) else {
                return false
            }
            
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
            
            // Get caller's public key (from API or cache)
            guard let publicKey = await getPublicKey(for: signal.fromUserId) else {
                return false
            }
            
            // Verify signature
            return publicKey.isValidSignature(signature, for: dataToVerify)
            
        } catch {
            print("Signature verification failed: \(error)")
            return false
        }
    }
    
    // MARK: - Key Management
    
    private func getDevicePrivateKey() async -> P256.Signing.PrivateKey? {
        // TODO: Retrieve from Secure Enclave/Keychain
        // For now, return a placeholder - in production this should be:
        // 1. Generate on first app launch
        // 2. Store in Secure Enclave
        // 3. Retrieve when needed
        
        // Check if we have a stored key identifier
        guard let keyIdentifier = UserDefaults.standard.string(forKey: "device_private_key_id") else {
            // Generate new key pair
            do {
                let privateKey = try P256.Signing.PrivateKey()
                let publicKey = privateKey.publicKey
                
                // Store in Secure Enclave would go here
                // For now, using a placeholder storage
                UserDefaults.standard.set("device_key_\(UUID().uuidString)", forKey: "device_private_key_id")
                
                // Register public key with server
                await registerPublicKey(publicKey)
                
                return privateKey
            } catch {
                print("Failed to generate device key: \(error)")
                return nil
            }
        }
        
        // Retrieve from secure storage using keyIdentifier
        // This is a placeholder - actual implementation would use SecItemCopyMatching
        return nil
    }
    
    private func getPublicKey(for userId: String) async -> P256.Signing.PublicKey? {
        // TODO: Fetch from API or local cache
        // This would call the backend to get the user's registered public key
        return nil
    }
    
    private func registerPublicKey(_ publicKey: P256.Signing.PublicKey) async {
        let publicKeyData = publicKey.rawRepresentation
        let base64Key = publicKeyData.base64EncodedString()
        
        // TODO: Send to API
        // POST /api/devices/register
        // { publicKey: base64Key }
    }
}

// MARK: - Signal Data Structure
private struct SignalData: Codable {
    let type: String
    let callId: String
    let fromUserId: String
    let toUserId: String
    let timestamp: String
    let payloadHash: String
}

// MARK: - Date Extension
private extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
