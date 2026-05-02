import Foundation
import AVFoundation
import Accelerate
import AudioToolbox
#if canImport(TwilioVoice)
import TwilioVoice
#endif

#if canImport(TwilioVoice)
/// Manages VoIP call audio via Twilio's global voice network.
///
/// Replaces: AgoraCallService
///
/// What Twilio gives us:
///   - Global PSTN-grade voice network (same infrastructure as phone carriers)
///   - Automatic NAT/TURN traversal, firewall punching
///   - Opus codec, adaptive bitrate, professional jitter buffer
///   - Client-to-client calling via TwiML App routing
///   - Works reliably on iOS 26 beta (unlike Agora 4.6.2)
///
/// Audio for ML:
///   - Twilio Media Streams mirror both call tracks to the backend.
///   - The backend expands Twilio 8kHz μ-law frames into 16kHz PCM16.
///   - The app polls that mirror into remote/local rolling buffers.
///   - AIAnalysisService reads those 16kHz buffers for inference.
@MainActor
final class TwilioCallService: NSObject, ObservableObject {

    static let shared = TwilioCallService()

    // MARK: - Published State

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isMuted    = false
    @Published var isSpeakerOn = false

    // MARK: - Callbacks

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onConnectFailed: ((String) -> Void)?
    var onIncomingCall: ((String, UUID?) -> Void)?  // caller identity + Twilio invite UUID

    // MARK: - Remote Audio Buffer (16kHz, for ML inference)

    /// Thread-safe access via remoteBufferQueue
    nonisolated let remoteBufferQueue = DispatchQueue(label: "com.vericall.twilio.remotebuf")
    nonisolated(unsafe) private(set) var remoteAudioBuffer: [Float] = []
    nonisolated let localBufferQueue = DispatchQueue(label: "com.vericall.twilio.localbuf")
    nonisolated(unsafe) private(set) var localAudioBuffer: [Float] = []
    private let maxBufferSamples = 16_000 * 10  // 10s at 16kHz

    // MARK: - Twilio Voice

    private var activeCall: TwilioVoice.Call?
    private var activeCallInvite: TwilioVoice.CallInvite?
    private let defaultAudioDevice: DefaultAudioDevice
    private var pendingPushCompletion: (() -> Void)?
    private var registrationInFlight = false
    private var lastRegistrationIdentity: String?
    private var lastRegistrationDeviceTokenSuffix: String?
    private var lastRegistrationAt: Date?
    private let bindingResetVersion = "pushcred_CR5d510145dd0fbf2be6a48fc6e0d99006_v1"
    private var audioMirrorTask: Task<Void, Never>?
    private var audioMirrorSessionKey: String?
    private var audioMirrorToken: String?
    private var audioMirrorContext: AudioMirrorContext?
    private let performanceProfile = AppPerformanceProfile.shared

    private struct AudioMirrorContext {
        let sessionKey: String
        let mirrorToken: String
    }

    private override init() {
        DefaultAudioDevice.ignoresPreferredAttributeConfigurationErrors = true
        self.defaultAudioDevice = DefaultAudioDevice()
        super.init()
        configureDefaultAudioDeviceBlock()
#if DEBUG
        TwilioVoiceSDK.logLevel = performanceProfile.verboseCallLogging ? .debug : .error
#else
        TwilioVoiceSDK.logLevel = .error
#endif
        TwilioVoiceSDK.audioDevice = defaultAudioDevice
    }

    var hasPendingInvite: Bool {
        activeCallInvite != nil
    }

    // MARK: - Outgoing Call

    /// Place an outgoing call to a recipient identity (their VeriCall user UUID).
    func makeCall(
        accessToken: String,
        to recipientIdentity: String,
        from callerIdentity: String,
        conferenceRoom: String? = nil,
        sessionKey: String? = nil,
        mirrorToken: String? = nil
    ) {
        var params = [
            "To": recipientIdentity,
            "From": callerIdentity
        ]
        if let accountContext = Constants.activeVoiceAccountContext() {
            params["FromMspId"] = accountContext.mspId
            params["FromOrganizationId"] = accountContext.organizationId
            if let membershipId = accountContext.membershipId, !membershipId.isEmpty {
                params["FromMembershipId"] = membershipId
            }
        }
        if let conferenceRoom {
            params["Mode"] = "conference"
            params["Room"] = conferenceRoom
        }
        if let sessionKey, !sessionKey.isEmpty {
            params["Session"] = sessionKey
        }
        if let mirrorToken, !mirrorToken.isEmpty {
            params["MirrorToken"] = mirrorToken
        }

        let connectOptions = ConnectOptions(accessToken: accessToken) { builder in
            builder.params = params
        }

        activeCall = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        defaultAudioDevice.isEnabled = true
        isStreaming = true
        print("[TwilioCall] Connecting to \(recipientIdentity)...")
    }

