# WebRTC Implementation Guide for VeriCall
## Copy & Paste This Into Claude Code

---

## THE PROBLEM

iOS CallKit does NOT allow apps to access audio from regular phone calls. This means voice verification during calls is impossible with the current implementation.

**Solution:** Replace phone calls with WebRTC in-app VoIP calls. This gives full audio stream access for real-time voice verification.

---

## IMPLEMENTATION STEPS

### Step 1: Add WebRTC Dependency

**File:** `/opt/moltbot/.openclaw/workspace/projects/vericall/ios/VeriCall.xcodeproj/project.pbxproj`

Add to Podfile or Package.swift:
```
dependency "GoogleWebRTC"
```

Or use Swift Package Manager:
- URL: `https://github.com/stasel/WebRTC`
- Version: Up to next major

---

### Step 2: Create WebRTC Service

**Create new file:** `/opt/moltbot/.openclaw/workspace/projects/vericall/ios/VeriCall/Services/WebRTCService.swift`

```swift
import Foundation
import WebRTC
import Combine

final class WebRTCService: NSObject, ObservableObject {
    static let shared = WebRTCService()
    
    @Published var isConnected = false
    @Published var localAudioLevel: Float = 0.0
    @Published var remoteAudioLevel: Float = 0.0
    
    // WebRTC components
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var factory: RTCPeerConnectionFactory
    
    // Audio processing for voice verification
    var onRemoteAudioBuffer: ((Data) -> Void)?
    
    private override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        super.init()
    }
    
    // MARK: - Setup
    
    func setupPeerConnection(iceServers: [String]) {
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: [$0]) }
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
        
        // Add local audio track
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        
        if let localAudioTrack = localAudioTrack {
            peerConnection?.add(localAudioTrack, streamIds: ["stream0"])
        }
    }
    
    // MARK: - Call Control
    
    func startCall(to signalingServer: URL, callId: String) async throws {
        guard let peerConnection = peerConnection else {
            throw WebRTCError.notInitialized
        }
        
        // Create offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        let offer = try await peerConnection.offer(for: constraints)
        try await peerConnection.setLocalDescription(offer)
        
        // Send offer to signaling server
        try await sendSignalingMessage(
            type: .offer,
            sdp: offer.sdp,
            callId: callId,
            server: signalingServer
        )
    }
    
    func answerCall(offerSDP: String, callId: String) async throws {
        guard let peerConnection = peerConnection else {
            throw WebRTCError.notInitialized
        }
        
        // Set remote description (offer)
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await peerConnection.setRemoteDescription(offer)
        
        // Create answer
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await peerConnection.answer(for: constraints)
        try await peerConnection.setLocalDescription(answer)
        
        // Send answer to signaling server
        try await sendSignalingMessage(
            type: .answer,
            sdp: answer.sdp,
            callId: callId,
            server: URL(string: "wss://vericall-api.fly.dev/ws")!
        )
    }
    
    func endCall() {
        peerConnection?.close()
        peerConnection = nil
        isConnected = false
    }
    
    // MARK: - Signaling
    
    private func sendSignalingMessage(type: SignalingType, sdp: String, callId: String, server: URL) async throws {
        // Use existing WebSocketService for signaling
        let message: [String: Any] = [
            "type": type.rawValue,
            "sdp": sdp,
            "callId": callId
        ]
        
        try await WebSocketService.shared.sendSignal(message)
    }
    
    // MARK: - Audio Processing
    
    func startAudioAnalysis() {
        // Hook into remote audio track for voice verification
        // This is called when remote audio track is received
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Signaling state changed: \(stateChanged)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Remote stream added")
        
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            isConnected = true
            
            // 🎉 HERE'S WHERE WE GET REMOTE AUDIO FOR VOICE VERIFICATION
            // Start analyzing this audio track
            NotificationCenter.default.post(
                name: .webRTCConnected,
                object: nil,
                userInfo: ["audioTrack": audioTrack]
            )
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("Remote stream removed")
        isConnected = false
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE connection state: \(newState)")
        if newState == .connected || newState == .completed {
            isConnected = true
        } else if newState == .disconnected || newState == .failed {
            isConnected = false
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Send ICE candidate to remote peer via signaling server
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ICE gathering state: \(newState)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Types

enum WebRTCError: Error {
    case notInitialized
    case signalingFailed
    case connectionFailed
}

enum SignalingType: String {
    case offer = "webrtc.offer"
    case answer = "webrtc.answer"
    case iceCandidate = "webrtc.ice"
}

extension Notification.Name {
    static let webRTCConnected = Notification.Name("webRTCConnected")
}
```

---

### Step 3: Integrate with Voice Verification

**Modify:** `/opt/moltbot/.openclaw/workspace/projects/vericall/ios/VeriCall/Services/VoiceVerificationService.swift`

Add WebRTC audio processing:

