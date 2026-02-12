import Foundation
import UIKit
import CallKit
import Combine

/// Observes native phone calls and triggers VeriCall device verification.
///
/// - Incoming calls: Show "Unverified" immediately, update to "Verified" if handshake received
/// - Outgoing calls: Send handshakes to recipient's VeriCall account
///
/// Device handshakes prove both parties have VeriCall installed.
/// Audio-based deepfake detection is only available during VoIP calls
/// (iOS locks audio hardware during native carrier calls).
@MainActor
class NativeCallObserver: NSObject, ObservableObject {
    static let shared = NativeCallObserver()

    // MARK: - Published State
    @Published var isInNativeCall = false
    @Published var currentCallPhoneNumber: String?
    @Published var currentCallUUID: UUID?
    @Published var verificationStatus: NativeCallVerificationStatus = .idle
    @Published var remoteUserName: String?

    // MARK: - Handshake State
    @Published var sentOurHandshake = false
    @Published var receivedTheirHandshake = false

    // MARK: - Services
    private let callObserver = CXCallObserver()
    private let apiService = APIService.shared
    private let webSocketService = WebSocketService.shared
    private let authKeychain = KeychainService.shared
    private let notificationService = NotificationService.shared

    // MARK: - State
    private var handshakeTimer: Timer?
    private var unverifiedTimer: Timer?
    private var isOutgoingCall = false

    /// Buffered handshake that arrived before CXCallObserver fired.
    private var pendingHandshake: (fromUserId: String, displayName: String?, phoneNumber: String)?

    /// Whether we already sent our info to the matching pool for this call
    private var sentToMatchingPool = false

    // MARK: - Initialization
    private override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        print("[NativeCallObserver] Initialized - monitoring native phone calls")
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

        startBackgroundTask()

        if !webSocketService.connectionStatus.isConnected {
            webSocketService.connect()
        }

        // Check for a buffered handshake that arrived early
        if let pending = pendingHandshake {
            print("[NativeCallObserver] Replaying buffered handshake from \(pending.displayName ?? pending.fromUserId)")
            pendingHandshake = nil
            await handleReceivedHandshake(
                fromUserId: pending.fromUserId,
                displayName: pending.displayName,
                phoneNumber: pending.phoneNumber
            )
            return
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

        // Send ourselves to the matching pool as a fallback
        await sendToMatchingPool(direction: "incoming")

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

        if sentOurHandshake {
            print("[NativeCallObserver] Handshake already sent before call - skipping")

            if let pending = pendingHandshake {
                print("[NativeCallObserver] Replaying buffered handshake response")
                pendingHandshake = nil
                await handleReceivedHandshake(
                    fromUserId: pending.fromUserId,
                    displayName: pending.displayName,
                    phoneNumber: pending.phoneNumber
                )
            }
            return
        }

        if currentCallPhoneNumber == nil {
            print("[NativeCallObserver] Call made outside VeriCall - monitoring for handshakes")
            verificationStatus = .monitoring
            await sendToMatchingPool(direction: "outgoing")
        }
    }

    /// Send device handshake to the recipient's VeriCall account
    private func sendHandshakesToRecipient(phoneNumber: String) async {
        print("[NativeCallObserver] OUTGOING CALL - Sending handshake to \(phoneNumber)")

        // Get access token
        guard let accessToken = try? await authKeychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        ) else {
            print("[NativeCallObserver] No access token - not logged in")
            verificationStatus = .handshakeFailed
            return
        }