    /// Accept an incoming call invite.
    func acceptIncomingCall() {
        guard let invite = activeCallInvite else {
            print("[TwilioCall] No pending call invite to accept")
            CallDebugReporter.post("twilio_accept_invite_missing")
            return
        }
        cacheAudioMirrorContextForPendingInvite()

        let acceptOptions = AcceptOptions(callInvite: invite) { builder in
            builder.uuid = invite.uuid
        }

        activeCall = invite.accept(options: acceptOptions, delegate: self)
        defaultAudioDevice.isEnabled = true
        activeCallInvite = nil
        print("[TwilioCall] Accepting incoming call...")
        CallDebugReporter.post("twilio_accept_invite_requested", details: ["uuid": invite.uuid.uuidString, "from": invite.from ?? "unknown"])
    }

    // MARK: - Call Lifecycle

    func disconnect() {
        activeCall?.disconnect()
        activeCall = nil
        activeCallInvite = nil
        stopMirroredAudioPolling()
        isConnected = false
        isStreaming = false
        onDisconnected?()
        print("[TwilioCall] Disconnected")
    }

    func rejectIncomingCall() {
        activeCallInvite?.reject()
        activeCallInvite = nil
        stopMirroredAudioPolling()
        print("[TwilioCall] Rejected incoming call")
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        isMuted = muted
        activeCall?.isMuted = muted
    }

    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
        configureDefaultAudioDeviceBlock()
        defaultAudioDevice.block()
    }

    func handleCallKitAudioSessionActivated() {
        defaultAudioDevice.isEnabled = true
        defaultAudioDevice.block()
        CallDebugReporter.post("twilio_default_audio_enabled")
    }

    func handleCallKitAudioSessionDeactivated() {
        defaultAudioDevice.isEnabled = false
        CallDebugReporter.post("twilio_default_audio_disabled")
    }

    private func configureDefaultAudioDeviceBlock() {
        defaultAudioDevice.block = { [weak self] in
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            Self.applySupportedAudioSessionPreferences(speakerEnabled: self?.isSpeakerOn ?? false)
        }
    }

    private static func applySupportedAudioSessionPreferences(speakerEnabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        if speakerEnabled && !isExternalAudioRouteActive(session.currentRoute) {
            options.insert(.defaultToSpeaker)
        }

        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        } catch {
            print("[TwilioCall] Default audio session category failed: \(error)")
        }

        do {
            let shouldForceSpeaker = speakerEnabled && !isExternalAudioRouteActive(session.currentRoute)
            try session.overrideOutputAudioPort(shouldForceSpeaker ? .speaker : .none)
        } catch {
            print("[TwilioCall] Default audio speaker override failed: \(error)")
        }

        print("[TwilioCall] Default audio route \(routeSummary(session.currentRoute))")
    }

    private static func isExternalAudioRouteActive(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.inputs.contains { input in
            isExternalInput(input.portType)
        } || route.outputs.contains { output in
            isExternalOutput(output.portType)
        }
    }

    private static func isExternalInput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .carAudio, .headsetMic, .usbAudio:
            return true
        default:
            return false
        }
    }

    private static func isExternalOutput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .carAudio, .headphones, .airPlay, .usbAudio, .HDMI:
            return true
        default:
            return false
        }
    }

    private static func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)]"
    }

    // MARK: - Register for Incoming Calls

    func registerForIncomingCalls(accessToken: String, deviceToken: Data) {
        let identity = Self.identity(fromAccessToken: accessToken) ?? Constants.preferredTwilioIdentity()
        let deviceTokenSuffix = deviceToken.map { String(format: "%02.2hhx", $0) }.joined().suffix(8)
        let now = Date()

        if registrationInFlight {
            print("[TwilioCall] Skipping duplicate registration while one is already in flight")
            CallDebugReporter.post("twilio_register_skipped", details: ["reason": "in_flight", "identity": identity])
            return
        }

        if lastRegistrationIdentity == identity,
           lastRegistrationDeviceTokenSuffix == String(deviceTokenSuffix),
           let lastRegistrationAt,
           now.timeIntervalSince(lastRegistrationAt) < 30 {
            print("[TwilioCall] Skipping duplicate registration for \(identity)")
            CallDebugReporter.post("twilio_register_skipped", details: ["reason": "recent_duplicate", "identity": identity])
            return
        }

        registrationInFlight = true
        let resetKey = "twilioVoiceBindingReset_\(bindingResetVersion)_\(identity)_\(deviceTokenSuffix)"
        if !UserDefaults.standard.bool(forKey: resetKey) {
            CallDebugReporter.post(
                "twilio_unregister_before_register_requested",
                details: ["identity": identity, "reason": "binding_reset"]
            )
            TwilioVoiceSDK.unregister(accessToken: accessToken, deviceToken: deviceToken) { [weak self] error in
                Task { @MainActor [weak self] in
                    if let error {
                        CallDebugReporter.post(
                            "twilio_unregister_before_register_failed",
                            details: ["identity": identity, "error": error.localizedDescription]
                        )
                    } else {
                        UserDefaults.standard.set(true, forKey: resetKey)
                        CallDebugReporter.post(
                            "twilio_unregister_before_register_success",
                            details: ["identity": identity]
                        )
                    }
                    self?.performTwilioRegistration(
                        accessToken: accessToken,
                        deviceToken: deviceToken,
                        identity: identity,
                        deviceTokenSuffix: String(deviceTokenSuffix)
                    )
                }
            }
            return
        }

        performTwilioRegistration(
            accessToken: accessToken,
            deviceToken: deviceToken,
            identity: identity,
            deviceTokenSuffix: String(deviceTokenSuffix)
        )
    }

    private func performTwilioRegistration(
        accessToken: String,
        deviceToken: Data,
        identity: String,
        deviceTokenSuffix: String
    ) {
        TwilioVoiceSDK.register(accessToken: accessToken, deviceToken: deviceToken) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registrationInFlight = false
                if let error = error {
                    print("[TwilioCall] Registration failed: \(error.localizedDescription)")
                    CallDebugReporter.post("twilio_register_failed", details: ["identity": identity, "error": error.localizedDescription])
                } else {
                    self.lastRegistrationIdentity = identity
                    self.lastRegistrationDeviceTokenSuffix = deviceTokenSuffix
                    self.lastRegistrationAt = Date()
                    print("[TwilioCall] Registered for incoming calls as \(identity)")
                    CallDebugReporter.post("twilio_register_success", details: ["identity": identity])
                }
            }
        }
    }

    private static func identity(fromAccessToken accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grants = json["grants"] as? [String: Any],
              let identity = grants["identity"] as? String else {
            return nil
        }
        return identity
    }

    /// Handle incoming push notification (VoIP push or regular push)
    func handleNotification(_ payload: [AnyHashable: Any], completion: (() -> Void)? = nil) {
        CallDebugReporter.post("twilio_handle_notification")
        pendingPushCompletion = completion
        TwilioVoiceSDK.handleNotification(payload, delegate: self, delegateQueue: nil)
        guard pendingPushCompletion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.pendingPushCompletion != nil else { return }
            CallDebugReporter.post("twilio_push_completion_safety_timeout")
            self?.completePendingPushHandling()
        }
    }

    func completePendingPushHandling() {
        guard pendingPushCompletion != nil else { return }
        CallDebugReporter.post("twilio_push_completion_called")
        pendingPushCompletion?()
        pendingPushCompletion = nil
    }

    // MARK: - Audio Feed (for ML inference)

    func startMirroredAudioPolling(sessionKey: String, mirrorToken: String, appAccessToken: String) {
        guard !sessionKey.isEmpty, !mirrorToken.isEmpty, !appAccessToken.isEmpty else {
            print("[TwilioCall] Audio mirror not started: missing session/token")
            return
        }

        if audioMirrorSessionKey == sessionKey, audioMirrorToken == mirrorToken, audioMirrorTask != nil {
            return
        }

        stopMirroredAudioPolling(clearContext: false)
        audioMirrorSessionKey = sessionKey
        audioMirrorToken = mirrorToken
        audioMirrorContext = AudioMirrorContext(sessionKey: sessionKey, mirrorToken: mirrorToken)
        remoteBufferQueue.async { self.remoteAudioBuffer.removeAll() }
        localBufferQueue.async { self.localAudioBuffer.removeAll() }

        audioMirrorTask = Task { [weak self] in
            var remoteCursor = 0
            var localCursor = 0
            var failureCount = 0

            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let response = try await APIService.shared.fetchTwilioAIAudioMirror(
                        sessionKey: sessionKey,
                        mirrorToken: mirrorToken,
                        remoteCursor: remoteCursor,
                        localCursor: localCursor,
                        accessToken: appAccessToken
                    )

                    remoteCursor = response.remoteCursor
                    localCursor = response.localCursor

                    let remoteSamples = Self.decodePCM16Base64(response.remotePCM16Base64)
                    let localSamples = Self.decodePCM16Base64(response.localPCM16Base64)
                    if !remoteSamples.isEmpty {
                        self.appendSamples(remoteSamples, source: .remote)
                    }
                    if !localSamples.isEmpty {
                        self.appendSamples(localSamples, source: .local)
                    }
                    if !remoteSamples.isEmpty || !localSamples.isEmpty {
                        failureCount = 0
                        self.performanceProfile.logCall("[TwilioCall] AI audio mirror +remote=\(remoteSamples.count) +local=\(localSamples.count) session=\(sessionKey)")
                    }
                } catch {
                    failureCount += 1
                    if failureCount == 1 || failureCount % 10 == 0 {
                        print("[TwilioCall] AI audio mirror poll failed (\(failureCount)): \(error.localizedDescription)")
                    }
                }

                try? await Task.sleep(nanoseconds: self.performanceProfile.audioMirrorPollNanoseconds)
            }
        }
        print("[TwilioCall] AI audio mirror polling started session=\(sessionKey)")
    }

    @discardableResult
    func startMirroredAudioPollingForPendingInvite(appAccessToken: String) -> Bool {
        guard let context = cacheAudioMirrorContextForPendingInvite() ?? audioMirrorContext else { return false }
        startMirroredAudioPolling(
            sessionKey: context.sessionKey,
            mirrorToken: context.mirrorToken,
            appAccessToken: appAccessToken
        )
        return true
    }

    @discardableResult
    func startMirroredAudioPollingForCurrentCallContext(appAccessToken: String) -> Bool {
        guard let context = audioMirrorContext else {
            print("[TwilioCall] No cached AI audio mirror context for active call")
            return false
        }
        startMirroredAudioPolling(
            sessionKey: context.sessionKey,
            mirrorToken: context.mirrorToken,
            appAccessToken: appAccessToken
        )
        return true
    }

    @discardableResult
    private func cacheAudioMirrorContextForPendingInvite() -> AudioMirrorContext? {
        guard let params = activeCallInvite?.customParameters else {
            print("[TwilioCall] Pending invite has no AI audio mirror parameters")
            return nil
        }
        let sessionKey = params["session"] ?? params["Session"] ?? ""
        let mirrorToken = params["mirror_token"] ?? params["MirrorToken"] ?? params["mirrorToken"] ?? ""
        guard !sessionKey.isEmpty, !mirrorToken.isEmpty else {
            print("[TwilioCall] Pending invite missing AI audio mirror session/token")
            return nil
        }
        let context = AudioMirrorContext(sessionKey: sessionKey, mirrorToken: mirrorToken)
        audioMirrorContext = context
        return context
    }

    private func stopMirroredAudioPolling(clearContext: Bool = true) {
        audioMirrorTask?.cancel()
        audioMirrorTask = nil
        audioMirrorSessionKey = nil
        audioMirrorToken = nil
        if clearContext {
            audioMirrorContext = nil
        }
    }

    nonisolated private static func decodePCM16Base64(_ encoded: String?) -> [Float] {
        guard
            let encoded,
            let data = Data(base64Encoded: encoded),
            data.count >= 2
        else {
            return []
        }

        var samples: [Float] = []
        samples.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var index = 0
            while index + 1 < data.count {
                let value = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let signed = Int16(bitPattern: value)
                samples.append(max(Float(-1.0), min(Float(1.0), Float(signed) / 32768.0)))
                index += 2
            }
        }
        return samples
    }

    private enum AudioStreamSource {
        case remote
        case local
    }

    nonisolated private func appendSamples(_ samples: [Float], source: AudioStreamSource) {
        guard !samples.isEmpty else { return }
        let queue = (source == .remote) ? remoteBufferQueue : localBufferQueue
        queue.async { [weak self] in
            guard let self else { return }
            switch source {
            case .remote:
                self.remoteAudioBuffer.append(contentsOf: samples)
                if self.remoteAudioBuffer.count > self.maxBufferSamples {
                    self.remoteAudioBuffer.removeFirst(self.remoteAudioBuffer.count - self.maxBufferSamples)
                }
                if self.remoteAudioBuffer.count >= AudioConfiguration.analysisWindowSamples {
                    Task { @MainActor in AIAnalysisService.shared.requestImmediateAnalysis() }
                }
            case .local:
                self.localAudioBuffer.append(contentsOf: samples)
                if self.localAudioBuffer.count > self.maxBufferSamples {
                    self.localAudioBuffer.removeFirst(self.localAudioBuffer.count - self.maxBufferSamples)
                }
                if self.localAudioBuffer.count >= AudioConfiguration.analysisWindowSamples {
                    Task { @MainActor in AIAnalysisService.shared.requestImmediateAnalysis() }
                }
            }
        }
    }
}