```swift
// Add to VoiceVerificationService class

private var webRTCObserver: NSObjectProtocol?

func setupWebRTCListening() {
    // Listen for WebRTC connection
    webRTCObserver = NotificationCenter.default.addObserver(
        forName: .webRTCConnected,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        if let audioTrack = notification.userInfo?["audioTrack"] as? RTCAudioTrack {
            self?.startAnalyzingRemoteAudio(track: audioTrack)
        }
    }
}

private func startAnalyzingRemoteAudio(track: RTCAudioTrack) {
    // Hook into the audio track to get raw audio data
    // This is where we extract features for voice verification
    
    // For now, simulate with timer (replace with real audio capture)
    Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
        Task {
            await self?.performVerification()
        }
    }
}

private func performVerification() async {
    // Capture 3-second audio sample from WebRTC
    // Extract features
    // Compare to received voice thumbprint
    // Update UI with match percentage
}
```

---

### Step 4: Update CallManager to Use WebRTC

**Modify:** `/opt/moltbot/.openclaw/workspace/projects/vericall/ios/VeriCall/Services/CallManager.swift`

Replace phone call logic with WebRTC:

```swift
// Add property
private let webRTCService = WebRTCService.shared

// Update initiateCall method
func initiateCall(to contact: Contact) async throws {
    // ... existing setup code ...
    
    // Setup WebRTC
    webRTCService.setupPeerConnection(iceServers: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302"
    ])
    
    // Start WebRTC call
    try await webRTCService.startCall(
        to: URL(string: "wss://vericall-api.fly.dev/ws")!,
        callId: callId
    )
    
    // Start voice verification once connected
    webRTCService.setupWebRTCListening()
    
    // ... rest of method ...
}

// Update acceptCall to use WebRTC
func acceptCall(_ call: Call, withOfferSDP: String? = nil) async throws {
    // Setup WebRTC
    webRTCService.setupPeerConnection(iceServers: [
        "stun:stun.l.google.com:19302"
    ])
    
    if let offerSDP = withOfferSDP {
        try await webRTCService.answerCall(offerSDP: offerSDP, callId: call.id)
    }
    
    // Start voice verification with received thumbprint
    if let voiceThumbprint = call.voiceThumbprint {
        try? await voiceVerificationService.startVerification(
            withExternalThumbprint: voiceThumbprint,
            contactId: call.callerId
        )
    }
    
    webRTCService.setupWebRTCListening()
}
```

---

### Step 5: Update Backend for WebRTC Signaling

**Modify:** `/opt/moltbot/.openclaw/workspace/projects/vericall/backend/app/websocket.py`

Add WebRTC signaling message types:

```python
# Add to handle_websocket function

elif message_type in ['webrtc.offer', 'webrtc.answer', 'webrtc.ice']:
    # Forward WebRTC signaling to recipient
    recipient_id = message.get('recipientId')
    if recipient_id in connected_clients:
        await connected_clients[recipient_id].send(json.dumps({
            'type': message_type,
            'sdp': message.get('sdp'),
            'callId': message.get('callId'),
            'ice': message.get('ice'),
            'from': user_id
        }))
```

---

### Step 6: Update UI

**Modify:** `/opt/moltbot/.openclaw/workspace/projects/vericall/ios/VeriCall/Views/Calling/ActiveCallView.swift`

Add WebRTC connection status:

```swift
@ObservedObject private var webRTCService = WebRTCService.shared

// In body:
HStack {
    Image(systemName: webRTCService.isConnected ? "wifi" : "wifi.slash")
    Text(webRTCService.isConnected ? "Secure Connection" : "Connecting...")
    
    // Voice verification status
    if let matchPercentage = voiceVerificationService.currentResult?.matchScore {
        Text("Voice Match: \(Int(matchPercentage * 100))%")
            .foregroundColor(matchPercentage > 0.75 ? .green : .orange)
    }
}
```

---

### Step 7: Update Info.plist

Add microphone description for WebRTC:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>VeriCall needs microphone access for secure in-app calling with voice verification.</string>
```

---

## EXPECTED RESULT

After implementation:
1. Users open VeriCall app
2. Tap contact to call
3. WebRTC connection established (in-app, not phone network)
4. "Device Verified" badge shows (from our crypto signature)
5. Once connected, voice verification starts
6. "Voice Match: 94%" displays in real-time
7. If voice doesn't match, mismatch alert shows

---

## TESTING CHECKLIST

- [ ] WebRTC framework imports successfully
- [ ] Can create peer connection
- [ ] Can start call (offer/answer exchange works)
- [ ] Audio flows both ways
- [ ] Voice verification analyzes remote audio
- [ ] Match percentage updates in UI
- [ ] Call ends properly

---

## NOTES

- Use Google's public STUN servers for demo (free)
- For production, add TURN servers (Twilio, Xirsys, etc.)
- WebRTC uses significant battery - optimize for mobile
- Add connection quality indicators for UX

---

## TIME ESTIMATE

- Implementation: 4-6 hours
- Testing: 2-3 hours
- Bug fixes: 2-4 hours
- **Total: 8-13 hours**

---

**COPY THIS ENTIRE FILE AND PASTE INTO CLAUDE CODE**

**Say:** "Implement this WebRTC solution for VeriCall"
