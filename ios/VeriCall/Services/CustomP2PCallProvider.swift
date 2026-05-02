import Foundation
import Combine

@MainActor
final class CustomP2PCallProvider: ObservableObject, CallProvider {

    let kind: CallProviderKind = .customP2P
    let isAvailable: Bool = true

    @Published private(set) var isConnected = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerOn = false

    var isConnectedPublisher: Published<Bool>.Publisher { $isConnected }
    var isStreamingPublisher: Published<Bool>.Publisher { $isStreaming }
    var isMutedPublisher: Published<Bool>.Publisher { $isMuted }
    var isSpeakerOnPublisher: Published<Bool>.Publisher { $isSpeakerOn }

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onIncomingCall: ((String, UUID?) -> Void)?
    var onConnectFailed: ((String) -> Void)?

    nonisolated let remoteBufferQueue = DispatchQueue(label: "com.vericall.customp2p.remotebuf")
    nonisolated(unsafe) private var remoteAudioBuffer: [Float] = []
    nonisolated let localBufferQueue = DispatchQueue(label: "com.vericall.customp2p.localbuf")
    nonisolated(unsafe) private var localAudioBuffer: [Float] = []

    private let audioStream = AudioStreamService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        audioStream.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isStreaming = value }
            .store(in: &cancellables)

        audioStream.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isMuted = value }
            .store(in: &cancellables)

        audioStream.$isSpeakerOn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isSpeakerOn = value }
            .store(in: &cancellables)

        audioStream.$isP2PConnected
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

        audioStream.onAudioConnected = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.refreshBuffers(clear: false)
            self.onConnected?()
        }
    }

    func configure() {
        audioStream.setup()
    }

    func joinCall(_ callId: String, remoteUserId: String?, remotePeerName: String?) {
        audioStream.setup()
        audioStream.startStreaming()
        if let remotePeerName, !remotePeerName.isEmpty {
            audioStream.connectToPeer(callerName: remotePeerName)
            print("[CallTransport] Attempting peer connection to \(remotePeerName) for call \(callId)")
        } else {
            print("[CallTransport] No remote peer name available for call \(callId); transport will wait for inbound connection")
        }
        refreshBuffers(clear: false)
        isStreaming = true
        print("[CallTransport] Started custom audio stream for call \(callId); waiting for peer transport connection")
    }

    func leaveCall() {
        let wasConnected = isConnected
        audioStream.tearDown()
        refreshBuffers(clear: true)
        isConnected = false
        isStreaming = false
        if wasConnected {
            onDisconnected?()
        }
        print("[CallTransport] Stopped custom audio stream")
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioStream.setMicrophoneEnabled(!muted)
    }

    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
        audioStream.setSpeaker(on)
    }

    nonisolated func remoteAudioSnapshot() -> [Float] {
        remoteBufferQueue.sync { remoteAudioBuffer }
    }

    nonisolated func localAudioSnapshot() -> [Float] {
        localBufferQueue.sync { localAudioBuffer }
    }

    nonisolated func debugAudioSnapshot() -> (remoteFrames: Int, localFrames: Int, remoteSamples: Int, localSamples: Int) {
        let remote = remoteBufferQueue.sync { remoteAudioBuffer.count }
        let local = localBufferQueue.sync { localAudioBuffer.count }
        return (remote / 160, local / 160, remote, local)
    }

    func refreshBuffers(clear: Bool = false) {
        if clear {
            remoteBufferQueue.async { [weak self] in self?.remoteAudioBuffer.removeAll() }
            localBufferQueue.async { [weak self] in self?.localAudioBuffer.removeAll() }
            return
        }

        audioStream.remoteQueue.async { [weak self, weak audioStream] in
            guard let self, let audioStream else { return }
            let snapshot = audioStream.remoteBuffer
            self.remoteBufferQueue.async { self.remoteAudioBuffer = snapshot }
        }

        audioStream.captureQueue.async { [weak self, weak audioStream] in
            guard let self, let audioStream else { return }
            let snapshot = audioStream.captureBuffer
            self.localBufferQueue.async { self.localAudioBuffer = snapshot }
        }
    }

    func ensureAIAudioMirrorRunning() {}
}