        // Make sure WebSocket is connected
        if !webSocketService.connectionStatus.isConnected {
            print("[NativeCallObserver] WebSocket not connected - connecting...")
            webSocketService.connect()
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

        // Look up if recipient has a VeriCall account
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

            // Send device handshake (no voiceprint)
            let handshake: [String: Any] = [
                "type": "native_call:handshake",
                "recipientId": recipientUserId,
                "phoneNumber": phoneNumber,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "callDirection": "outgoing"
            ]

            try await webSocketService.sendRaw(message: handshake)
            print("[NativeCallObserver] SENT device handshake to recipient")

            sentOurHandshake = true
            verificationStatus = .awaitingResponse

            // Also send to the matching pool as a fallback
            await sendToMatchingPool(direction: "outgoing")

            startHandshakeTimeout()

        } catch {
            print("[NativeCallObserver] Handshake failed: \(error)")
            verificationStatus = .handshakeFailed
        }
    }

    // MARK: - Matching Pool Fallback

    private func sendToMatchingPool(direction: String) async {
        guard !sentToMatchingPool else { return }

        guard webSocketService.connectionStatus.isConnected else {
            print("[NativeCallObserver] WebSocket not connected - can't send to matching pool")
            return
        }

        do {
            let poolMessage: [String: Any] = [
                "type": "native_call:in_call",
                "direction": direction,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            try await webSocketService.sendRaw(message: poolMessage)
            sentToMatchingPool = true
            print("[NativeCallObserver] Sent to matching pool (\(direction))")
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

    // MARK: - RECEIVING HANDSHAKES

    /// Called when we receive a handshake from the other party.
    /// This proves the other party has VeriCall installed (device verification).
    func handleReceivedHandshake(
        fromUserId: String,
        displayName: String?,
        phoneNumber: String
    ) async {
        print("[NativeCallObserver] RECEIVED HANDSHAKE from \(displayName ?? fromUserId)")

        // Buffer if we are not in a call yet
        if !isInNativeCall && verificationStatus == .idle {
            print("[NativeCallObserver] Not in a call yet - buffering handshake for replay")
            pendingHandshake = (fromUserId, displayName, phoneNumber)

            // Pre-show the verified notification
            verificationStatus = .verified
            remoteUserName = displayName ?? phoneNumber
            receivedTheirHandshake = true
            currentCallPhoneNumber = phoneNumber

            await notificationService.showCallVerificationNotification(
                callerName: displayName ?? phoneNumber,
                callerId: fromUserId,
                isDeviceVerified: true,
                hasVoiceThumbprint: false
            )
            print("[NativeCallObserver] Pre-verified! Notification shown before call rings")
            return
        }

        // Cancel unverified timer
        unverifiedTimer?.invalidate()

        receivedTheirHandshake = true
        remoteUserName = displayName ?? phoneNumber
        currentCallPhoneNumber = phoneNumber

        // UPDATE STATUS TO VERIFIED
        verificationStatus = .verified
        print("[NativeCallObserver] VERIFIED! Other party has VeriCall")

        // Show VERIFIED notification
        await notificationService.showCallVerificationNotification(
            callerName: displayName ?? phoneNumber,
            callerId: fromUserId,
            isDeviceVerified: true,
            hasVoiceThumbprint: false
        )

        // Send OUR handshake back so they can verify us too
        if !sentOurHandshake {
            print("[NativeCallObserver] Sending our handshake back...")
            await sendHandshakeResponse(to: fromUserId)
        }
    }

    /// Called when the other party requests our device handshake
    func handleHandshakeRequest(fromUserId: String, phoneNumber: String) async {
        print("[NativeCallObserver] Received handshake request")
        await sendHandshakeResponse(to: fromUserId)
    }

    private func sendHandshakeResponse(to userId: String) async {
        // Make sure WebSocket is connected
        if !webSocketService.connectionStatus.isConnected {
            print("[NativeCallObserver] WebSocket not connected - connecting...")
            webSocketService.connect()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        do {
            let response: [String: Any] = [
                "type": "native_call:handshake_response",
                "recipientId": userId,
                "phoneNumber": currentCallPhoneNumber ?? "",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]

            try await webSocketService.sendRaw(message: response)
            print("[NativeCallObserver] Sent our handshake response to \(userId)")
            sentOurHandshake = true
        } catch {
            print("[NativeCallObserver] Failed to send response: \(error)")
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

        if verificationStatus == .verified {
            print("[NativeCallObserver] Call connected - verified via device handshake")
        }
    }

    private func handleCallEnded(call: CXCall) {
        print("[NativeCallObserver] Call ended")

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

        startBackgroundTask()

        // Give a moment for the response to arrive before opening Phone app
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Call this when user initiates an outgoing call through your app
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

    private func startBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VeriCallHandshake") { [weak self] in
            self?.endBackgroundTask()
        }
        print("[NativeCallObserver] Started background task for handshake")

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
    case monitoring          // Call detected but no phone number
    case unverified          // Incoming call - no handshake yet
    case sendingHandshake    // Sending our handshake
    case awaitingResponse    // Waiting for their response
    case verified            // Both verified via device handshake
    case handshakeTimeout    // No response in time
    case handshakeFailed     // Error
    case recipientNotOnVeriCall

    var displayText: String {
        switch self {
        case .idle: return ""
        case .monitoring: return "Monitoring call..."
        case .unverified: return "Unverified Caller"
        case .sendingHandshake: return "Verifying..."
        case .awaitingResponse: return "Waiting for response..."
        case .verified: return "VeriCall Verified"
        case .handshakeTimeout: return "Verification timeout"
        case .handshakeFailed: return "Verification failed"
        case .recipientNotOnVeriCall: return "Not on VeriCall"
        }
    }

    var isActive: Bool {
        self != .idle
    }
}
