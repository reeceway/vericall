import Foundation

#if canImport(WebRTC)
import WebRTC

/// WebRTC data-channel transport for high-fidelity AI audio packets.
/// RTP remains the phone-call path; this channel carries packetized ALAC/PCM AI chunks.
final class AIDataChannelService: NSObject {
    static let shared = AIDataChannelService()

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onPacketReceived: ((Data) -> Void)?
    var onLocalDescription: ((_ type: String, _ sdp: String) -> Void)?
    var onLocalICECandidate: ((_ candidate: String, _ sdpMid: String?, _ sdpMLineIndex: Int32?) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var currentCallId: String?
    private var configuredIceServers: [RTCIceServer] = []
    private var configuredPolicy: RTCIceTransportPolicy = .all
    private var pendingRemoteCandidates: [RTCIceCandidate] = []

    private(set) var isConnected: Bool = false
    let isSupported: Bool = true

    private override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    func configure(iceServers: [VoIPICEServer], transportPolicy: String) {
        configuredIceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "")
        }
        if configuredIceServers.isEmpty {
            configuredIceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        }
        configuredPolicy = transportPolicy.lowercased() == "relay" ? .relay : .all
    }

    func startAsCaller(callId: String) {
        if currentCallId != callId {
            stop()
        }
        currentCallId = callId
        ensurePeerConnection()
        ensureLocalDataChannel()
        createOffer()
    }

    func startAsCallee(callId: String) {
        if currentCallId != callId {
            stop()
        }
        currentCallId = callId
        ensurePeerConnection()
    }

    func applyRemoteOffer(_ sdp: String) {
        ensurePeerConnection()
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection?.setRemoteDescription(offer, completionHandler: { [weak self] error in
            guard let self else { return }
            if let error {
                print("[AIDataChannel] setRemoteOffer failed: \(error)")
                return
            }
            self.flushPendingRemoteCandidates()
            self.createAnswer()
        })
    }

    func applyRemoteAnswer(_ sdp: String) {
        ensurePeerConnection()
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(answer, completionHandler: { [weak self] error in
            guard let self else { return }
            if let error {
                print("[AIDataChannel] setRemoteAnswer failed: \(error)")
                return
            }
            self.flushPendingRemoteCandidates()
        })
    }

    func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
        ensurePeerConnection()
        let index = sdpMLineIndex ?? 0
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: index,
            sdpMid: sdpMid
        )

        guard let peerConnection else { return }
        if peerConnection.remoteDescription == nil {
            pendingRemoteCandidates.append(rtcCandidate)
            return
        }
        peerConnection.add(rtcCandidate)
    }

    @discardableResult
    func sendPacket(_ packet: Data) -> Bool {
        guard !packet.isEmpty else { return false }
        guard let dataChannel, dataChannel.readyState == .open else { return false }
        let buffer = RTCDataBuffer(data: packet, isBinary: true)
        return dataChannel.sendData(buffer)
    }

    func stop() {
        dataChannel?.delegate = nil
        peerConnection?.delegate = nil
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        pendingRemoteCandidates.removeAll(keepingCapacity: false)
        currentCallId = nil
        if isConnected {
            isConnected = false
            onDisconnected?()
        }
    }

    // MARK: - Internal setup

    private func ensurePeerConnection() {
        if peerConnection != nil {
            return
        }
        let config = RTCConfiguration()
        config.iceServers = configuredIceServers
        config.iceTransportPolicy = configuredPolicy
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    private func ensureLocalDataChannel() {
        guard dataChannel == nil else { return }
        guard let peerConnection else { return }

        let config = RTCDataChannelConfiguration()
        config.isOrdered = false
        config.maxRetransmits = 0
        let channel = peerConnection.dataChannel(forLabel: "ai-lossless-audio", configuration: config)
        channel?.delegate = self
        dataChannel = channel
    }

    private func createOffer() {
        guard let peerConnection else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            guard let sdp else {
                if let error {
                    print("[AIDataChannel] Offer failed: \(error)")
                }
                return
            }
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { error in
                if let error {
                    print("[AIDataChannel] setLocalOffer failed: \(error)")
                    return
                }
                self.onLocalDescription?("offer", sdp.sdp)
            })
        }
    }

    private func createAnswer() {
        guard let peerConnection else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        peerConnection.answer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            guard let sdp else {
                if let error {
                    print("[AIDataChannel] Answer failed: \(error)")
                }
                return
            }
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { error in
                if let error {
                    print("[AIDataChannel] setLocalAnswer failed: \(error)")
                    return
                }
                self.onLocalDescription?("answer", sdp.sdp)
            })
        }
    }

    private func flushPendingRemoteCandidates() {
        guard let peerConnection, peerConnection.remoteDescription != nil else { return }
        guard !pendingRemoteCandidates.isEmpty else { return }
        for candidate in pendingRemoteCandidates {
            peerConnection.add(candidate)
        }
        pendingRemoteCandidates.removeAll(keepingCapacity: false)
    }

    private func updateConnectedState(_ connected: Bool, reason: String) {
        if connected == isConnected {
            return
        }
        isConnected = connected
        print("[AIDataChannel] state=\(connected ? "connected" : "disconnected") reason=\(reason)")
        if connected {
            onConnected?()
        } else {
            onDisconnected?()
        }
    }
}

extension AIDataChannelService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            updateConnectedState(true, reason: "ice-\(newState.rawValue)")
        case .disconnected, .failed, .closed:
            updateConnectedState(false, reason: "ice-\(newState.rawValue)")
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalICECandidate?(candidate.sdp, candidate.sdpMid, Int32(candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        self.dataChannel?.delegate = nil
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCPeerConnectionState) {
        switch stateChanged {
        case .connected:
            updateConnectedState(true, reason: "pc-\(stateChanged.rawValue)")
        case .disconnected, .failed, .closed:
            updateConnectedState(false, reason: "pc-\(stateChanged.rawValue)")
        default:
            break
        }
    }
}

extension AIDataChannelService: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            updateConnectedState(true, reason: "dc-open")
        case .closing, .closed:
            updateConnectedState(false, reason: "dc-\(dataChannel.readyState.rawValue)")
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary else { return }
        onPacketReceived?(buffer.data)
    }
}

#else

/// Build-safe stub when WebRTC dependency isn't available.
final class AIDataChannelService {
    static let shared = AIDataChannelService()

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onPacketReceived: ((Data) -> Void)?
    var onLocalDescription: ((_ type: String, _ sdp: String) -> Void)?
    var onLocalICECandidate: ((_ candidate: String, _ sdpMid: String?, _ sdpMLineIndex: Int32?) -> Void)?

    private(set) var isConnected: Bool = false
    let isSupported: Bool = false

    func configure(iceServers: [VoIPICEServer], transportPolicy: String) {}
    func startAsCaller(callId: String) {}
    func startAsCallee(callId: String) {}
    func applyRemoteOffer(_ sdp: String) {}
    func applyRemoteAnswer(_ sdp: String) {}
    func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {}
    @discardableResult
    func sendPacket(_ packet: Data) -> Bool { false }
    func stop() {}
}

#endif
