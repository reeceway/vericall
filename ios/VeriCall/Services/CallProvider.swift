import Foundation
import Combine

enum CallProviderKind: String {
    case customP2P
    case twilioVoice
}

@MainActor
protocol CallProvider: AnyObject {
    var kind: CallProviderKind { get }
    var isAvailable: Bool { get }

    var isConnectedPublisher: Published<Bool>.Publisher { get }
    var isStreamingPublisher: Published<Bool>.Publisher { get }
    var isMutedPublisher: Published<Bool>.Publisher { get }
    var isSpeakerOnPublisher: Published<Bool>.Publisher { get }

    var onConnected: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onIncomingCall: ((String, UUID?) -> Void)? { get set }
    var onConnectFailed: ((String) -> Void)? { get set }

    var remoteBufferQueue: DispatchQueue { get }
    var localBufferQueue: DispatchQueue { get }

    func remoteAudioSnapshot() -> [Float]
    func localAudioSnapshot() -> [Float]

    func configure()
    func joinCall(_ callId: String, remoteUserId: String?, remotePeerName: String?)
    func leaveCall()
    func setMuted(_ muted: Bool)
    func setSpeaker(_ on: Bool)
    func debugAudioSnapshot() -> (remoteFrames: Int, localFrames: Int, remoteSamples: Int, localSamples: Int)
    func refreshBuffers(clear: Bool)
    func ensureAIAudioMirrorRunning()
}