// MARK: - CallDelegate

extension TwilioCallService: CallDelegate {

    func callDidStartRinging(call: TwilioVoice.Call) {
        print("[TwilioCall] Ringing...")
    }

    nonisolated func callDidConnect(call: TwilioVoice.Call) {
        Task { @MainActor in
            self.isConnected = true
            self.isStreaming = true
            self.remoteBufferQueue.async { self.remoteAudioBuffer.removeAll() }
            self.localBufferQueue.async { self.localAudioBuffer.removeAll() }
            self.onConnected?()
            print("[TwilioCall] Connected! SID: \(call.sid)")
        }
    }

    nonisolated func callDidDisconnect(call: TwilioVoice.Call, error: (any Error)?) {
        Task { @MainActor in
            if let error = error {
                print("[TwilioCall] Disconnected with error: \(error.localizedDescription)")
            } else {
                print("[TwilioCall] Disconnected normally")
            }
            self.activeCall = nil
            self.stopMirroredAudioPolling()
            self.isConnected = false
            self.isStreaming = false
            self.onDisconnected?()
        }
    }

    nonisolated func callDidFailToConnect(call: TwilioVoice.Call, error: any Error) {
        Task { @MainActor in
            let nsError = error as NSError
            let message = "Failed to connect (\(nsError.domain):\(nsError.code)): \(error.localizedDescription)"
            print("[TwilioCall] \(message)")
            CallDebugReporter.post("twilio_call_failed_to_connect", details: ["domain": nsError.domain, "code": "\(nsError.code)", "message": error.localizedDescription])
            self.activeCall = nil
            self.stopMirroredAudioPolling()
            self.isConnected = false
            self.isStreaming = false
            self.onConnectFailed?(message)
            self.onDisconnected?()
        }
    }
}

