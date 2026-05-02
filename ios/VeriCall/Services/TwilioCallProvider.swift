import Foundation
import Combine

@MainActor
final class TwilioCallProvider: ObservableObject, CallProvider {

    let kind: CallProviderKind = .twilioVoice
    let isAvailable: Bool = {
#if canImport(TwilioVoice)
        true
#else
        false
#endif
    }()

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

#if canImport(TwilioVoice)
    nonisolated let remoteBufferQueue = TwilioCallService.shared.remoteBufferQueue
    nonisolated let localBufferQueue = TwilioCallService.shared.localBufferQueue
#else
    nonisolated let remoteBufferQueue = DispatchQueue(label: "com.vericall.twilio.placeholder.remote")
    nonisolated let localBufferQueue = DispatchQueue(label: "com.vericall.twilio.placeholder.local")
#endif

    private let keychain = KeychainService.shared
    private let api = APIService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
#if canImport(TwilioVoice)
        let service = TwilioCallService.shared

        service.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isConnected = value }
            .store(in: &cancellables)

        service.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isStreaming = value }
            .store(in: &cancellables)

        service.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isMuted = value }
            .store(in: &cancellables)

        service.$isSpeakerOn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isSpeakerOn = value }
            .store(in: &cancellables)

        service.onConnected = { [weak self] in self?.onConnected?() }
        service.onDisconnected = { [weak self] in self?.onDisconnected?() }
        service.onIncomingCall = { [weak self] identity, inviteUUID in
            self?.onIncomingCall?(identity, inviteUUID)
        }
        service.onConnectFailed = { [weak self] message in
            print("[CallTransport] Twilio connect failed: \(message)")
            self?.onConnectFailed?(message)
        }
#endif
    }

    func remoteAudioSnapshot() -> [Float] {
#if canImport(TwilioVoice)
        remoteBufferQueue.sync { TwilioCallService.shared.remoteAudioBuffer }
#else
        []
#endif
    }

    func localAudioSnapshot() -> [Float] {
#if canImport(TwilioVoice)
        localBufferQueue.sync { TwilioCallService.shared.localAudioBuffer }
#else
        []
#endif
    }

    func configure() {
#if canImport(TwilioVoice)
        print("[CallTransport] Twilio provider configured and waiting for token-backed call setup.")
#else
        print("[CallTransport] Twilio provider selected, but Twilio SDK is not linked in the current app build yet.")
#endif
    }

    func joinCall(_ callId: String, remoteUserId: String?, remotePeerName: String?) {
#if canImport(TwilioVoice)
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let service = TwilioCallService.shared

                if service.hasPendingInvite {
                    print("[CallTransport] Accepting pending Twilio invite for call \(callId)")
                    CallDebugReporter.post("twilio_provider_accept_pending_invite", details: ["callId": callId])
                    if let appAccessToken = await self.appAccessTokenForLiveCall(context: "incoming_answer") {
                        service.startMirroredAudioPollingForPendingInvite(appAccessToken: appAccessToken)
                    } else {
                        print("[CallTransport] AI audio mirror skipped: missing app access token for incoming call")
                        CallDebugReporter.post("ai_audio_mirror_token_missing", details: ["context": "incoming_answer"])
                    }
                    service.acceptIncomingCall()
                    return
                }

                guard let appAccessToken = await self.appAccessTokenForLiveCall(context: "outgoing_call") else {
                    throw APIError.unauthorized
                }
                let twilioToken = try await self.loadTwilioVoiceAccessToken(appAccessToken: appAccessToken)
                let localIdentity = twilioToken.identity ?? Constants.preferredTwilioIdentity()

                guard let remoteUserId, !remoteUserId.isEmpty else {
                    let message = "Missing Twilio recipient identity."
                    print("[CallTransport] \(message) callId=\(callId)")
                    self.onConnectFailed?(message)
                    return
                }

                print("[CallTransport] Starting Twilio direct client call for call \(callId) -> \(remoteUserId)")
                let audioMirrorToken = Self.makeAudioMirrorToken()
                service.startMirroredAudioPolling(
                    sessionKey: callId,
                    mirrorToken: audioMirrorToken,
                    appAccessToken: appAccessToken
                )
                service.makeCall(
                    accessToken: twilioToken.token,
                    to: remoteUserId,
                    from: localIdentity,
                    sessionKey: callId,
                    mirrorToken: audioMirrorToken
                )
                print("[CallTransport] Receiver wake is handled by Twilio <Dial><Client> push delivery")
            } catch {
                let message = "Failed to fetch Twilio access token: \(error.localizedDescription)"
                print("[CallTransport] \(message)")
                self.onConnectFailed?(message)
            }
        }
#else
        onConnectFailed?("Twilio SDK is unavailable in this build.")
        print("[CallTransport] Twilio provider unavailable for call \(callId).")
#endif
    }

    func leaveCall() {
#if canImport(TwilioVoice)
        let service = TwilioCallService.shared
        if service.hasPendingInvite {
            service.rejectIncomingCall()
        } else {
            service.disconnect()
        }
#endif
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
#if canImport(TwilioVoice)
        TwilioCallService.shared.setMuted(muted)
#endif
    }

    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
#if canImport(TwilioVoice)
        TwilioCallService.shared.setSpeaker(on)
#endif
    }

    func debugAudioSnapshot() -> (remoteFrames: Int, localFrames: Int, remoteSamples: Int, localSamples: Int) {
#if canImport(TwilioVoice)
        let remote = remoteAudioSnapshot().count
        let local = localAudioSnapshot().count
        return (remote / 160, local / 160, remote, local)
#else
        return (0, 0, 0, 0)
#endif
    }

    func refreshBuffers(clear: Bool) {
        _ = clear
    }

    func ensureAIAudioMirrorRunning() {
#if canImport(TwilioVoice)
        Task { @MainActor [weak self] in
            guard let self,
                  let appAccessToken = await self.appAccessTokenForLiveCall(context: "ai_mirror_ensure") else {
                CallDebugReporter.post("ai_audio_mirror_ensure_skipped", details: ["reason": "missing_token"])
                return
            }
            let started = TwilioCallService.shared.startMirroredAudioPollingForCurrentCallContext(
                appAccessToken: appAccessToken
            )
            CallDebugReporter.post(
                "ai_audio_mirror_ensure",
                details: ["started": started ? "true" : "false"]
            )
        }
#endif
    }

    private func appAccessTokenForLiveCall(context: String) async -> String? {
        do {
            let token = try await keychain.retrieveString(
                service: "VeriCall",
                account: Constants.KeychainKeys.accessToken
            )
            guard !token.isEmpty else { return nil }
            UserDefaults.standard.set(token, forKey: "authToken")
            return token
        } catch {
            if let fallback = UserDefaults.standard.string(forKey: "authToken"),
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CallDebugReporter.post(
                    "app_access_token_keychain_fallback",
                    details: ["context": context, "error": String(describing: error)]
                )
                return fallback
            }
            CallDebugReporter.post(
                "app_access_token_unavailable",
                details: ["context": context, "error": String(describing: error)]
            )
            return nil
        }
    }

    private func loadTwilioVoiceAccessToken(appAccessToken: String) async throws -> TwilioVoiceAccessTokenResponse {
        let requestedIdentity = Constants.preferredTwilioIdentity()

        return try await api.fetchTwilioVoiceAccessToken(
            clientIdentity: requestedIdentity,
            accessToken: appAccessToken
        )
    }

    private static func makeAudioMirrorToken() -> String {
        let first = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let second = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return first + second
    }
}
