import Foundation
import CallKit
import Combine

/// Observes native phone calls and triggers VeriCall verification
/// - Incoming calls: Show "Unverified" immediately, update to "Verified" if handshake received
/// - Outgoing calls: Send handshakes to recipient's VeriCall account
@MainActor
class NativeCallObserver: NSObject, ObservableObject {
    static let shared = NativeCallObserver()
    
    // MARK: - Published State
    @Published var isInNativeCall = false
    @Published var currentCallPhoneNumber: String?
    @Published var currentCallUUID: UUID?
    @Published var verificationStatus: NativeCallVerificationStatus = .idle
    @Published var voiceMatchPercentage: Double?
    @Published var receivedThumbprint: [Float]?
    @Published var remoteUserName: String?
    
    // MARK: - Handshake State
    @Published var sentOurHandshake = false
    @Published var receivedTheirHandshake = false
    
    // MARK: - Services
    private let callObserver = CXCallObserver()
    private let apiService = APIService.shared
    private let webSocketService = WebSocketService.shared
    private let authKeychain = KeychainService.shared
    private let voiceVerificationService = VoiceVerificationService()
    private let keychainService = VoiceKeychainService()
    private let notificationService = NotificationService.shared
    
    // MARK: - State
    private var handshakeTimer: Timer?
    private var unverifiedTimer: Timer?
    private var isOutgoingCall = false
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    private override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        setupVoiceVerificationSubscription()
        print("[NativeCallObserver] ✅ Initialized - monitoring native phone calls")
    }
    
    // MARK: - Setup
    
    private func setupVoiceVerificationSubscription() {
        voiceVerificationService.$currentResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self = self, let result = result else { return }
                self.voiceMatchPercentage = Double(result.similarity)
                Task {
                    await self.handleVoiceMatchResult(result.similarity)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - INCOMING CALL: Show Unverified, Wait for Handshake
    
    private func handleIncomingCall(call: CXCall) async {
        print("[NativeCallObserver] 📞 INCOMING call detected")
        
        isInNativeCall = true
        currentCallUUID = call.uuid
        isOutgoingCall = false
        sentOurHandshake = false
        receivedTheirHandshake = false
        
        // IMMEDIATELY show UNVERIFIED notification
        verificationStatus = .unverified
        await notificationService.showCallVerificationNotification(
            callerName: "Incoming Call",
            callerId: "unknown",
            isDeviceVerified: false,
            hasVoiceThumbprint: false
        )
        
        print("[NativeCallObserver] ⚠️ Showing UNVERIFIED - waiting for handshake...")
        
        // Start timer - if no handshake received in 3 seconds, stays unverified
        startUnverifiedTimer()
    }
    
    private func startUnverifiedTimer() {
        unverifiedTimer?.invalidate()
        unverifiedTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.verificationStatus == .unverified {
                    print("[NativeCallObserver] ⏰ No handshake received - caller is UNVERIFIED")
                    // Update notification to make it clear
                    await self.notificationService.showCallVerificationNotification(
                        callerName: "Unknown Caller",
                        callerId: "unknown",
                        isDeviceVerified: false,
                        hasVoiceThumbprint: false
                    )
                }
            }
        }
    }
    
    // MARK: - OUTGOING CALL: Send Handshakes
    
    private func handleOutgoingCall(call: CXCall) async {
        print("[NativeCallObserver] 📱 OUTGOING call detected")
        
        isInNativeCall = true
        currentCallUUID = call.uuid
        isOutgoingCall = true
        sentOurHandshake = false
        receivedTheirHandshake = false
        verificationStatus = .sendingHandshake
        
        // If we have the phone number (set via userInitiatedCall), send handshakes
        if let phoneNumber = currentCallPhoneNumber {
            await sendHandshakesToRecipient(phoneNumber: phoneNumber)
        } else {
            print("[NativeCallObserver] ⚠️ No phone number set - can't send handshakes")
            verificationStatus = .idle
        }
    }
    
    /// Send both handshake messages to the recipient's VeriCall account
    private func sendHandshakesToRecipient(phoneNumber: String) async {
        print("[NativeCallObserver] 🤝 Sending handshakes to \(phoneNumber)")
        
        // 1. Check if WE have enrolled our voice
        guard let mySignature = try? keychainService.loadSignature(for: "self") else {
            print("[NativeCallObserver] ❌ We haven't enrolled our voice yet")
            verificationStatus = .notEnrolled
            return
        }
        
        // 2. Get access token
        guard let accessToken = try? await authKeychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        ) else {
            print("[NativeCallObserver] ❌ No access token - not logged in")
            verificationStatus = .handshakeFailed
            return
        }
        
        // 3. Look up if recipient has a VeriCall account
        do {
            guard let recipientInfo = try await apiService.lookupVeriCallUser(
                phoneNumber: phoneNumber,
                accessToken: accessToken
            ) else {
                print("[NativeCallObserver] ❌ Recipient doesn't have VeriCall")
                verificationStatus = .recipientNotOnVeriCall
                await notificationService.showCallVerificationNotification(
                    callerName: phoneNumber,
                    callerId: phoneNumber,
                    isDeviceVerified: false,
                    hasVoiceThumbprint: false
                )
                return
            }
            
            let recipientUserId = recipientInfo.id
            remoteUserName = recipientInfo.displayName ?? phoneNumber
            
            // 4. SEND HANDSHAKE 1: Our voice thumbprint
            let handshake1: [String: Any] = [
                "type": "native_call:handshake",
                "recipientId": recipientUserId,
                "phoneNumber": phoneNumber,
                "voiceThumbprint": mySignature.vector,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "callDirection": "outgoing"
            ]
            
            try await webSocketService.sendRaw(message: handshake1)
            print("[NativeCallObserver] ✅ Sent handshake 1 (our thumbprint)")
            
            // 5. SEND HANDSHAKE 2: Request their thumbprint
            let handshake2: [String: Any] = [
                "type": "native_call:request_thumbprint",
                "recipientId": recipientUserId,
                "phoneNumber": phoneNumber,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "callDirection": "outgoing"
            ]
            
            try await webSocketService.sendRaw(message: handshake2)
            print("[NativeCallObserver] ✅ Sent handshake 2 (thumbprint request)")
            
            sentOurHandshake = true
            verificationStatus = .awaitingResponse
            
            // Start timeout
            startHandshakeTimeout()
            
        } catch {
            print("[NativeCallObserver] ❌ Handshake failed: \(error)")
            verificationStatus = .handshakeFailed
        }
    }
    
    private func startHandshakeTimeout() {
        handshakeTimer?.invalidate()
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.verificationStatus == .awaitingResponse {
                    print("[NativeCallObserver] ⏰ Handshake timeout")
                    self.verificationStatus = .handshakeTimeout
                }
            }
        }
    }
    
    // MARK: - RECEIVING HANDSHAKES (Called from WebSocket handler)
    
    /// Called when we receive a handshake from caller (they're calling us)
    func handleReceivedHandshake(
        fromUserId: String,
        displayName: String?,
        voiceThumbprint: [Float],
        phoneNumber: String
    ) async {
        print("[NativeCallObserver] 📥 Received handshake from \(displayName ?? fromUserId)!")
        
        // Cancel unverified timer
        unverifiedTimer?.invalidate()
        
        // Store their thumbprint
        receivedThumbprint = voiceThumbprint
        receivedTheirHandshake = true
        remoteUserName = displayName ?? phoneNumber
        currentCallPhoneNumber = phoneNumber
        
        // UPDATE TO VERIFIED!
        verificationStatus = .verified
        print("[NativeCallObserver] ✅ VERIFIED! Caller has VeriCall")
        
        // Show VERIFIED notification
        await notificationService.showCallVerificationNotification(
            callerName: displayName ?? phoneNumber,
            callerId: fromUserId,
            isDeviceVerified: true,
            hasVoiceThumbprint: true
        )
        
        // Send our handshake back
        if !sentOurHandshake {
            await sendHandshakeResponse(to: fromUserId)
        }
        
        // Start voice verification
        startVoiceVerification(withThumbprint: voiceThumbprint)
    }
    
    /// Called when they request our thumbprint
    func handleThumbprintRequest(fromUserId: String, phoneNumber: String) async {
        print("[NativeCallObserver] 📥 Received thumbprint request")
        await sendHandshakeResponse(to: fromUserId)
    }
    
    private func sendHandshakeResponse(to userId: String) async {
        guard let mySignature = try? keychainService.loadSignature(for: "self") else {
            print("[NativeCallObserver] ❌ Can't respond - no voice enrolled")
            return
        }
        
        do {
            let response: [String: Any] = [
                "type": "native_call:handshake_response",
                "recipientId": userId,
                "voiceThumbprint": mySignature.vector,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            
            try await webSocketService.sendRaw(message: response)
            print("[NativeCallObserver] ✅ Sent our thumbprint response")
            sentOurHandshake = true
        } catch {
            print("[NativeCallObserver] ❌ Failed to send response: \(error)")
        }
    }
    
    // MARK: - Voice Verification
    
    private func startVoiceVerification(withThumbprint thumbprint: [Float]) {
        print("[NativeCallObserver] 🎤 Starting continuous voice verification")
        verificationStatus = .verifyingVoice
        
        Task {
            do {
                try await voiceVerificationService.startVerification(
                    withExternalThumbprint: thumbprint,
                    contactId: currentCallPhoneNumber
                )
            } catch {
                print("[NativeCallObserver] ❌ Voice verification failed: \(error)")
            }
        }
    }
    
    private func handleVoiceMatchResult(_ similarity: Float) async {
        guard isInNativeCall else { return }
        
        let percentage = Double(similarity)
        voiceMatchPercentage = percentage
        
        if let name = remoteUserName, let uuid = currentCallUUID {
            await notificationService.showVoiceMatchNotification(
                callerName: name,
                matchPercentage: percentage,
                callId: uuid.uuidString
            )
        }
    }
    
    // MARK: - Call State Management
    
    private func handleCallStarted(call: CXCall) {
        print("[NativeCallObserver] 📞 Call started - Outgoing: \(call.isOutgoing)")
        
        Task {
            if call.isOutgoing {
                await handleOutgoingCall(call: call)
            } else {
                await handleIncomingCall(call: call)
            }
        }
    }
    
    private func handleCallConnected(call: CXCall) {
        print("[NativeCallObserver] 📞 Call connected")
        
        if let thumbprint = receivedThumbprint, verificationStatus == .verified {
            startVoiceVerification(withThumbprint: thumbprint)
        }
    }
    
    private func handleCallEnded(call: CXCall) {
        print("[NativeCallObserver] 📞 Call ended")
        
        voiceVerificationService.stopVerification()
        
        // Reset state
        isInNativeCall = false
        currentCallUUID = nil
        currentCallPhoneNumber = nil
        verificationStatus = .idle
        voiceMatchPercentage = nil
        receivedThumbprint = nil
        remoteUserName = nil
        sentOurHandshake = false
        receivedTheirHandshake = false
        
        handshakeTimer?.invalidate()
        unverifiedTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    
    /// Call this when user initiates an outgoing call through your app
    /// Sets the phone number so handshakes can be sent
    func userInitiatedCall(to phoneNumber: String) {
        print("[NativeCallObserver] 📱 User initiating call to \(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
    }
    
    /// Called by AppDelegate when a VoIP push requests we send our handshake
    /// (Used when someone is calling us and we need to identify ourselves)
    func triggerOutgoingHandshake(to phoneNumber: String) async {
        print("[NativeCallObserver] 🤝 VoIP push - sending handshake to \(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
        await sendHandshakesToRecipient(phoneNumber: phoneNumber)
    }
}

// MARK: - CXCallObserverDelegate
extension NativeCallObserver: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            if call.hasConnected && !call.hasEnded {
                handleCallConnected(call: call)
            } else if call.hasEnded {
                handleCallEnded(call: call)
            } else if !call.hasConnected && !call.hasEnded {
                handleCallStarted(call: call)
            }
        }
    }
}

// MARK: - Verification Status
enum NativeCallVerificationStatus: Equatable {
    case idle
    case unverified          // Incoming call - no handshake yet
    case sendingHandshake    // Sending our handshakes
    case awaitingResponse    // Waiting for their response
    case verified            // ✓ Both verified!
    case verifyingVoice      // Checking voice matches thumbprint
    case handshakeTimeout    // No response in time
    case handshakeFailed     // Error
    case recipientNotOnVeriCall
    case notEnrolled
    
    var displayText: String {
        switch self {
        case .idle: return ""
        case .unverified: return "⚠️ Unverified Caller"
        case .sendingHandshake: return "Verifying..."
        case .awaitingResponse: return "Waiting..."
        case .verified: return "✓ Verified"
        case .verifyingVoice: return "🎤 Checking voice..."
        case .handshakeTimeout: return "⚠️ Timeout"
        case .handshakeFailed: return "❌ Failed"
        case .recipientNotOnVeriCall: return "Not on VeriCall"
        case .notEnrolled: return "Voice not enrolled"
        }
    }
}