// MARK: - NotificationDelegate (incoming call handling)

extension TwilioCallService: NotificationDelegate {

    nonisolated func callInviteReceived(callInvite: TwilioVoice.CallInvite) {
        // TwilioVoiceSDK.handleNotification was called with delegateQueue: nil
        // from the main thread, so this delegate method is invoked synchronously
        // on the main thread. We MUST propagate synchronously all the way down
        // to CXProvider.reportNewIncomingCall — any Task { @MainActor in ... }
        // bounce here would violate the iOS 13+ PushKit contract and get the
        // app killed / VoIP pushes blackholed. See AppDelegate.pushRegistry.
        MainActor.assumeIsolated {
            print("[TwilioCall] Incoming call from: \(callInvite.from ?? "unknown")")
            CallDebugReporter.post("twilio_call_invite_received", details: ["from": callInvite.from ?? "unknown"])
            self.activeCallInvite = callInvite
            self.onIncomingCall?(callInvite.from ?? "unknown", callInvite.uuid)
        }
    }

    nonisolated func cancelledCallInviteReceived(cancelledCallInvite: TwilioVoice.CancelledCallInvite, error: Error) {
        MainActor.assumeIsolated {
            print("[TwilioCall] Incoming call cancelled: \(error.localizedDescription)")
            CallDebugReporter.post("twilio_call_invite_cancelled", details: ["error": error.localizedDescription])
            self.activeCallInvite = nil
            self.completePendingPushHandling()
        }
    }
}

