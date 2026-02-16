import Foundation
import AVFoundation
import Accelerate
import Combine
import UIKit

/// Manages the full lifecycle of a VoIP call with HYBRID architecture:
///
/// RTP Path (Ultra-Low Latency): Phone-to-phone conversation
///   - RTPAudioService handles human voice conversation
///   - 5ms buffers, UDP, Opus encoding
///   - Directly plays to speaker for instant response
///
/// MoQ Path (AI Analysis): Parallel stream to AI backend
///   - AudioStreamService (MoQ/QUIC) sends audio to AI
///   - Slightly higher latency acceptable for deepfake detection
///   - Does NOT play through speaker - only analyzed
///
/// Architecture:
///   Mic -> [Split] -> RTP -> Other Phone (speaker)
///              |
///              +----> MoQ -> AI Analysis (no playback)
///
/// Integrates:
///  - RTPAudioService - Real-time phone conversation (ultra-low latency)
///  - AudioStreamService - MoQ-based AI analysis stream
///  - WebSocketService - signaling relay
///  - DeepfakeDetectionService - real-time AI detection
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
    // RTP: Ultra-low latency phone conversation (plays through speaker)
    private let rtpAudio = RTPAudioService.shared
    // MoQ: AI analysis path (parallel, does not play)
    private let moqAudio = AudioStreamService.shared
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
    
    // MARK: - Computed Properties
    
    private var myDeviceName: String {
        UserDefaults.standard.string(forKey: "userName") ?? UIDevice.current.name
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
            remoteDeviceName: nil, // Will be filled on answer
            remoteIp: nil,
            remotePort: nil,
            direction: .outgoing
        )

        currentCall = call
        callState = .calling
        deepfakeResult = nil

        // Setup BOTH audio paths:
        // RTP: For ultra-low latency phone conversation
        rtpAudio.startListening()
        // MoQ: For AI analysis (parallel path, doesn't play through speaker)
        moqAudio.setup()

        do {
            // Send call initiation with BOTH ports
            // RTP port for phone conversation, MoQ port for AI
            try await ws.sendRaw(message: [
                "type": "voip:initiate",
                "callId": callId,
                "toPhone": contact.phoneNumber ?? "",
                "toUserId": contact.id,
                "callerName": UserDefaults.standard.string(forKey: "userName") ?? "Unknown",
                "deviceName": myDeviceName,
                "rtpPort": rtpAudio.currentLocalPort ?? 5004,
                "moqPort": moqAudio.transport.localPort ?? 0,
                "listenerPort": rtpAudio.currentLocalPort ?? 5004  // Backward compat
            ])

            print("[VoIPCall] Sent call to \(contact.displayName) (my device: \(myDeviceName))")

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
        callerDeviceName: String?,
        callerIp: String? = nil,
        callerPort: UInt16? = nil
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
            remoteDeviceName: callerDeviceName,
            remoteIp: nil, // Will be filled from signaling if available, but initiate captures it
            remotePort: nil,
            direction: .incoming
        )
        // Store IP/Port if passed in (custom init or modifying below)
        var mutableCall = call
        mutableCall.remoteIp = callerIp
        mutableCall.remotePort = callerPort
        
        currentCall = mutableCall
        callState = .ringing

        print("[VoIPCall] Incoming call from \(callerName) (device: \(callerDeviceName ?? "unknown"))")
    }

    // MARK: - Answer

    func answerCall() async {
        guard callState == .ringing,
              let call = currentCall else {
            print("[VoIPCall] No ringing call to answer")
            return
        }

        callState = .connecting

        // Setup BOTH audio paths:
        // RTP: Ultra-low latency phone conversation
        rtpAudio.startListening()
        // MoQ: AI analysis (parallel path)
        moqAudio.setup()

        do {
            // Send answer back with BOTH ports
            try await ws.sendRaw(message: [
                "type": "voip:answer",
                "callId": call.id,
                "toUserId": call.remoteUserId,
                "deviceName": myDeviceName,
                "rtpPort": rtpAudio.currentLocalPort ?? 5004,
                "moqPort": moqAudio.transport.localPort ?? 0,
                "listenerPort": rtpAudio.currentLocalPort ?? 5004  // Backward compat
            ])

            // RTP: Connect for phone conversation (ultra-low latency)
            if let remoteDevice = call.remoteDeviceName {
                print("[VoIPCall] RTP: Connecting to \(remoteDevice)")
                rtpAudio.connectToPeer(deviceName: remoteDevice)
            }
            if let ip = call.remoteIp, let port = call.remotePort, port > 0 {
                print("[VoIPCall] RTP: Connecting to \(ip):\(port)")
                rtpAudio.connectToPeer(host: ip, port: port)
            }
            
            // MoQ: Connect for AI analysis (parallel, doesn't affect latency)
            if let remoteDevice = call.remoteDeviceName {
                print("[VoIPCall] MoQ: Connecting to \(remoteDevice)")
                moqAudio.connectToPeer(callerName: remoteDevice)
            }
            if let ip = call.remoteIp, let port = call.remotePort, port > 0 {
                moqAudio.connectToPeer(host: ip, port: port)
            }
            
            // Start BOTH streams:
            // RTP: Plays through speaker immediately (ultra-low latency)
            rtpAudio.startStreaming()
            // MoQ: Sends to AI for analysis (parallel, no playback)
            moqAudio.startStreaming()

            print("[VoIPCall] Call answered - RTP (voice) + MoQ (AI) active")

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
        guard let callData = currentCall else { return }

        Task {
            try? await ws.sendRaw(message: [
                "type": "voip:reject",
                "callId": callData.id,
                "toUserId": callData.remoteUserId,
                "reason": "declined"
            ])
            
            let finishedCall = Call(
                id: callData.id,
                callerId: callData.direction == .incoming ? callData.remoteUserId : "me",
                callerName: callData.direction == .incoming ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                recipientId: callData.direction == .outgoing ? callData.remoteUserId : "me",
                recipientName: callData.direction == .outgoing ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                direction: callData.direction,
                state: .declined,
                startedAt: Date(),
                endedAt: Date(),
                isVerified: true
            )
            await StorageService.shared.saveCall(finishedCall)
        }

        resetCall()
    }

    // MARK: - End call

    func endCall() {
        guard let callData = currentCall else { return }

        Task {
            try? await ws.sendRaw(message: [
                "type": "voip:end",
                "callId": callData.id,
                "toUserId": callData.remoteUserId
            ])
            
            let finishedCall = Call(
                id: callData.id,
                callerId: callData.direction == .incoming ? callData.remoteUserId : "me",
                callerName: callData.direction == .incoming ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                recipientId: callData.direction == .outgoing ? callData.remoteUserId : "me",
                recipientName: callData.direction == .outgoing ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                direction: callData.direction,
                state: callState == .ringing ? .missed : .ended,
                startedAt: Date().addingTimeInterval(-callDuration),
                endedAt: Date(),
                isVerified: true
            )
            await StorageService.shared.saveCall(finishedCall)
        }

        callState = .ended
        deepfakeDetection.stopDetection()
        // Stop BOTH audio paths
        rtpAudio.disconnect()  // RTP: Phone conversation
        moqAudio.tearDown()    // MoQ: AI analysis
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
            let deviceName = json["deviceName"] as? String
            
            handleIncomingCall(
                callId: callId,
                fromUserId: fromUserId,
                callerName: callerName,
                callerDeviceName: deviceName,
                callerIp: json["senderIp"] as? String,
                callerPort: json["listenerPort"] as? UInt16
            )

        case "voip:answer":
            handleRemoteAnswer(json)

        case "voip:audio":
            // NO-OP: MoQ handles audio directly.
            // Ignore legacy WebSocket audio packets.
            break

        case "voip:reject":
            let reason = json["reason"] as? String ?? "rejected"
            print("[VoIPCall] Call rejected: \(reason)")
            
            if let callData = currentCall {
                Task {
                    let finishedCall = Call(
                        id: callData.id,
                        callerId: callData.direction == .incoming ? callData.remoteUserId : "me",
                        callerName: callData.direction == .incoming ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                        recipientId: callData.direction == .outgoing ? callData.remoteUserId : "me",
                        recipientName: callData.direction == .outgoing ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                        direction: callData.direction,
                        state: reason == "declined" ? .declined : .failed,
                        startedAt: Date(),
                        endedAt: Date(),
                        isVerified: true
                    )
                    await StorageService.shared.saveCall(finishedCall)
                }
            }
            
            callState = .ended
            // Stop BOTH audio paths
            rtpAudio.disconnect()  // RTP: Phone conversation
            moqAudio.tearDown()    // MoQ: AI analysis
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.resetCall()
            }

        case "voip:end":
            print("[VoIPCall] Remote ended call")
            
            if let callData = currentCall {
                let currentState = callState // Capture state before it changes
                Task {
                    let finishedCall = Call(
                        id: callData.id,
                        callerId: callData.direction == .incoming ? callData.remoteUserId : "me",
                        callerName: callData.direction == .incoming ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                        recipientId: callData.direction == .outgoing ? callData.remoteUserId : "me",
                        recipientName: callData.direction == .outgoing ? callData.remoteName : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
                        direction: callData.direction,
                        state: (currentState == .ringing || currentState == .calling) ? .missed : .ended,
                        startedAt: Date().addingTimeInterval(-callDuration),
                        endedAt: Date(),
                        isVerified: true
                    )
                    await StorageService.shared.saveCall(finishedCall)
                }
            }
            
            callState = .ended
            deepfakeDetection.stopDetection()
            // Stop BOTH audio paths
            rtpAudio.disconnect()  // RTP: Phone conversation
            moqAudio.tearDown()    // MoQ: AI analysis
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
        // Mute affects BOTH paths (RTP + MoQ)
        rtpAudio.isMuted = isMuted
        moqAudio.isMuted = isMuted
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        // Speaker only affects RTP (phone conversation)
        rtpAudio.isSpeakerOn = isSpeakerOn
    }

    // MARK: - Private helpers

    private func handleRemoteAnswer(_ json: [String: Any]) {
        // Update remoteUserId to the REAL backend user ID.
        if let realUserId = json["fromUserId"] as? String {
            currentCall?.remoteUserId = realUserId
            print("[VoIPCall] Updated remoteUserId to backend ID: \(realUserId)")
        }
        
        // Connect BOTH audio paths
        // RTP: Phone conversation (ultra-low latency)
        if let deviceName = json["deviceName"] as? String {
            currentCall?.remoteDeviceName = deviceName
            rtpAudio.connectToPeer(deviceName: deviceName)
            print("[VoIPCall] RTP: Connecting to \(deviceName)")
        }
        
        // MoQ: AI analysis (parallel)
        if let deviceName = json["deviceName"] as? String {
            moqAudio.connectToPeer(callerName: deviceName)
            print("[VoIPCall] MoQ: Connecting to \(deviceName)")
        }

        // [WAN P2P] Connect via Direct IP if available
        if let ip = json["senderIp"] as? String {
            // RTP port for phone conversation
            if let rtpPort = json["rtpPort"] as? UInt16, rtpPort > 0 {
                print("[VoIPCall] RTP: Connecting to \(ip):\(rtpPort)")
                rtpAudio.connectToPeer(host: ip, port: rtpPort)
            } else if let port = json["listenerPort"] as? UInt16, port > 0 {
                // Backward compat
                print("[VoIPCall] RTP: Connecting to \(ip):\(port)")
                rtpAudio.connectToPeer(host: ip, port: port)
            }
            // MoQ port for AI
            if let moqPort = json["moqPort"] as? UInt16, moqPort > 0 {
                print("[VoIPCall] MoQ: Connecting to \(ip):\(moqPort)")
                moqAudio.connectToPeer(host: ip, port: moqPort)
            }
        }

        // Start BOTH streams:
        // RTP: Ultra-low latency phone conversation (plays through speaker)
        rtpAudio.startStreaming()
        // MoQ: AI analysis (parallel, no playback)
        moqAudio.startStreaming()
        
        print("[VoIPCall] Remote answered - RTP (voice) + MoQ (AI) active")
    }

    private func setupCallbacks() {
        // RTP callback: When phone conversation audio connects (ultra-low latency)
        rtpAudio.onConnected = { [weak self] in
            Task { @MainActor in
                self?.onRTPConnected()
            }
        }
        
        // MoQ callback: When AI analysis stream connects
        moqAudio.onAudioConnected = { [weak self] in
            Task { @MainActor in
                self?.onMoQConnected()
            }
        }
    }
    
    /// Called when RTP (phone conversation) connects - ultra-low latency path
    private func onRTPConnected() {
        print("[VoIPCall] RTP Connected - phone conversation active!")
        // If MoQ is not yet connected, we're still in 'connecting' state
        // but the user can already talk (RTP is active)
        if callState == .calling {
            callState = .connecting
        }
    }
    
    /// Called when MoQ (AI analysis) connects - parallel path
    private func onMoQConnected() {
        guard callState == .connecting || callState == .calling else { return }
        
        callState = .connected
        startDurationTimer()
        
        // Start AI deepfake detection on the incoming audio
        deepfakeDetection.startDetection()
        
        print("[VoIPCall] MoQ Connected - AI deepfake detection active!")
    }

    /// Called when audio is flowing in both directions.
    private func onAudioConnected() {
        guard callState == .connecting || callState == .calling else { return }
        
        callState = .connected
        startDurationTimer()

        // Start AI deepfake detection on the incoming audio
        deepfakeDetection.startDetection()

        print("[VoIPCall] MoQ Connected - AI deepfake detection active!")
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
        // Clean up both audio services
        rtpAudio.disconnect()
        moqAudio.tearDown()
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
    var remoteDeviceName: String? // Bonjour service name for P2P
    var remoteIp: String?         // WAN IP for P2P
    var remotePort: UInt16?       // WAN Port for P2P
    let direction: CallDirection

    static func == (lhs: VoIPCall, rhs: VoIPCall) -> Bool {
        lhs.id == rhs.id
    }
}
