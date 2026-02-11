import Foundation
import Combine

// MARK: - Call Manager
@MainActor
class CallManager: ObservableObject {
    static let shared = CallManager()
    
    @Published var currentCall: Call?
    @Published var isInCall: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private let webSocketService = WebSocketService.shared
    private let callKitManager = CallKitManager.shared
    private let callSignaling = CallSignaling.shared
    private let voiceVerificationService = VoiceVerificationService()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        webSocketService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)
        
        // Listen for incoming call signals
        Task {
            await listenForIncomingCalls()
        }
    }
    
    private func listenForIncomingCalls() async {
        for await signal in webSocketService.incomingSignals {
            await handleIncomingSignal(signal)
        }
    }
    
    private func handleIncomingSignal(_ signal: CallSignal) async {
        switch signal.type {
        case .initiate, .offer:
            await handleIncomingCall(signal)
        case .answer:
            await handleCallAnswered(signal)
        case .end:
            await handleCallEnded(signal)
        case .voiceMatchUpdate:
            await handleVoiceMatchUpdate(signal)
        default:
            break
        }
    }
    
    // MARK: - Outgoing Call
    func initiateCall(to contact: Contact) async throws {
        guard currentCall == nil else {
            throw CallError.invalidState
        }
        
        guard connectionStatus.isConnected else {
            throw CallError.webSocketDisconnected
        }
        
        // Generate call ID
        let callId = UUID().uuidString
        
        // Create call object
        let call = Call(
            id: callId,
            callerId: "current_user_id", // TODO: Get from auth
            callerName: "Me",
            recipientId: contact.id,
            recipientName: contact.name,
            direction: .outgoing,
            state: .dialing,
            startedAt: Date(),
            endedAt: nil,
            isVerified: contact.isVerified,
            voiceMatchPercentage: nil
        )
        
        await MainActor.run {
            self.currentCall = call
            self.isInCall = true
        }
        
        do {
            // Sign and send call initiation
            let signal = try await callSignaling.createInitiateSignal(
                callId: callId,
                toUserId: contact.id,
                isVerified: contact.isVerified
            )
            
            try await webSocketService.sendSignal(signal)
            
            // Update call state
            await updateCallState(.ringing)
            
            // Report to CallKit
            await callKitManager.reportOutgoingCall(call: call)
            
        } catch {
            try? await endCall()
            throw error
        }
    }
    
    // MARK: - Incoming Call
    private func handleIncomingCall(_ signal: CallSignal) async {
        guard currentCall == nil else {
            // Already in a call, reject
            let rejectSignal = await callSignaling.createRejectSignal(
                callId: signal.callId,
                toUserId: signal.fromUserId,
                reason: "busy"
            )
            try? await webSocketService.sendSignal(rejectSignal)
            return
        }
        
        // Verify signature if present
        let isVerified = signal.signature != nil ? 
            await callSignaling.verifySignal(signal) : false
        
        // Extract voice thumbprint from incoming signal (for caller verification)
        let receivedVoiceThumbprint = signal.voiceThumbprint
        
        let call = Call(
            id: signal.callId,
            callerId: signal.fromUserId,
            callerName: "Unknown", // TODO: Look up from contacts
            recipientId: signal.toUserId,
            recipientName: "Me",
            direction: .incoming,
            state: .ringing,
            startedAt: nil,
            endedAt: nil,
            isVerified: isVerified,
            voiceMatchPercentage: nil,
            voiceThumbprint: receivedVoiceThumbprint
        )
        
        await MainActor.run {
            self.currentCall = call
            self.isInCall = true
        }
        
        // Show verification notification (appears on lock screen)
        await NotificationService.shared.showCallVerificationNotification(
            callerName: call.callerName,
            callerId: call.callerId,
            isDeviceVerified: isVerified,
            hasVoiceThumbprint: receivedVoiceThumbprint != nil
        )
        // Report to CallKit for native UI
        await callKitManager.reportIncomingCall(call: call) { accepted in
            if accepted {
                Task {
                    NotificationService.shared.removeCallNotification(for: call.callerId)
                    try? await self.acceptCall(call)
                }
            } else {
                Task {
                    NotificationService.shared.removeCallNotification(for: call.callerId)
                    try? await self.declineCall(call)
                }
            }
        }
    }
    
    // MARK: - Accept/Decline
    func acceptCall(_ call: Call) async throws {
        guard let currentCall = currentCall, currentCall.id == call.id else {
            throw CallError.invalidState
        }
        
        let acceptSignal = try await callSignaling.createAcceptSignal(
            callId: call.id,
            toUserId: call.callerId
        )
        
        try await webSocketService.sendSignal(acceptSignal)
        await updateCallState(.connecting)
        
        // Start voice verification if we have the caller's thumbprint
        if let voiceThumbprint = call.voiceThumbprint {
            print("[CallManager] Starting voice verification with received thumbprint")
            try? await voiceVerificationService.startVerification(withExternalThumbprint: voiceThumbprint)
        }
        
        // Simulate connection delay
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await updateCallState(.connected)
        
        await callKitManager.reportCallConnected(callId: call.id)
    }
    
    func declineCall(_ call: Call) async throws {
        guard let currentCall = currentCall, currentCall.id == call.id else {
            throw CallError.invalidState
        }
        
        // Stop voice verification if it was started
        voiceVerificationService.stopVerification()
        
        let rejectSignal = await callSignaling.createRejectSignal(
            callId: call.id,
            toUserId: call.callerId,
            reason: "declined"
        )
        
        try await webSocketService.sendSignal(rejectSignal)
        await updateCallState(.declined)
        try await endCall()
    }
    
    // MARK: - Handle Answers
    private func handleCallAnswered(_ signal: CallSignal) async {
        await updateCallState(.connecting)
        
        // Simulate connection delay
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await updateCallState(.connected)
    }
    
    // MARK: - Call Controls
    func setMute(_ muted: Bool) async throws {
        let signalType: CallSignalType = muted ? .mute : .unmute
        
        guard let call = currentCall else {
            throw CallError.invalidState
        }
        
        let signal = CallSignal(
            type: signalType,
            callId: call.id,
            fromUserId: "current_user_id",
            toUserId: call.direction == .incoming ? call.callerId : call.recipientId,
            timestamp: Date(),
            payload: CallSignalPayload(isMuted: muted),
            signature: nil,
            voiceThumbprint: nil
        )

        try await webSocketService.sendSignal(signal)
    }

    func setSpeaker(_ enabled: Bool) async throws {
        // This would configure audio session
        // For now, just a placeholder
    }

    func holdCall() async throws {
        guard let call = currentCall else {
            throw CallError.invalidState
        }

        let signal = CallSignal(
            type: .hold,
            callId: call.id,
            fromUserId: "current_user_id",
            toUserId: call.direction == .incoming ? call.callerId : call.recipientId,
            timestamp: Date(),
            payload: CallSignalPayload(),
            signature: nil,
            voiceThumbprint: nil
        )

        try await webSocketService.sendSignal(signal)
        await updateCallState(.held)
    }

    func resumeCall() async throws {
        guard let call = currentCall else {
            throw CallError.invalidState
        }

        let signal = CallSignal(
            type: .resume,
            callId: call.id,
            fromUserId: "current_user_id",
            toUserId: call.direction == .incoming ? call.callerId : call.recipientId,
            timestamp: Date(),
            payload: CallSignalPayload(),
            signature: nil,
            voiceThumbprint: nil
        )
        
        try await webSocketService.sendSignal(signal)
        await updateCallState(.connected)
    }
    
    func sendDTMF(_ digit: String) async throws {
        // DTMF signaling would go here
        print("Sending DTMF: \(digit)")
    }
    
    // MARK: - End Call
    func endCall() async throws {
        guard let call = currentCall else {
            throw CallError.invalidState
        }
        
        // Stop voice verification
        voiceVerificationService.stopVerification()
        
        let endSignal = CallSignal(
            type: .end,
            callId: call.id,
            fromUserId: "current_user_id",
            toUserId: call.direction == .incoming ? call.callerId : call.recipientId,
            timestamp: Date(),
            payload: CallSignalPayload(),
            signature: nil,
            voiceThumbprint: nil
        )
        
        try? await webSocketService.sendSignal(endSignal)
        
        await handleCallEnded(endSignal)
    }
    
    private func handleCallEnded(_ signal: CallSignal) async {
        guard let call = currentCall else { return }
        
        // Stop voice verification
        voiceVerificationService.stopVerification()
        
        await MainActor.run {
            var endedCall = call
            endedCall.state = .ended
            endedCall.endedAt = Date()
            self.currentCall = endedCall
        }
        
        // Delay to show ended state
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        await MainActor.run {
            self.currentCall = nil
            self.isInCall = false
        }
        
        await callKitManager.reportCallEnded(callId: signal.callId)
    }
    
    // MARK: - Voice Match Update
    private func handleVoiceMatchUpdate(_ signal: CallSignal) async {
        guard let call = currentCall, call.id == signal.callId else { return }
        
        await MainActor.run {
            if let percentage = signal.payload.voiceMatchPercentage {
                var updatedCall = call
                updatedCall.voiceMatchPercentage = percentage
                self.currentCall = updatedCall
            }
        }
    }
    
    // MARK: - Helpers
    private func updateCallState(_ state: CallState) async {
        await MainActor.run {
            if var call = currentCall {
                call.state = state
                if state == .connected && call.startedAt == nil {
                    call.startedAt = Date()
                }
                currentCall = call
            }
        }
    }
}