final class VeriCallTwilioAudioDevice: NSObject, AudioDevice {

    var onRemoteSamples: (([Float], Double) -> Void)?
    var onLocalSamples: (([Float], Double) -> Void)?

    private var renderContext: AudioDeviceContext?
    private var captureContext: AudioDeviceContext?
    private var audioUnit: AudioUnit?
    private let stateLock = NSLock()
    private var speakerEnabled = false

    private let preferredSampleRate: Double = 48_000
    private let preferredIOBufferDuration: TimeInterval = 0.02
    private let maxFramesPerBuffer: UInt32
    private let captureBufferList: UnsafeMutablePointer<AudioBufferList>
    private var activeStreamSampleRate: Double = 48_000

    override init() {
        self.maxFramesPerBuffer = Self.detectMaximumFramesPerBuffer()
        self.captureBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.captureBufferList.initialize(to: AudioBufferList())
        super.init()
        captureBufferList.pointee.mNumberBuffers = 1
        captureBufferList.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        configureAudioSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        teardownAudioUnit()
        captureBufferList.deinitialize(count: 1)
        captureBufferList.deallocate()
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        speakerEnabled = enabled
        configureAudioSession()
    }

    func audioSessionActivated() {
        stateLock.lock()
        let contexts = [renderContext, captureContext].compactMap { $0 }
        stateLock.unlock()

        guard !contexts.isEmpty else {
            CallDebugReporter.post("twilio_audio_session_activated_no_context")
            return
        }

        contexts.forEach { AudioSessionActivated(context: $0) }
        CallDebugReporter.post("twilio_audio_session_activated", details: ["contexts": "\(contexts.count)"])
    }

