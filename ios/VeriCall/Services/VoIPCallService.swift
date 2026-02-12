import Foundation
import AVFoundation
import Accelerate
import Combine

/// Manages the full lifecycle of a VoIP call:
/// initiate -> ring -> answer -> connected (with voice verification) -> end.
///
/// Integrates:
///  - AudioStreamService - mic capture & playback via WebSocket relay
///  - WebSocketService - signaling relay
///  - LocalVoiceVerifier - voice verification against thumbprint
@MainActor
final class VoIPCallService: ObservableObject {

    static let shared = VoIPCallService()

    // MARK: - Published state
    @Published var callState: VoIPCallState = .idle
    @Published var currentCall: VoIPCall?
    @Published var voiceMatchPercentage: Double?
    @Published var isDeviceVerified: Bool = false
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var callDuration: TimeInterval = 0

    // MARK: - Services
    private let audioStream = AudioStreamService.shared
    private let ws = WebSocketService.shared
    private let verifier = LocalVoiceVerifier()
    private let keychainService = VoiceKeychainService()

    // MARK: - Voice verification
    private var receivedThumbprint: [Float]?
    private var verificationTimer: Timer?
    private var recentScores: [Float] = []

    // MARK: - Call timer
    private var durationTimer: Timer?

    private init() {
        setupCallbacks()
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
        isDeviceVerified = contact.isVerified
        voiceMatchPercentage = nil
        receivedThumbprint = nil

        // Load our own voice thumbprint to send
        let ourThumbprint = loadOurThumbprint()

        // Setup audio but don't start streaming yet (wait for answer)
        audioStream.setup()

        do {
            // Send call initiation via WebSocket
            try await ws.sendRaw(message: [
                "type": "voip:initiate",
                "callId": callId,
                "toPhone": contact.phoneNumber ?? "",
                "toUserId": contact.id,
                "voiceThumbprint": ourThumbprint ?? [] as [Float],
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
        callerName: String,
        voiceThumbprint: [Float]?
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
        receivedThumbprint = voiceThumbprint
        isDeviceVerified = voiceThumbprint != nil

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

        // Load our own thumbprint to send back
        let ourThumbprint = loadOurThumbprint()

        // Setup and start audio streaming
        audioStream.setup()

        do {
            // Send answer back
            try await ws.sendRaw(message: [
                "type": "voip:answer",
                "callId": call.id,
                "toUserId": call.remoteUserId,
                "voiceThumbprint": ourThumbprint ?? [] as [Float]
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
        stopVerification()
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
            var thumbprint: [Float]? = nil
            if let arr = json["voiceThumbprint"] as? [Double], !arr.isEmpty {
                thumbprint = arr.map { Float($0) }
            } else if let arr = json["voiceThumbprint"] as? [NSNumber], !arr.isEmpty {
                thumbprint = arr.map { Float(truncating: $0) }
            }
            handleIncomingCall(
                callId: callId,
                fromUserId: fromUserId,
                callerName: callerName,
                voiceThumbprint: thumbprint
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
            stopVerification()
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
        // When initiating, we set remoteUserId = contact.id (CNContact
        // identifier), which is a local address-book UUID - not a backend
        // user ID.  The backend attaches its own fromUserId (the real
        // backend UUID of the answering user) to every forwarded message.
        if let realUserId = json["fromUserId"] as? String {
            currentCall?.remoteUserId = realUserId
            // CRITICAL: Also update the cached ID in AudioStreamService
            // so audio packets are sent to the correct backend user ID
            audioStream.updateRemoteUserId(realUserId)
            print("[VoIPCall] Updated remoteUserId to backend ID: \(realUserId)")
        }

        // Capture their thumbprint if sent with the answer
        if let arr = json["voiceThumbprint"] as? [Double], !arr.isEmpty {
            receivedThumbprint = arr.map { Float($0) }
            isDeviceVerified = true
        } else if let arr = json["voiceThumbprint"] as? [NSNumber], !arr.isEmpty {
            receivedThumbprint = arr.map { Float(truncating: $0) }
            isDeviceVerified = true
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

        // Start verification after a short delay to accumulate audio
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startVerification()
        }

        print("[VoIPCall] Audio connected - call is live!")
    }

    // MARK: - Voice Verification

    private func startVerification() {
        guard receivedThumbprint != nil else {
            print("[VoIPCall] No thumbprint - skipping voice verification")
            return
        }

        // Verify every 4 seconds using REMOTE audio
        verificationTimer?.invalidate()
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.performVerification()
        }

        print("[VoIPCall] Voice verification started - will check every 4s")
    }

    /// Dedicated background queue for heavy voice feature extraction
    /// (LPC formants + covariance computation takes ~1.7s)
    private let verificationQueue = DispatchQueue(label: "com.vericall.verification", qos: .userInitiated)

    private func performVerification() {
        guard let thumbprint = receivedThumbprint else { return }

        // Thread-safe copy of remote audio buffer
        let remoteAudio: [Float] = audioStream.remoteQueue.sync {
            return audioStream.remoteBuffer
        }

        let minSamples = Int(5.0 * AudioConfiguration.sampleRate)
        guard remoteAudio.count >= minSamples else {
            print("[VoIPCall] Waiting for remote audio (\(remoteAudio.count)/\(minSamples) samples)")
            return
        }

        // Use most recent 7 seconds for best accuracy
        let targetSamples = Int(7.0 * AudioConfiguration.sampleRate)
        let chunk = Array(remoteAudio.suffix(min(targetSamples, remoteAudio.count)))

        // Pre-check: ensure the chunk has enough energy (not silence)
        var rms: Float = 0
        vDSP_measqv(chunk, 1, &rms, vDSP_Length(chunk.count))
        rms = sqrt(rms)
        guard rms > 0.003 else {
            print("[VoIPCall] Remote audio too quiet (RMS: \(String(format: "%.4f", rms))) - skipping")
            return
        }

        let signature = VoiceSignature(
            vector: thumbprint,
            contactId: "remote",
            phraseCount: 5
        )

        // Run heavy computation on background thread to avoid blocking UI
        verificationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.verifier.verify(audioData: chunk, against: signature)
            let score = result.similarity

            // Discard garbage scores from silence or noise
            // Threshold lowered from 0.15 to 0.05: per-group scoring produces
            // lower scores for different speakers (can be as low as 1.8%)
            guard score > 0.05 else {
                print("[VoIPCall] Score too low (\(Int(score * 100))%) - likely silence, skipping")
                return
            }

            // Update UI on main thread
            Task { @MainActor in
                // Weighted moving average - newer scores count more
                self.recentScores.append(score)
                if self.recentScores.count > 8 { self.recentScores.removeFirst() }

                var weightedSum: Float = 0
                var weightTotal: Float = 0
                for (i, s) in self.recentScores.enumerated() {
                    let w = Float(i + 1)
                    weightedSum += s * w
                    weightTotal += w
                }
                let smoothed = weightedSum / weightTotal

                self.voiceMatchPercentage = Double(smoothed * 100)
                print("[VoIPCall] Voice match: \(Int(smoothed * 100))% (raw: \(Int(score * 100))%, rms: \(String(format: "%.4f", rms)), n=\(self.recentScores.count))")
            }
        }
    }

    private func stopVerification() {
        verificationTimer?.invalidate()
        verificationTimer = nil
        recentScores.removeAll()
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
        voiceMatchPercentage = nil
        isDeviceVerified = false
        isMuted = false
        isSpeakerOn = false
        callDuration = 0
        receivedThumbprint = nil
        stopVerification()
        stopDurationTimer()
    }

    // MARK: - Helpers

    private var currentUserId: String {
        UserDefaults.standard.string(forKey: "userId") ?? "unknown"
    }

    private func loadOurThumbprint() -> [Float]? {
        guard let sig = try? keychainService.loadSignature(for: "self") else {
            return nil
        }
        return sig.vector
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
