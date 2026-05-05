import Foundation
import Combine

/// Shared Twilio-backed call transport facade used by the app's live call and ML paths.
@MainActor
final class CallTransportService: ObservableObject {

    static let shared = CallTransportService()

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published private(set) var activeProviderKind: CallProviderKind = .twilioVoice

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onIncomingCall: ((String, UUID?) -> Void)?
    var onConnectFailed: ((String) -> Void)?

    nonisolated let remoteBufferQueue = DispatchQueue(label: "com.vericall.calltransport.remotebuf")
    nonisolated(unsafe) private(set) var remoteAudioBuffer: [Float] = []
    nonisolated let localBufferQueue = DispatchQueue(label: "com.vericall.calltransport.localbuf")
    nonisolated(unsafe) private(set) var localAudioBuffer: [Float] = []

    private let twilioProvider = TwilioCallProvider()
    private var provider: CallProvider
    private var cancellables = Set<AnyCancellable>()

    private init() {
        provider = twilioProvider
        activeProviderKind = provider.kind
        bindProvider()
    }

    func configure() {
        provider.configure()
    }

    func joinCall(_ callId: String, remoteUserId: String? = nil, remotePeerName: String? = nil) {
        provider.joinCall(callId, remoteUserId: remoteUserId, remotePeerName: remotePeerName)
        refreshBuffers()
    }

    func leaveCall() {
        provider.leaveCall()
        refreshBuffers(clear: true)
    }

    func setMuted(_ muted: Bool) {
        provider.setMuted(muted)
    }

    func setSpeaker(_ on: Bool) {
        provider.setSpeaker(on)
    }

    func debugAudioSnapshot() -> (remoteFrames: Int, localFrames: Int, remoteSamples: Int, localSamples: Int) {
        provider.debugAudioSnapshot()
    }

    func refreshBuffers(clear: Bool = false) {
        if clear {
            remoteBufferQueue.sync { remoteAudioBuffer.removeAll() }
            localBufferQueue.sync { localAudioBuffer.removeAll() }
            provider.refreshBuffers(clear: true)
            return
        }

        provider.refreshBuffers(clear: false)
        let remoteSnapshot = provider.remoteAudioSnapshot()
        let localSnapshot = provider.localAudioSnapshot()
        remoteBufferQueue.sync { remoteAudioBuffer = remoteSnapshot }
        localBufferQueue.sync { localAudioBuffer = localSnapshot }
    }

    func ensureAIAudioMirrorRunning() {
        provider.ensureAIAudioMirrorRunning()
    }

    private func bindProvider() {
        cancellables.removeAll()

        provider.isStreamingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isStreaming = value }
            .store(in: &cancellables)

        provider.isMutedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isMuted = value }
            .store(in: &cancellables)

        provider.isSpeakerOnPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isSpeakerOn = value }
            .store(in: &cancellables)

        provider.isConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = value
                if value && !wasConnected {
                    self.onConnected?()
                } else if !value && wasConnected {
                    self.onDisconnected?()
                }
            }
            .store(in: &cancellables)

        provider.onConnected = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.refreshBuffers()
            self.onConnected?()
        }

        provider.onDisconnected = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.onDisconnected?()
        }

        provider.onIncomingCall = { [weak self] identity, inviteUUID in
            self?.onIncomingCall?(identity, inviteUUID)
        }

        provider.onConnectFailed = { [weak self] message in
            self?.onConnectFailed?(message)
        }
    }
}
