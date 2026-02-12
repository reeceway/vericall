import Foundation
import AVFoundation
import Accelerate
import Combine

/// Manages the full lifecycle of a VoIP call:
/// initiate -> ring -> answer -> connected (with AI deepfake detection) -> end.
///
/// Integrates:
///  - AudioStreamService - mic capture & playback via WebSocket relay
///  - WebSocketService - signaling relay
///  - DeepfakeDetectionService - real-time AI detection on incoming audio
@MainActor
final class VoIPCallService: ObservableObject {

    static let shared = VoIPCallService()

    // MARK: - Published state
    @Published var callState: VoIPCallState = .idle
    @Published var currentCall: VoIPCall?
    @Published var deepfakeResult: DeepfakeDetectionResult?
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var callDuration: TimeInterval = 0

    // MARK: - Services
    private let audioStream = AudioStreamService.shared
    private let ws = WebSocketService.shared
    private let deepfakeDetection = DeepfakeDetectionService.shared

    // MARK: - Call timer
    private var durationTimer: Timer?

    // MARK: - Observation
    private var deepfakeCancellable: AnyCancellable?

    private init() {
        setupCallbacks()
        // Observe deepfake detection results
        deepfakeCancellable = deepfakeDetection.$detectionResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.deepfakeResult = result
            }
    }

    // MARK: - Outgoing call

    func initiateCall(to contact: Contact) async {
        guard callState == .idle else {
            print("[VoIPCall] Already in a call")
            return
        }

        let callId = UUID().uuidString

        let call = VoIPCall(
            id: callId,
            remoteUserId: contact.id,
            remoteName: contact.displayName,
            remotePhone: contact.phoneNumber,
            direction: .outgoing
        )

        currentCall = call
        callState = .calling
        deepfakeResult = nil

        // Setup audio but don't start streaming yet (wait for answer)
        audioStream.setup()

        do {
            // Send call initiation via WebSocket (no voiceprint)
            try await ws.sendRaw(message: [
                "type": "voip:initiate",
                "callId": callId,
                "toPhone": contact.phoneNumber ?? "",
                "toUserId": contact.id,
                "callerName": UserDefaults.standard.string(forKey: "userName") ?? "Unknown"
            ])

            print("[VoIPCall] Sent call to \(contact.displayName)")

        } catch {
            print("[VoIPCall] Failed to initiate: \(error)")
            callState = .failed(error.localizedDescription)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.resetCall()
            }
        }
    }

    // MARK: - Incoming call handling

    func handleIncomingCall(
        callId: String,
        fromUserId: String,
        callerName: String
    ) {
        guard callState == .idle else {
            print("[VoIPCall] Busy - rejecting incoming call")
            Task {
                try? await ws.sendRaw(message: [
                    "type": "voip:reject",
                    "callId": callId,
                    "toUserId": fromUserId,
                    "reason": "busy"
                ])
            }
            return
        }

        let call = VoIPCall(
            id: callId,
            remoteUserId: fromUserId,
            remoteName: callerName,
            remotePhone: nil,
            direction: .incoming
        )

        currentCall = call
        callState = .ringing

        print("[VoIPCall] Incoming call from \(callerName)")
    }

    // MARK: - Answer

    func answerCall() async {
        guard callState == .ringing,
              let call = currentCall else {
            print("[VoIPCall] No ringing call to answer")
            return
        }

        callState = .connecting

        // Setup and start audio streaming
        audioStream.setup()

        do {
            // Send answer back (no voiceprint)
            try await ws.sendRaw(message: [
                "type": "voip:answer",
                "callId": call.id,
                "toUserId": call.remoteUserId
            ])

            // Start streaming audio immediately
            audioStream.startStreaming()
            onAudioConnected()

            print("[VoIPCall] Answered call, audio streaming started")

        } catch {
            print("[VoIPCall] Failed to answer: \(error)")
            callState = .failed(error.localizedDescription)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.resetCall()
            }
        }
    }

    // MARK: - Decline

    func declineCall() {
        guard let call = currentCall else { return }

        Task {
            try? await ws.sendRaw(message: [
                "type": "voip:reject",
                "callId": call.id,
                "toUserId": call.remoteUserId,
                "reason": "declined"
            ])
        }

        resetCall()
    }

    // MARK: - End call

    func endCall() {
        guard let call = currentCall else { return }

        Task {
            try? await ws.sendRaw(message: [
                "type": "voip:end",
                "callId": call.id,
                "toUserId": call.remoteUserId
            ])
        }

        callState = .ended
        deepfakeDetection.stopDetection()
        audioStream.tearDown()
        stopDurationTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.resetCall()
        }
    }

    // MARK: - Signaling message router

    /// Called from WebSocketService when a voip: message arrives.
    func handleSignalingMessage(_ json: [String: Any], type: String) {
        switch type {
        case "voip:initiate":
            let callId = json["callId"] as? String ?? UUID().uuidString
            let fromUserId = json["fromUserId"] as? String ?? "unknown"
            let callerName = json["callerName"] as? String ?? "Unknown"
            handleIncomingCall(
                callId: callId,
                fromUserId: fromUserId,
                callerName: callerName
            )

        case "voip:answer":
            handleRemoteAnswer(json)

        case "voip:audio":
            // Route audio data to AudioStreamService for playback
            if let audioData = json["audio"] as? String {
                audioStream.receiveAudioData(audioData)
            }

        case "voip:reject":
            let reason = json["reason"] as? String ?? "rejected"
            print("[VoIPCall] Call rejected: \(reason)")
            callState = .ended
            audioStream.tearDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.resetCall()
            }

        case "voip:end":
            print("[VoIPCall] Remote ended call")
            callState = .ended
            deepfakeDetection.stopDetection()
            audioStream.tearDown()
            stopDurationTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.resetCall()
            }

        default:
            print("[VoIPCall] Unknown voip message: \(type)")
        }
    }

    // MARK: - Controls

    func toggleMute() {
        isMuted.toggle()
        audioStream.setMicrophoneEnabled(!isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        audioStream.setSpeaker(isSpeakerOn)
    }

    // MARK: - Private helpers

    private func handleRemoteAnswer(_ json: [String: Any]) {
        // Update remoteUserId to the REAL backend user ID.
        if let realUserId = json["fromUserId"] as? String {
            currentCall?.remoteUserId = realUserId
            audioStream.updateRemoteUserId(realUserId)
            print("[VoIPCall] Updated remoteUserId to backend ID: \(realUserId)")
        }

        // The other side answered - start streaming audio
        audioStream.startStreaming()
        onAudioConnected()

        print("[VoIPCall] Remote answered - audio streaming started")
    }

    private func setupCallbacks() {
        // When audio from the other side first arrives, upgrade state
        audioStream.onAudioConnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.callState == .connecting || self.callState == .calling else { return }
                // Already handled in onAudioConnected
            }
        }
    }

    /// Called when audio is flowing in both directions.
    private func onAudioConnected() {
        callState = .connected
        startDurationTimer()

        // Start AI deepfake detection on the incoming audio
        deepfakeDetection.startDetection()

        print("[VoIPCall] Audio connected - AI deepfake detection active!")
    }

    // MARK: - Duration timer

    private func startDurationTimer() {
        callDuration = 0
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.callDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Reset

    private func resetCall() {
        callState = .idle
        currentCall = nil
        deepfakeResult = nil
        isMuted = false
        isSpeakerOn = false
        callDuration = 0
        deepfakeDetection.stopDetection()
        stopDurationTimer()
    }

    /// VoIP calls through VeriCall are inherently device-verified
    /// (both parties are using the app via WebSocket signaling).
    var isDeviceVerified: Bool {
        currentCall != nil && callState != .idle
    }

    var formattedDuration: String {
        let m = Int(callDuration) / 60
        let s = Int(callDuration) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - VoIP Call State
enum VoIPCallState: Equatable {
    case idle
    case calling       // outgoing, waiting for answer
    case ringing       // incoming, not yet answered
    case connecting    // answer sent/received, audio starting
    case connected     // audio flowing
    case ended
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .calling: return "Calling..."
        case .ringing: return "Incoming Call"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .ended: return "Call Ended"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .calling, .ringing, .connecting, .connected: return true
        default: return false
        }
    }
}

// MARK: - VoIP Call Model
struct VoIPCall: Identifiable, Equatable {
    let id: String
    var remoteUserId: String
    let remoteName: String
    let remotePhone: String?
    let direction: CallDirection

    static func == (lhs: VoIPCall, rhs: VoIPCall) -> Bool {
        lhs.id == rhs.id
    }
}