    func audioSessionDeactivated() {
        stateLock.lock()
        let contexts = [renderContext, captureContext].compactMap { $0 }
        stateLock.unlock()

        guard !contexts.isEmpty else {
            CallDebugReporter.post("twilio_audio_session_deactivated_no_context")
            return
        }

        contexts.forEach { AudioSessionDeactivated(context: $0) }
        CallDebugReporter.post("twilio_audio_session_deactivated", details: ["contexts": "\(contexts.count)"])
    }

    func renderFormat() -> AudioFormat? {
        AudioFormat(channels: AudioFormat.ChannelsMono,
                    sampleRate: Self.twilioAudioSampleRate(for: activeStreamSampleRate),
                    framesPerBuffer: Int(maxFramesPerBuffer))
    }

    func initializeRenderer() -> Bool {
        return true
    }

    func startRendering(_ context: AudioDeviceContext) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        renderContext = context
        configureAudioSession()
        if !ensureAudioUnitStarted() {
            return false
        }
        return true
    }

    func stopRendering() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        renderContext = nil
        stopAudioUnitIfIdle()
        return true
    }

    func captureFormat() -> AudioFormat? {
        AudioFormat(channels: AudioFormat.ChannelsMono,
                    sampleRate: Self.twilioAudioSampleRate(for: activeStreamSampleRate),
                    framesPerBuffer: Int(maxFramesPerBuffer))
    }

    func initializeCapturer() -> Bool {
        true
    }

    func startCapturing(_ context: AudioDeviceContext) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        captureContext = context
        configureAudioSession()
        if !ensureAudioUnitStarted() {
            return false
        }
        return true
    }

    func stopCapturing() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        captureContext = nil
        stopAudioUnitIfIdle()
        return true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: audioSessionOptions(for: session))
        } catch {
            print("[TwilioAudioDevice] Audio session category failed: \(error)")
        }

        preferHandsFreeInputIfAvailable(for: session)

        do {
            if session.maximumInputNumberOfChannels > 0 {
                try session.setPreferredInputNumberOfChannels(1)
            }
        } catch {
            print("[TwilioAudioDevice] Preferred input channel count unavailable for route \(Self.routeSummary(session.currentRoute)): \(error)")
        }

        do {
            try session.setPreferredSampleRate(Self.preferredHardwareSampleRate(for: session.currentRoute))
        } catch {
            print("[TwilioAudioDevice] Preferred sample rate unavailable for route \(Self.routeSummary(session.currentRoute)): \(error)")
        }

        do {
            try session.setPreferredIOBufferDuration(preferredIOBufferDuration)
        } catch {
            print("[TwilioAudioDevice] Preferred IO buffer unavailable for route \(Self.routeSummary(session.currentRoute)): \(error)")
        }

        do {
            try session.setActive(true)
        } catch {
            print("[TwilioAudioDevice] Audio session activation failed: \(error)")
        }

        activeStreamSampleRate = Self.supportedStreamSampleRate(for: session)
        print("[TwilioAudioDevice] Active stream rate \(activeStreamSampleRate)Hz route \(Self.routeSummary(session.currentRoute))")
        applySpeakerOverride(for: session)
    }

    private func audioSessionOptions(for session: AVAudioSession) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if speakerEnabled && !Self.isExternalAudioRouteActive(session.currentRoute) {
            options.insert(.defaultToSpeaker)
        }
        return options
    }

    private func applySpeakerOverride(for session: AVAudioSession = .sharedInstance()) {
        do {
            let shouldForceSpeaker = speakerEnabled && !Self.isExternalAudioRouteActive(session.currentRoute)
            try session.overrideOutputAudioPort(shouldForceSpeaker ? .speaker : .none)
        } catch {
            print("[TwilioAudioDevice] Failed to apply speaker route \(speakerEnabled): \(error)")
        }
    }

    private func preferHandsFreeInputIfAvailable(for session: AVAudioSession) {
        guard !Self.isCarAudioRouteActive(session.currentRoute) else { return }
        guard let handsFreeInput = session.availableInputs?.first(where: { input in
            input.portType == .bluetoothHFP || input.portType == .bluetoothLE
        }) else {
            return
        }

        do {
            try session.setPreferredInput(handsFreeInput)
        } catch {
            print("[TwilioAudioDevice] Preferred hands-free input unavailable: \(error)")
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        print("[TwilioAudioDevice] Route changed: \(Self.routeSummary(session.currentRoute))")
        restartAudioUnitAfterRouteChange()
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            stateLock.lock()
            let hasActiveContext = renderContext != nil || captureContext != nil
            if hasActiveContext, let audioUnit {
                AudioOutputUnitStop(audioUnit)
            }
            stateLock.unlock()
        case .ended:
            restartAudioUnitAfterRouteChange()
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        restartAudioUnitAfterRouteChange()
    }

    private func restartAudioUnitAfterRouteChange() {
        stateLock.lock()
        let shouldRestart = renderContext != nil || captureContext != nil
        if shouldRestart {
            teardownAudioUnit()
        }
        configureAudioSession()
        if shouldRestart {
            _ = ensureAudioUnitStarted()
        }
        stateLock.unlock()
    }

    private static func isExternalAudioRouteActive(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.inputs.contains { input in
            isExternalInput(input.portType)
        } || route.outputs.contains { output in
            isExternalOutput(output.portType)
        }
    }

    private static func isCarAudioRouteActive(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.inputs.contains { $0.portType == .carAudio } || route.outputs.contains { $0.portType == .carAudio }
    }

    private static func isExternalInput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .carAudio, .headsetMic, .usbAudio:
            return true
        default:
            return false
        }
    }

    private static func isExternalOutput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .carAudio, .headphones, .airPlay, .usbAudio, .HDMI:
            return true
        default:
            return false
        }
    }

    private static func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)]"
    }

    private static func preferredHardwareSampleRate(for route: AVAudioSessionRouteDescription) -> Double {
        isCarAudioRouteActive(route) || isBluetoothHandsFreeRouteActive(route) ? 16_000 : 48_000
    }

    private static func supportedStreamSampleRate(for session: AVAudioSession) -> Double {
        let route = session.currentRoute
        let hardwareRate = session.sampleRate > 0 ? session.sampleRate : preferredHardwareSampleRate(for: route)
        let supportedRates: [Double] = [8_000, 16_000, 24_000, 32_000, 44_100, 48_000]
        return supportedRates.min(by: { abs($0 - hardwareRate) < abs($1 - hardwareRate) }) ?? 48_000
    }

    private static func twilioAudioSampleRate(for sampleRate: Double) -> UInt32 {
        switch Int(sampleRate.rounded()) {
        case 8_000:
            return AudioFormat.SampleRate8000
        case 16_000:
            return AudioFormat.SampleRate16000
        case 24_000:
            return AudioFormat.SampleRate24000
        case 32_000:
            return AudioFormat.SampleRate32000
        case 44_100:
            return AudioFormat.SampleRate44100
        default:
            return AudioFormat.SampleRate48000
        }
    }

    private static func isBluetoothHandsFreeRouteActive(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.inputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE } ||
        route.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
    }

    private func ensureAudioUnitStarted() -> Bool {
        if audioUnit == nil, !setupAudioUnit() {
            return false
        }
        guard let audioUnit else { return false }
        let status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            print("[TwilioAudioDevice] Could not start audio unit: \(status)")
            return false
        }
        return true
    }

    private func stopAudioUnitIfIdle() {
        guard renderContext == nil && captureContext == nil else { return }
        guard let audioUnit else { return }
        let status = AudioOutputUnitStop(audioUnit)
        if status != noErr {
            print("[TwilioAudioDevice] Could not stop audio unit: \(status)")
        }
        teardownAudioUnit()
    }

    private func teardownAudioUnit() {
        guard let audioUnit else { return }
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
    }

    private func setupAudioUnit() -> Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            print("[TwilioAudioDevice] Could not find VoiceProcessingIO component")
            return false
        }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            print("[TwilioAudioDevice] Could not create VoiceProcessingIO instance")
            return false
        }
        audioUnit = unit

        var enableIO: UInt32 = 1
        if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)) != noErr {
            print("[TwilioAudioDevice] Could not enable output bus")
            teardownAudioUnit()
            return false
        }

        if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)) != noErr {
            print("[TwilioAudioDevice] Could not enable input bus")
            teardownAudioUnit()
            return false
        }

        var streamDescription = makeStreamDescription()
        if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) != noErr {
            print("[TwilioAudioDevice] Could not set input bus stream format")
            teardownAudioUnit()
            return false
        }

        if AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) != noErr {
            print("[TwilioAudioDevice] Could not set output bus stream format")
            teardownAudioUnit()
            return false
        }

        var renderCallback = AURenderCallbackStruct(
            inputProc: veriCallTwilioPlayoutCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        if AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Output, 0, &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) != noErr {
            print("[TwilioAudioDevice] Could not set render callback")
            teardownAudioUnit()
            return false
        }

        var captureCallback = AURenderCallbackStruct(
            inputProc: veriCallTwilioRecordCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Input, 1, &captureCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) != noErr {
            print("[TwilioAudioDevice] Could not set capture callback")
            teardownAudioUnit()
            return false
        }

        var status = AudioUnitInitialize(unit)
        var attempts = 0
        while status != noErr && attempts < 5 {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.1)
            status = AudioUnitInitialize(unit)
        }
        if status != noErr {
            print("[TwilioAudioDevice] Could not initialize audio unit: \(status)")
            teardownAudioUnit()
            return false
        }

        return true
    }

    private func makeStreamDescription() -> AudioStreamBasicDescription {
        return AudioStreamBasicDescription(
            // Keep Twilio and VoiceProcessingIO on the same clock for the active
            // route. The AI path still resamples this stream to 16 kHz above.
            mSampleRate: activeStreamSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private static func detectMaximumFramesPerBuffer() -> UInt32 {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return 3072 }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return 3072 }
        defer { AudioComponentInstanceDispose(unit) }
        var framesPerSlice: UInt32 = 3072
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &framesPerSlice, &propertySize)
        return status == noErr ? framesPerSlice : 3072
    }

    fileprivate func handlePlayout(ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        guard let renderContext else {
            zero(ioData)
            return noErr
        }

        let buffer = ioData.pointee.mBuffers
        guard let data = buffer.mData else {
            zero(ioData)
            return noErr
        }

        let byteCount = Int(buffer.mDataByteSize)
        AudioDeviceReadRenderData(context: renderContext,
                                  data: data.assumingMemoryBound(to: Int8.self),
                                  sizeInBytes: byteCount)

        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let int16Samples = data.assumingMemoryBound(to: Int16.self)
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            floatSamples[i] = Float(int16Samples[i]) / Float(Int16.max)
        }
        onRemoteSamples?(floatSamples, activeStreamSampleRate)
        return noErr
    }

    fileprivate func handleRecord(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
                              timestamp: UnsafePointer<AudioTimeStamp>?,
                              numFrames: UInt32) -> OSStatus {
        guard let captureContext, let audioUnit else { return noErr }
        guard let timestamp else { return noErr }

        captureBufferList.pointee.mNumberBuffers = 1
        captureBufferList.pointee.mBuffers.mNumberChannels = 1
        captureBufferList.pointee.mBuffers.mDataByteSize = numFrames * 2
        captureBufferList.pointee.mBuffers.mData = nil

        var localFlags = actionFlags?.pointee ?? []
        let status = AudioUnitRender(audioUnit, &localFlags, timestamp, 1, numFrames, captureBufferList)
        guard status == noErr else { return status }
        guard let data = captureBufferList.pointee.mBuffers.mData else { return noErr }

        let byteCount = Int(captureBufferList.pointee.mBuffers.mDataByteSize)
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let int16Samples = data.assumingMemoryBound(to: Int16.self)
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            floatSamples[i] = Float(int16Samples[i]) / Float(Int16.max)
        }
        onLocalSamples?(floatSamples, activeStreamSampleRate)

        AudioDeviceWriteCaptureData(context: captureContext,
                                    data: data.assumingMemoryBound(to: Int8.self),
                                    sizeInBytes: byteCount)
        return noErr
    }

    private func zero(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for audioBuffer in buffers {
            guard let out = audioBuffer.mData else { continue }
            memset(out, 0, Int(audioBuffer.mDataByteSize))
        }
    }
}

private func veriCallTwilioPlayoutCallback(inRefCon: UnsafeMutableRawPointer,
                                           ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                           inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                           inBusNumber: UInt32,
                                           inNumberFrames: UInt32,
                                           ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let device = Unmanaged<VeriCallTwilioAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    return device.handlePlayout(ioData: ioData)
}

private func veriCallTwilioRecordCallback(inRefCon: UnsafeMutableRawPointer,
                                          ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                          inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                          inBusNumber: UInt32,
                                          inNumberFrames: UInt32,
                                          ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let device = Unmanaged<VeriCallTwilioAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    return device.handleRecord(actionFlags: ioActionFlags, timestamp: inTimeStamp, numFrames: inNumberFrames)
}
#endif
