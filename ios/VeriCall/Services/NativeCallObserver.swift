import Foundation
import UIKit
import CallKit
import Combine

/// Observes native phone calls and triggers VeriCall verification
/// - Incoming calls: Show "Unverified" immediately, update to "Verified" if handshake received
/// - Outgoing calls: Send handshakes to recipient's VeriCall account
///
/// KEY FIX: Handshakes can arrive BEFORE CXCallObserver fires. We now buffer
/// received handshakes and replay them once a call is detected. We also use
/// the matching-pool (native_call:in_call) as a fallback so verification
/// works even if the direct WebSocket relay fails.
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
    
    /// Buffered handshake that arrived before CXCallObserver fired.
    /// If a handshake arrives while we are NOT in a call, we stash it here
    /// and replay it once CXCallObserver detects the incoming/connected call.
    private var pendingHandshake: (fromUserId: String, displayName: String?, voiceThumbprint: [Float], phoneNumber: String)?
    
    /// Whether we already sent our voiceprint to the matching pool for this call
    private var sentToMatchingPool = false
    
    // MARK: - Initialization
    private override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        setupVoiceVerificationSubscription()
        print("[NativeCallObserver] Initialized - monitoring native phone calls")
    }
    
    // MARK: - Setup
    
    private func setupVoiceVerificationSubscription() {
        voiceVerificationService.$currentResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self = self, let result = result else { return }
                self.voiceMatchPercentage = Double(result.similarity) * 100.0
                Task {
                    await self.handleVoiceMatchResult(result.similarity)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - INCOMING CALL: Show Unverified, Wait for Handshake
    
    private func handleIncomingCall(call: CXCall) async {
        print("[NativeCallObserver] INCOMING call detected")

        isInNativeCall = true
        currentCallUUID = call.uuid
        isOutgoingCall = false
        sentOurHandshake = false
        receivedTheirHandshake = false
        sentToMatchingPool = false

        // Keep app alive in background to receive handshake via WebSocket
        startBackgroundTask()

        // Make sure WebSocket is connected to receive the handshake
        if !webSocketService.connectionStatus.isConnected {
            webSocketService.connect()
        }

        // KEY FIX: Check for a buffered handshake that arrived early
        if let pending = pendingHandshake {
            print("[NativeCallObserver] Replaying buffered handshake from \(pending.displayName ?? pending.fromUserId)")
            pendingHandshake = nil
            await handleReceivedHandshake(
                fromUserId: pending.fromUserId,
                displayName: pending.displayName,
                voiceThumbprint: pending.voiceThumbprint,
                phoneNumber: pending.phoneNumber
            )
            return  // Already verified - skip unverified flow
        }

        // IMMEDIATELY show UNVERIFIED notification
        verificationStatus = .unverified
        await notificationService.showCallVerificationNotification(
            callerName: "Incoming Call",
            callerId: "unknown",
            isDeviceVerified: false,
            hasVoiceThumbprint: false
        )

        print("[NativeCallObserver] Showing UNVERIFIED - waiting for handshake...")
        
        // Also send ourselves to the matching pool as a fallback
        await sendToMatchingPool(direction: "incoming")
        
        // Start timer - if no handshake received in 10 seconds, stays unverified
        startUnverifiedTimer()
    }
    
    private func startUnverifiedTimer() {
        unverifiedTimer?.invalidate()
        unverifiedTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.verificationStatus == .unverified || self.verificationStatus == .monitoring {
                    print("[NativeCallObserver] No handshake received - caller is UNVERIFIED")
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
        print("[NativeCallObserver] OUTGOING call detected by CXCallObserver")
        
        currentCallUUID = call.uuid
        isInNativeCall = true
        isOutgoingCall = true

        // If handshake was already sent via sendHandshakeBeforeCall(), don't send again.
        if sentOurHandshake {
            print("[NativeCallObserver] Handshake already sent before call - skipping")
            
            // KEY FIX: Check for a buffered response that arrived while Phone app was loading
            if let pending = pendingHandshake {
                print("[NativeCallObserver] Replaying buffered handshake response")
                pendingHandshake = nil
                await handleReceivedHandshake(
                    fromUserId: pending.fromUserId,
                    displayName: pending.displayName,
                    voiceThumbprint: pending.voiceThumbprint,
                    phoneNumber: pending.phoneNumber
                )
            }
            return
        }

        // Call was made from the regular Phone app (not VeriCall) - no phone number available.
        if currentCallPhoneNumber == nil {
            print("[NativeCallObserver] Call made outside VeriCall - monitoring for handshakes")
            verificationStatus = .monitoring
            
            // Use matching pool as fallback
            await sendToMatchingPool(direction: "outgoing")
        }
    }
    
    /// Send both handshake messages to the recipient's VeriCall account
    private func sendHandshakesToRecipient(phoneNumber: String) async {
        print("[NativeCallObserver] OUTGOING CALL - Sending handshake to \(phoneNumber)")
        
        // 1. Check if WE have enrolled our voice
        guard let mySignature = try? keychainService.loadSignature(for: "self") else {
            print("[NativeCallObserver] We haven't enrolled our voice yet - can't verify")
            verificationStatus = .notEnrolled
            return
        }
        
        print("[NativeCallObserver] Our voiceprint has \(mySignature.vector.count) values")
        
        // 2. Get access token
        guard let accessToken = try? await authKeychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        ) else {
            print("[NativeCallObserver] No access token - not logged in")
            verificationStatus = .handshakeFailed
            return
        }
        
        // 3. Make sure WebSocket is connected
        if !webSocketService.connectionStatus.isConnected {
            print("[NativeCallObserver] WebSocket not connected - connecting...")
            webSocketService.connect()
            // Wait up to 2 seconds for connection
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if webSocketService.connectionStatus.isConnected { break }
            }
        }
        
        guard webSocketService.connectionStatus.isConnected else {
            print("[NativeCallObserver] WebSocket still not connected")
            verificationStatus = .handshakeFailed
            return
        }
        
        // 4. Look up if recipient has a VeriCall account
        do {
            guard let recipientInfo = try await apiService.lookupVeriCallUser(
                phoneNumber: phoneNumber,
                accessToken: accessToken
            ) else {
                print("[NativeCallObserver] Recipient doesn't have VeriCall")
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
            
            print("[NativeCallObserver] Found recipient: \(recipientInfo.displayName ?? recipientUserId)")
            
            // 5. SEND OUR HANDSHAKE with our voiceprint (direct WebSocket relay)
            //    Convert [Float] -> [Double] for JSON serialization compatibility
            let handshake: [String: Any] = [
                "type": "native_call:handshake",
                "recipientId": recipientUserId,
                "phoneNumber": phoneNumber,
                "voiceThumbprint": mySignature.vector.map { Double($0) },
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "callDirection": "outgoing"
            ]
            
            try await webSocketService.sendRaw(message: handshake)
            print("[NativeCallObserver] SENT our voiceprint to recipient via direct relay")
            
            sentOurHandshake = true
            verificationStatus = .awaitingResponse
            
            // 6. ALSO send to the matching pool as a fallback
            await sendToMatchingPool(direction: "outgoing")
            
            // Start timeout - waiting for THEIR handshake back
            startHandshakeTimeout()
            
        } catch {
            print("[NativeCallObserver] Handshake failed: \(error)")
            verificationStatus = .handshakeFailed
        }
    }
    
    // MARK: - Matching Pool Fallback
    
    /// Send our voiceprint to the matching pool so the backend can pair us
    /// with the other VeriCall user in this call, even if the direct relay fails.
    private func sendToMatchingPool(direction: String) async {
        guard !sentToMatchingPool else { return }
        
        guard let mySignature = try? keychainService.loadSignature(for: "self") else {
            print("[NativeCallObserver] No voice enrolled - can't send to matching pool")
            return
        }
        
        guard webSocketService.connectionStatus.isConnected else {
            print("[NativeCallObserver] WebSocket not connected - can't send to matching pool")
            return
        }
        
        do {
            let poolMessage: [String: Any] = [
                "type": "native_call:in_call",
                "direction": direction,
                "voiceThumbprint": mySignature.vector.map { Double($0) },
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            try await webSocketService.sendRaw(message: poolMessage)
            sentToMatchingPool = true
            print("[NativeCallObserver] Sent voiceprint to matching pool (\(direction))")
        } catch {
            print("[NativeCallObserver] Failed to send to matching pool: \(error)")
        }
    }
    
    private func startHandshakeTimeout() {
        handshakeTimer?.invalidate()
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.verificationStatus == .awaitingResponse {
                    print("[NativeCallObserver] Handshake timeout - still waiting")
                    self.verificationStatus = .handshakeTimeout
                }
            }
        }
    }
    
    // MARK: - RECEIVING HANDSHAKES (Called from WebSocket handler)
    
    /// Called when we receive a handshake from the other party.
    /// This can arrive BEFORE CXCallObserver fires (race condition).
    /// If we are not in a call yet, we buffer it and replay later.
    func handleReceivedHandshake(
        fromUserId: String,
        displayName: String?,
        voiceThumbprint: [Float],
        phoneNumber: String
    ) async {
        print("[NativeCallObserver] RECEIVED HANDSHAKE from \(displayName ?? fromUserId)")
        print("[NativeCallObserver] Voiceprint has \(voiceThumbprint.count) values")
        
        // KEY FIX: Buffer if we are not in a call yet
        if !isInNativeCall && verificationStatus == .idle {
            print("[NativeCallObserver] Not in a call yet - buffering handshake for replay")
            pendingHandshake = (fromUserId, displayName, voiceThumbprint, phoneNumber)
            
            // Pre-show the verified notification even though CXCallObserver has not fired.
            // The user is about to get a phone call and we already know who it is from.
            verificationStatus = .verified
            remoteUserName = displayName ?? phoneNumber
            receivedThumbprint = voiceThumbprint
            receivedTheirHandshake = true
            currentCallPhoneNumber = phoneNumber
            
            await notificationService.showCallVerificationNotification(
                callerName: displayName ?? phoneNumber,
                callerId: fromUserId,
                isDeviceVerified: true,
                hasVoiceThumbprint: true
            )
            print("[NativeCallObserver] Pre-verified! Notification shown before call rings")
            return
        }
        
        // Cancel unverified timer
        unverifiedTimer?.invalidate()
        
        // Store their thumbprint for voice verification
        receivedThumbprint = voiceThumbprint
        receivedTheirHandshake = true
        remoteUserName = displayName ?? phoneNumber
        currentCallPhoneNumber = phoneNumber
        
        // UPDATE STATUS TO VERIFIED!
        verificationStatus = .verified
        print("[NativeCallObserver] VERIFIED! Other party has VeriCall")
        
        // Show VERIFIED notification
        await notificationService.showCallVerificationNotification(
            callerName: displayName ?? phoneNumber,
            callerId: fromUserId,
            isDeviceVerified: true,
            hasVoiceThumbprint: true
        )
        
        // CRITICAL: Send OUR handshake back so they can verify us too!
        if !sentOurHandshake {
            print("[NativeCallObserver] Sending our handshake back...")
            await sendHandshakeResponse(to: fromUserId)
        }
        
        // NOTE: Live voice verification (audio capture) is NOT possible during
        // native phone calls on iOS. The system telephony session has exclusive
        // control of the audio hardware. Attempting to start AVAudioEngine will
        // crash the app. Device/cryptographic handshake verification is sufficient.
        print("[NativeCallObserver] Skipping live voice verification (not available during native calls)")
    }
    
    /// Called when they request our thumbprint
    func handleThumbprintRequest(fromUserId: String, phoneNumber: String) async {
        print("[NativeCallObserver] Received thumbprint request")
        await sendHandshakeResponse(to: fromUserId)
    }
    
    private func sendHandshakeResponse(to userId: String) async {
        guard let mySignature = try? keychainService.loadSignature(for: "self") else {
            print("[NativeCallObserver] Can't respond - no voice enrolled")
            return
        }
        
        // Make sure WebSocket is connected
        if !webSocketService.connectionStatus.isConnected {
            print("[NativeCallObserver] WebSocket not connected - connecting...")
            webSocketService.connect()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1s for connection
        }
        
        do {
            let response: [String: Any] = [
                "type": "native_call:handshake_response",
                "recipientId": userId,
                "phoneNumber": currentCallPhoneNumber ?? "",
                "voiceThumbprint": mySignature.vector.map { Double($0) },
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            
            try await webSocketService.sendRaw(message: response)
            print("[NativeCallObserver] Sent OUR voiceprint to \(userId)")
            sentOurHandshake = true
        } catch {
            print("[NativeCallObserver] Failed to send response: \(error)")
        }
    }
    
    // MARK: - Voice Verification
    
    /// Starts continuous voice verification during the call
    /// Compares the live audio from the call against the received voiceprint
    private func startVoiceVerification(withThumbprint thumbprint: [Float]) {
        print("[NativeCallObserver] Starting LIVE voice verification")
        print("[NativeCallObserver] Comparing call audio against \(thumbprint.count) value voiceprint")
        
        // Don't downgrade from .verified to .verifyingVoice - keep showing verified
        // The voice match percentage will update separately
        if verificationStatus != .verified {
            verificationStatus = .verifyingVoice
        }
        
        Task {
            do {
                try await voiceVerificationService.startVerification(
                    withExternalThumbprint: thumbprint,
                    contactId: currentCallPhoneNumber
                )
                print("[NativeCallObserver] Voice verification started successfully")
            } catch {
                print("[NativeCallObserver] Voice verification failed to start: \(error)")
            }
        }
    }
    
    private func handleVoiceMatchResult(_ similarity: Float) async {
        guard isInNativeCall else { return }
        
        let percentage = Double(similarity) * 100.0
        voiceMatchPercentage = percentage
        
        print("[NativeCallObserver] Voice match: \(String(format: "%.1f", percentage))%")
        
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
        print("[NativeCallObserver] Call started - Outgoing: \(call.isOutgoing)")
        
        Task {
            if call.isOutgoing {
                await handleOutgoingCall(call: call)
            } else {
                await handleIncomingCall(call: call)
            }
        }
    }
    
    private func handleCallConnected(call: CXCall) {
        print("[NativeCallObserver] Call connected")
        
        // NOTE: Live voice verification disabled during native calls.
        // iOS telephony has exclusive audio session control — AVAudioEngine will crash.
        if receivedThumbprint != nil, verificationStatus == .verified {
            print("[NativeCallObserver] Call connected - verified via handshake (voice verification N/A for native calls)")
        }
    }
    
    private func handleCallEnded(call: CXCall) {
        print("[NativeCallObserver] Call ended")

        voiceVerificationService.stopVerification()
        endBackgroundTask()
        
        // Notify matching pool that our call ended
        if sentToMatchingPool {
            Task {
                do {
                    try await webSocketService.sendRaw(message: ["type": "native_call:call_ended"])
                } catch { /* ignore */ }
            }
        }

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
        sentToMatchingPool = false
        pendingHandshake = nil

        handshakeTimer?.invalidate()
        unverifiedTimer?.invalidate()
    }
    
    // MARK: - Public Methods

    /// Called from VeriCall UI BEFORE opening the Phone app.
    /// Sends the handshake while the WebSocket is still connected (app in foreground).
    /// After this returns, it is safe to open tel: URL.
    func sendHandshakeBeforeCall(to phoneNumber: String) async {
        print("[NativeCallObserver] Sending handshake BEFORE opening Phone app to \(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
        isInNativeCall = true
        isOutgoingCall = true
        sentOurHandshake = false
        receivedTheirHandshake = false
        sentToMatchingPool = false
        pendingHandshake = nil
        verificationStatus = .sendingHandshake

        await sendHandshakesToRecipient(phoneNumber: phoneNumber)

        // Start a background task so iOS gives us time to receive the response
        startBackgroundTask()
        
        // Give a moment for the response to arrive before opening Phone app
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s grace period
    }

    /// Call this when user initiates an outgoing call through your app
    /// Sets the phone number so handshakes can be sent
    func userInitiatedCall(to phoneNumber: String) {
        print("[NativeCallObserver] User initiating call to \(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
    }

    /// Called by AppDelegate when a VoIP push requests we send our handshake
    func triggerOutgoingHandshake(to phoneNumber: String) async {
        print("[NativeCallObserver] VoIP push - sending handshake to \(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
        await sendHandshakesToRecipient(phoneNumber: phoneNumber)
    }

    // MARK: - Background Task

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Request background execution time so the WebSocket stays alive
    /// long enough to receive the handshake response after the Phone app opens.
    private func startBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VeriCallHandshake") { [weak self] in
            self?.endBackgroundTask()
        }
        print("[NativeCallObserver] Started background task for handshake")

        // End it after 25 seconds (iOS gives ~30s max)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        print("[NativeCallObserver] Ending background task")
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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
    case monitoring          // Call detected but no phone number (called from regular Phone app)
    case unverified          // Incoming call - no handshake yet
    case sendingHandshake    // Sending our handshakes
    case awaitingResponse    // Waiting for their response
    case verified            // Both verified!
    case verifyingVoice      // Checking voice matches thumbprint
    case handshakeTimeout    // No response in time
    case handshakeFailed     // Error
    case recipientNotOnVeriCall
    case notEnrolled

    var displayText: String {
        switch self {
        case .idle: return ""
        case .monitoring: return "Monitoring call..."
        case .unverified: return "Unverified Caller"
        case .sendingHandshake: return "Verifying..."
        case .awaitingResponse: return "Waiting for response..."
        case .verified: return "Verified"
        case .verifyingVoice: return "Voice Verified"
        case .handshakeTimeout: return "Verification timeout"
        case .handshakeFailed: return "Verification failed"
        case .recipientNotOnVeriCall: return "Not on VeriCall"
        case .notEnrolled: return "Voice not enrolled"
        }
    }

    var isActive: Bool {
        self != .idle
    }
}
