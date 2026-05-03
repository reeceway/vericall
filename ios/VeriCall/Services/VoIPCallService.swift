import Foundation
import AVFoundation
import AudioToolbox
import Combine
import Contacts
import UIKit

/// Manages the live Twilio call lifecycle for the app.
///
/// Transport:
///   Twilio Voice SDK owns invite delivery, ringing, connection, and media.
///
/// AI analysis:
///   Local spoof-only inference runs in parallel from the tapped Twilio audio
///   buffers and updates the in-call UI without affecting call routing.
@MainActor
final class VoIPCallService: ObservableObject {

    static let shared = VoIPCallService()

    // MARK: - Published State

    @Published var callState: VoIPCallState = .idle
    @Published var currentCall: VoIPCall?
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var callDuration: TimeInterval = 0

    /// Latest AI analysis results (nil while loading)
    @Published var spoofResult: SpoofResult?
    @Published var speakerResult: SpeakerResult?
    @Published var localSpoofResult: SpoofResult?
    @Published var localSpeakerResult: SpeakerResult?
    @Published var isDeviceVerified: Bool = false
    @Published var hasRemoteEnrolledVoiceprint: Bool = false
    @Published var aiDiagnosticsText: String = "idle"

    // MARK: - Services

    private let callTransport = CallTransportService.shared
    private let aiAnalysis = AIAnalysisService.shared
    private let callKit = CallKitManager.shared
    private let performanceProfile = AppPerformanceProfile.shared

    // MARK: - Internals

    private var durationTimer: Timer?
    private var connectTimeoutTimer: Timer?
    private var aiCancellable: AnyCancellable?
    private var localSpoofCancellable: AnyCancellable?
    private var latestRawRemoteSpoofResult: SpoofResult?
    private var latestRawLocalSpoofResult: SpoofResult?
    private var lastStableRemoteSpoofResult: SpoofResult?
    private var remoteFakeCandidateCount = 0
    private var suspiciousSpeechWindows = 0
    private var suspiciousSpeechSeconds: TimeInterval = 0
    private var lastSuspiciousSpeechAt: Date?
    private var hasSentLikelySyntheticAlert = false
    private var hasSentHighSyntheticAlert = false
    private var callKitTrustDisplayState: CallKitTrustDisplayState = .normal
    private let remoteFakeConfirmationWindows = 2
    private let remoteStrongSyntheticScore: Float = AudioConfiguration.spoofSyntheticCandidateThresholdCall
    private let remoteExtremeFakeScore: Float = 0.995
    private let suspiciousSpeechDisplaySeconds: TimeInterval = 2.0
    private let suspiciousSpeechAlertSeconds: TimeInterval = 5.0
    private static let contactCacheQueue = DispatchQueue(label: "com.vicall.incoming-contact-cache")
    private nonisolated(unsafe) static var cachedContactNamesByDigits: [String: String] = [:]

    private init() {
        setupCallKitCallbacks()
        setupCallTransportCallbacks()
        observeAIResults()
        refreshIncomingContactCache()
        callTransport.configure()
    }

    // MARK: - Outgoing Call

    func initiateCall(to contact: Contact) async {
        guard callState == .idle else { return }

        let callId = UUID().uuidString
        guard let twilioTargetIdentity = resolveTwilioTargetIdentity(for: contact) else {
            callState = .failed("Missing valid Twilio destination.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.resetCall()
            }
            print("[VoIPCall] Refusing to dial contact without a valid Twilio identity: id=\(contact.id) phone=\(contact.phoneNumber ?? "nil")")
            return
        }
        currentCall = VoIPCall(
            id: callId,
            remoteUserId: twilioTargetIdentity,
            remoteName: contact.displayName,
            remotePhone: contact.phoneNumber,
            direction: .outgoing
        )
        callState  = .calling
        spoofResult   = nil
        speakerResult = nil
        localSpoofResult = nil
        localSpeakerResult = nil
        resetSpoofAlertState()
        aiAnalysis.prepareForFirstCall()
        callTransport.joinCall(callId, remoteUserId: twilioTargetIdentity, remotePeerName: nil)
        callState = .connecting
        startConnectTimeout()
        print("[VoIPCall] Outgoing Twilio call to \(contact.displayName) using identity \(twilioTargetIdentity)")
    }

    // MARK: - Answer

    func answerCall() async {
        guard let call = currentCall else {
            CallDebugReporter.post("answer_call_ignored", details: ["reason": "missing_current_call", "state": "\(callState)"])
            return
        }
        guard callState == .ringing else {
            CallDebugReporter.post("answer_call_ignored", details: ["reason": "not_ringing", "state": "\(callState)", "callId": call.id])
            return
        }
        callState = .connecting
        aiAnalysis.prepareForCallKitAnswer()
        callTransport.joinCall(call.id, remoteUserId: call.remoteUserId, remotePeerName: nil)
        startConnectTimeout()
        print("[VoIPCall] Accepting Twilio invite for \(call.remoteUserId)")
        CallDebugReporter.post("answer_call_started", details: ["callId": call.id, "remote": call.remoteUserId])
    }

    // MARK: - Decline / End

    func declineCall() {
        guard let call = currentCall else { return }
        callTransport.leaveCall()
        saveCallRecord(state: .declined)
        resetCall()
    }

    func endCall() {
        guard currentCall != nil else { return }
        tearDownCall(recordState: .ended)
    }

    // MARK: - Controls

    func toggleMute() {
        isMuted.toggle()
        callTransport.setMuted(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        callTransport.setSpeaker(isSpeakerOn)
    }

    // MARK: - Signaling Router

    func handleSignalingMessage(_ json: [String: Any], type: String) {
        print("[VoIPCall] Ignoring legacy signaling message while Twilio is active: \(type) \(json)")
    }

    // MARK: - Computed

    var formattedDuration: String {
        let m = Int(callDuration) / 60
        let s = Int(callDuration) % 60
        return String(format: "%02d:%02d", m, s)
    }

    func verificationStatusSummary() -> String {
        let remoteSpoof = spoofResult.map { spoofSummary(prefix: "Remote", result: $0) } ?? "Remote Voice: Analyzing..."
        let localSpoof = localSpoofResult.map { spoofSummary(prefix: "Local", result: $0) } ?? "Local Voice: Analyzing..."
        return "\(remoteSpoof) • \(localSpoof)"
    }

    // MARK: - Private

    private func setupCallTransportCallbacks() {
        callTransport.onIncomingCall = { [weak self] identity, inviteUUID in
            // Called synchronously from the PushKit delegate's call stack
            // (see AppDelegate.pushRegistry and TwilioCallService.callInviteReceived).
            // Must NOT wrap in Task — CXProvider.reportNewIncomingCall has to
            // be called before the PushKit delegate returns or iOS 13+ will
            // terminate the app and suppress future VoIP pushes.
            MainActor.assumeIsolated {
                self?.handleTwilioIncomingCall(identity: identity, inviteUUID: inviteUUID)
            }
        }
        callTransport.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .connecting || self.callState == .calling else { return }
                self.stopConnectTimeout()
                self.callState = .connected
                self.startDurationTimer()
                self.startAIAnalysis()
                if let call = self.currentCall {
                    Task { await self.callKit.reportCallConnected(callId: call.id) }
                }
                print("[VoIPCall] Connected via Twilio — spoof analysis started")
            }
        }
        callTransport.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .connected else { return }
                self.tearDownCall(recordState: .ended)
            }
        }
        callTransport.onConnectFailed = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopConnectTimeout()
                self.callState = .failed(message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.resetCall()
                }
            }
        }
    }

    private func handleTwilioIncomingCall(identity: String, inviteUUID: UUID?) {
        guard Constants.preferredCallProvider == .twilioVoice else { return }
        guard callState == .idle else {
            print("[VoIPCall] Ignoring incoming Twilio call while busy")
            CallDebugReporter.post("incoming_call_ignored_busy", details: ["from": identity, "state": "\(callState)"])
            return
        }

        let callId = (inviteUUID ?? UUID()).uuidString
        let caller = resolveIncomingCaller(identity: identity)
        currentCall = VoIPCall(
            id: callId,
            remoteUserId: identity,
            remoteName: caller.displayName,
            remotePhone: caller.phoneNumber,
            direction: .incoming
        )
        callState = .ringing
        isDeviceVerified = false
        hasRemoteEnrolledVoiceprint = false
        spoofResult = nil
        localSpoofResult = nil
        speakerResult = nil
        localSpeakerResult = nil
        resetSpoofAlertState()
        aiAnalysis.prepareForFirstCall()
        print("[VoIPCall] Incoming Twilio invite from \(identity) resolved=\(caller.displayName) uuid=\(callId)")
        CallDebugReporter.post("incoming_call_state_created", details: ["from": identity, "displayName": caller.displayName, "uuid": callId])
        reportIncomingCallToCallKit(
            callId: callId,
            identity: identity,
            callerHandle: caller.phoneNumber ?? identity,
            callKitCallerName: caller.callKitName
        )
    }

    private func setupCallKitCallbacks() {
        callKit.onAnswerCall = { [weak self] callUUID in
            Task { @MainActor [weak self] in
                guard let self, self.currentCall?.id == callUUID.uuidString else { return }
                await self.answerCall()
            }
        }

        callKit.onEndCall = { [weak self] callUUID in
            Task { @MainActor [weak self] in
                guard let self, self.currentCall?.id == callUUID.uuidString else { return }
                switch self.callState {
                case .ringing:
                    self.declineCall()
                case .calling, .connecting, .connected:
                    self.endCall()
                default:
                    break
                }
            }
        }

        callKit.onMuteCall = { [weak self] callUUID, muted in
            Task { @MainActor [weak self] in
                guard let self, self.currentCall?.id == callUUID.uuidString else { return }
                self.isMuted = muted
                self.callTransport.setMuted(muted)
            }
        }
    }

    private func reportIncomingCallToCallKit(
        callId: String,
        identity: String,
        callerHandle: String,
        callKitCallerName: String
    ) {
        let call = Call(
            id: callId,
            callerId: callerHandle,
            callerName: callKitCallerName,
            recipientId: "me",
            recipientName: UserDefaults.standard.string(forKey: "userName") ?? "Me",
            direction: .incoming,
            state: .ringing,
            startedAt: Date(),
            endedAt: nil,
            isVerified: true
        )

        // Called synchronously from the PushKit delegate's call stack.
        // reportIncomingCall below is now non-async and calls
        // CXProvider.reportNewIncomingCall synchronously, satisfying the
        // iOS 13+ PushKit/CallKit contract. No Task wrapper here.
        callKit.reportIncomingCall(
            call: call,
            reportCompletion: { _ in
#if canImport(TwilioVoice)
                // reportNewIncomingCall has already been issued at this point,
                // so the PushKit contract is satisfied and it is safe to
                // release the PushKit completion from a main-actor Task.
                Task { @MainActor in
                    TwilioCallService.shared.completePendingPushHandling()
                }
#endif
            }
        ) { [weak self] accepted in
            Task { @MainActor [weak self] in
                guard let self, self.currentCall?.id == callId else { return }
                if accepted {
                    await self.answerCall()
                } else {
                    self.declineCall()
                }
            }
        }
    }

    private func resolveIncomingCaller(identity: String) -> IncomingCallerPresentation {
        let phoneNumber = Constants.phoneNumber(fromTwilioIdentity: identity)
        let contactName = Self.cachedContactName(forPhoneNumber: phoneNumber)
        let fallbackName = phoneNumber ?? Constants.normalizedTwilioIdentity(identity) ?? identity
        let displayName = contactName ?? fallbackName
        return IncomingCallerPresentation(
            displayName: displayName,
            phoneNumber: phoneNumber,
            callKitName: "\(Constants.callKitDisplayName) from \(displayName)"
        )
    }

    private func refreshIncomingContactCache() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }

        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey
        ] as [CNKeyDescriptor]

        DispatchQueue.global(qos: .utility).async {
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: keys)
            var cache: [String: String] = [:]

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let name = Self.displayName(for: contact)
                    guard !name.isEmpty else { return }

                    for number in contact.phoneNumbers {
                        let digits = Constants.canonicalPhoneDigits(number.value.stringValue)
                        guard !digits.isEmpty else { continue }
                        cache[digits] = name
                    }
                }

                Self.contactCacheQueue.async {
                    Self.cachedContactNamesByDigits = cache
                    DispatchQueue.main.async {
                        CallDebugReporter.post("incoming_contact_cache_refreshed", details: ["count": "\(cache.count)"])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    CallDebugReporter.post("incoming_contact_cache_failed", details: ["error": String(describing: error)])
                }
            }
        }
    }

    private static func cachedContactName(forPhoneNumber phoneNumber: String?) -> String? {
        let digits = Constants.canonicalPhoneDigits(phoneNumber)
        guard !digits.isEmpty else { return nil }
        return contactCacheQueue.sync { cachedContactNamesByDigits[digits] }
    }

    private static func displayName(for contact: CNContact) -> String {
        let personalName = [contact.givenName, contact.familyName]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        if !personalName.isEmpty {
            return personalName
        }

        return contact.organizationName
    }

    private func startConnectTimeout() {
        stopConnectTimeout()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .connecting || self.callState == .calling else { return }
                print("[VoIPCall] ⚠️ Call transport connection timed out")
                self.callState = .failed("Connection timed out. Check network and transport configuration.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.resetCall() }
            }
        }
    }

    private func stopConnectTimeout() {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
    }

    private func observeAIResults() {
        aiCancellable = aiAnalysis.$latestSpoof
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self else { return }
                self.latestRawRemoteSpoofResult = result
                self.refreshDisplayedSpoofResult()
            }

        localSpoofCancellable = aiAnalysis.$latestLocalSpoof
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self else { return }
                self.localSpoofResult = result
                self.latestRawLocalSpoofResult = result
                self.refreshDisplayedSpoofResult()
            }

        aiAnalysis.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let audio = self.callTransport.debugAudioSnapshot()
                self.aiDiagnosticsText = "\(self.aiAnalysis.diagnostics) | rf=\(audio.remoteFrames) lf=\(audio.localFrames) rs=\(audio.remoteSamples) ls=\(audio.localSamples)"
            }
            .store(in: &diagnosticCancellables)
    }

    private func startAIAnalysis() {
        aiAnalysis.prepareForCallKitAnswer()
        callTransport.ensureAIAudioMirrorRunning()
        aiAnalysis.start(
            remoteEnrolledEmbedding: nil,
            localEnrolledEmbedding: nil
        )
        startDiagnosticsTicker()
        scheduleAIAudioMirrorWatchdog()
        print("[VoIPCall] Spoof analysis started (diagnostics=\(aiAnalysis.diagnostics))")
    }

    private func refreshDisplayedSpoofResult() {
        spoofResult = applyRemoteTrustPolicy(to: otherPartySpoofResultForCurrentCall())
    }

    private func otherPartySpoofResultForCurrentCall() -> SpoofResult? {
        guard let currentCall else {
            return latestRawRemoteSpoofResult
        }

        switch currentCall.direction {
        case .outgoing:
            return latestRawRemoteSpoofResult
        case .incoming:
            // The Twilio media stream is started on the originating call leg:
            // outbound track = audio sent back to caller, inbound track = caller audio.
            // For the receiving device, the caller's voice is therefore the mirrored local track.
            return latestRawLocalSpoofResult
        }
    }

    private func scheduleAIAudioMirrorWatchdog() {
        for delay in [3.0, 7.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.callState == .connected else { return }
                let audio = self.callTransport.debugAudioSnapshot()
                guard audio.remoteSamples < AudioConfiguration.analysisWindowSamples,
                      audio.localSamples < AudioConfiguration.analysisWindowSamples else { return }
                CallDebugReporter.post(
                    "ai_audio_mirror_watchdog_retry",
                    details: [
                        "delay": String(format: "%.1f", delay),
                        "remoteSamples": "\(audio.remoteSamples)",
                        "localSamples": "\(audio.localSamples)"
                    ]
                )
                self.callTransport.ensureAIAudioMirrorRunning()
            }
        }
    }

    private func applyRemoteTrustPolicy(to result: SpoofResult?) -> SpoofResult? {
        guard callState == .connected, let result else {
            remoteFakeCandidateCount = 0
            return lastStableRemoteSpoofResult
        }

        switch result.verdict {
        case .human:
            if lastStableRemoteSpoofResult?.verdict == .likelyFake || hasSentHighSyntheticAlert {
                return lastStableRemoteSpoofResult
            }
            remoteFakeCandidateCount = 0
            resetSuspiciousSpeech()
            lastStableRemoteSpoofResult = result
            updateCallKitTrustDisplay(.normal, result: result)
            return result

        case .likelyFake:
            guard isDecisionQualityRemoteResult(result) else {
                remoteFakeCandidateCount = 0
                return lastStableRemoteSpoofResult
            }

            remoteFakeCandidateCount += 1
            markSuspiciousSpeech(at: result.timestamp)

            let confirmed = remoteFakeCandidateCount >= remoteFakeConfirmationWindows
                || result.cloneProbability >= remoteExtremeFakeScore
            if confirmed {
                sendFlaggedSyntheticAlertIfNeeded(result: result)
                resetSuspiciousSpeech()
                lastStableRemoteSpoofResult = result
                return result
            }

            if lastStableRemoteSpoofResult?.verdict == .human {
                return lastStableRemoteSpoofResult
            }

            sendLikelySyntheticAlertIfNeeded(result: result)
            if lastStableRemoteSpoofResult == nil || suspiciousSpeechSeconds >= suspiciousSpeechDisplaySeconds {
                updateCallKitTrustDisplay(.likelySynthetic, result: result)
                CallDebugReporter.post(
                    "remote_spoof_fake_candidate",
                    details: [
                        "count": "\(remoteFakeCandidateCount)",
                        "score": String(format: "%.3f", result.cloneProbability),
                        "windows": "\(result.supportingWindows)",
                        "suspiciousSpeechSeconds": String(format: "%.2f", suspiciousSpeechSeconds)
                    ]
                )
                return warningRemoteSpoofResult(from: result)
            }
            return lastStableRemoteSpoofResult

        case .uncertain:
            remoteFakeCandidateCount = 0
            guard isDecisionQualityRemoteResult(result) else {
                return lastStableRemoteSpoofResult
            }

            if lastStableRemoteSpoofResult?.verdict == .human {
                resetSuspiciousSpeech()
                return lastStableRemoteSpoofResult
            }

            markSuspiciousSpeech(at: result.timestamp)

            if result.cloneProbability >= remoteStrongSyntheticScore {
                sendLikelySyntheticAlertIfNeeded(result: result)
                updateCallKitTrustDisplay(.likelySynthetic, result: result)
                let warning = warningRemoteSpoofResult(from: result)
                lastStableRemoteSpoofResult = warning
                return warning
            }

            sendLikelySyntheticAlertIfNeeded(result: result)

            if suspiciousSpeechSeconds >= suspiciousSpeechDisplaySeconds {
                updateCallKitTrustDisplay(.likelySynthetic, result: result)
                return warningRemoteSpoofResult(from: result)
            }
            return lastStableRemoteSpoofResult
        }
    }

    private func isAudibleRemoteResult(_ result: SpoofResult) -> Bool {
        if let rms = result.rms {
            return rms >= AudioConfiguration.spoofAudibleRMSCall * 0.35
        }
        return result.confidence == .high
    }

    private func isDecisionQualityRemoteResult(_ result: SpoofResult) -> Bool {
        guard result.confidence == .high, isAudibleRemoteResult(result) else {
            return false
        }
        if result.cloneProbability >= remoteStrongSyntheticScore {
            return true
        }
        if let speechActivity = result.speechActivityRatio {
            return speechActivity >= AudioConfiguration.spoofDecisionSpeechActivityCall
        }
        return true
    }

    private func warningRemoteSpoofResult(from result: SpoofResult) -> SpoofResult {
        SpoofResult(
            cloneProbability: AudioConfiguration.spoofHumanThresholdCall,
            confidence: .high,
            threshold: AudioConfiguration.spoofHumanThresholdCall,
            supportingWindows: max(result.supportingWindows, AudioConfiguration.spoofWarmupWindowsCall),
            processingTimeMs: result.processingTimeMs,
            rms: result.rms,
            speechActivityRatio: result.speechActivityRatio,
            timestamp: result.timestamp
        )
    }

    private func sendLikelySyntheticAlertIfNeeded(result: SpoofResult) {
        let strongSynthetic = result.cloneProbability >= remoteStrongSyntheticScore
        guard (strongSynthetic || suspiciousSpeechSeconds >= suspiciousSpeechAlertSeconds),
              !hasSentLikelySyntheticAlert,
              !hasSentHighSyntheticAlert else { return }

        hasSentLikelySyntheticAlert = true
        sendLiveSpoofAlert(severity: .suspectedSynthetic, result: result)
    }

    private func sendFlaggedSyntheticAlertIfNeeded(result: SpoofResult) {
        guard !hasSentHighSyntheticAlert else { return }
        hasSentHighSyntheticAlert = true
        sendLiveSpoofAlert(severity: .flaggedSynthetic, result: result)
    }

    private func sendLiveSpoofAlert(
        severity: LiveSpoofAlertSeverity,
        result: SpoofResult?
    ) {
        guard let callId = currentCall?.id else {
            CallDebugReporter.post(
                "live_spoof_alert_dropped",
                details: [
                    "reason": "missing_current_call",
                    "severity": severity.rawValue,
                    "callState": "\(callState)"
                ]
            )
            return
        }

        let title = severity.notificationTitle
        var traceDetails: [String: String] = [
            "callId": callId,
            "severity": severity.rawValue,
            "title": title,
            "verdict": result?.verdict.rawValue ?? "none",
            "score": result.map { String(format: "%.3f", $0.cloneProbability) } ?? "none",
            "windows": result.map { "\($0.supportingWindows)" } ?? "0",
            "rms": result?.rms.map { String(format: "%.5f", $0) } ?? "none",
            "buzzCount": "\(severity.buzzCount)",
            "callState": "\(callState)",
            "app_state": appStateDescription(),
            "suspiciousSpeechWindows": "\(suspiciousSpeechWindows)",
            "suspiciousSpeechSeconds": String(format: "%.2f", suspiciousSpeechSeconds),
            "fakeCandidateWindows": "\(remoteFakeCandidateCount)"
        ]
        callKit.debugStateDetails().forEach { traceDetails[$0.key] = $0.value }

        CallDebugReporter.post("live_spoof_alert_triggered", details: traceDetails)
        CallDebugReporter.post("live_spoof_alert_\(severity.rawValue)", details: traceDetails)
        updateCallKitTrustDisplay(
            severity == .flaggedSynthetic ? .highSynthetic : .likelySynthetic,
            result: result
        )

        Task {
            await NotificationService.shared.showLiveSpoofAlert(
                callId: callId,
                severity: severity
            )
        }
        buzz(count: severity.buzzCount, severity: severity, callId: callId)
    }

    private func buzz(count: Int, severity: LiveSpoofAlertSeverity, callId: String) {
        guard count > 0 else {
            CallDebugReporter.post(
                "live_spoof_buzz_skipped",
                details: ["callId": callId, "severity": severity.rawValue, "reason": "zero_count"]
            )
            return
        }

        CallDebugReporter.post(
            "live_spoof_buzz_scheduled",
            details: [
                "callId": callId,
                "severity": severity.rawValue,
                "count": "\(count)",
                "app_state": appStateDescription()
            ]
        )

        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.45) { [weak self] in
                let state = self?.appStateDescription() ?? "unknown"
                let details = [
                    "callId": callId,
                    "severity": severity.rawValue,
                    "pulse": "\(index + 1)",
                    "count": "\(count)",
                    "app_state": state
                ]

                CallDebugReporter.post("live_spoof_buzz_pulse_started", details: details)
                AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_Vibrate) {
                    CallDebugReporter.post("live_spoof_buzz_pulse_completed", details: details)
                }

                if UIApplication.shared.applicationState == .active {
                    UINotificationFeedbackGenerator().notificationOccurred(severity.feedbackType)
                    CallDebugReporter.post("live_spoof_ui_haptic_fired", details: details)
                } else {
                    CallDebugReporter.post("live_spoof_ui_haptic_skipped_not_active", details: details)
                }
            }
        }
    }

    private func appStateDescription() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func resetSpoofAlertState() {
        latestRawRemoteSpoofResult = nil
        latestRawLocalSpoofResult = nil
        lastStableRemoteSpoofResult = nil
        remoteFakeCandidateCount = 0
        resetSuspiciousSpeech()
        hasSentLikelySyntheticAlert = false
        hasSentHighSyntheticAlert = false
        callKitTrustDisplayState = .normal
    }

    private func resolveTwilioTargetIdentity(for contact: Contact) -> String? {
        if let phoneIdentity = Constants.twilioIdentity(forPhoneNumber: contact.phoneNumber) {
            return phoneIdentity
        }
        if Constants.isPhoneTwilioIdentity(contact.id) {
            return contact.id
        }
        return nil
    }

    private func spoofSummary(prefix: String, result: SpoofResult) -> String {
        switch result.verdict {
        case .human:
            return "\(prefix) Voice: Human"
        case .likelyFake:
            return "\(prefix) Voice: Highly Likely Synthetic"
        case .uncertain:
            return result.supportingWindows < AudioConfiguration.spoofWarmupWindowsCall
                ? "\(prefix) Voice: Analyzing"
                : "\(prefix) Voice: Likely Synthetic"
        }
    }

    private func markSuspiciousSpeech(at timestamp: Date) {
        suspiciousSpeechWindows += 1
        let fallbackDelta = performanceProfile.analysisInterval
        let elapsed: TimeInterval
        if let lastAt = lastSuspiciousSpeechAt {
            elapsed = timestamp.timeIntervalSince(lastAt)
        } else {
            elapsed = fallbackDelta
        }
        suspiciousSpeechSeconds += min(1.0, max(fallbackDelta, elapsed))
        lastSuspiciousSpeechAt = timestamp
    }

    private func resetSuspiciousSpeech() {
        suspiciousSpeechWindows = 0
        suspiciousSpeechSeconds = 0
        lastSuspiciousSpeechAt = nil
    }

    private func updateCallKitTrustDisplay(_ state: CallKitTrustDisplayState, result: SpoofResult?) {
        guard callKitTrustDisplayState != state,
              let call = currentCall else { return }

        let callerName: String
        switch state {
        case .normal:
            callerName = normalCallKitDisplayName(for: call)
        case .likelySynthetic:
            callerName = "\(Constants.callKitDisplayName): \(LiveSpoofAlertSeverity.suspectedSynthetic.callKitTitle)"
        case .highSynthetic:
            callerName = "\(Constants.callKitDisplayName): \(LiveSpoofAlertSeverity.flaggedSynthetic.callKitTitle)"
        }

        callKitTrustDisplayState = state
        callKit.updateCallDisplay(
            callId: call.id,
            callerName: callerName,
            handleValue: call.remotePhone ?? call.remoteUserId
        )
        CallDebugReporter.post(
            "callkit_trust_display_state",
            details: [
                "state": state.rawValue,
                "verdict": result?.verdict.rawValue ?? "none",
                "score": result.map { String(format: "%.3f", $0.cloneProbability) } ?? "none"
            ]
        )
    }

    private func normalCallKitDisplayName(for call: VoIPCall) -> String {
        switch call.direction {
        case .incoming:
            return "\(Constants.callKitDisplayName) from \(call.remoteName)"
        case .outgoing:
            return call.remoteName
        }
    }

    private func tearDownCall(recordState: CallStateRecord) {
        let callId = currentCall?.id
        aiAnalysis.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        resetSpoofAlertState()
        callTransport.leaveCall()
        stopDurationTimer()
        saveCallRecord(state: recordState)
        callState = .ended
        if let callId {
            Task { await callKit.reportCallEnded(callId: callId) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.resetCall()
        }
    }

    private func resetCall() {
        callState                = .idle
        currentCall              = nil
        spoofResult              = nil
        speakerResult            = nil
        localSpoofResult         = nil
        localSpeakerResult       = nil
        latestRawRemoteSpoofResult = nil
        latestRawLocalSpoofResult = nil
        hasRemoteEnrolledVoiceprint = false
        aiDiagnosticsText        = "idle"
        isDeviceVerified         = false
        isMuted                  = false
        isSpeakerOn              = false
        callDuration             = 0
        resetSpoofAlertState()
        stopDurationTimer()
        stopConnectTimeout()
    }

    private func startDurationTimer() {
        callDuration = 0
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.callDuration += 1 }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private var diagnosticsTimer: Timer?
    private var diagnosticCancellables = Set<AnyCancellable>()

    private func startDiagnosticsTicker() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let audio = self.callTransport.debugAudioSnapshot()
                self.aiDiagnosticsText = "\(self.aiAnalysis.diagnostics) | rf=\(audio.remoteFrames) lf=\(audio.localFrames) rs=\(audio.remoteSamples) ls=\(audio.localSamples)"
            }
        }
    }

    // MARK: - Call History

    private enum CallStateRecord { case ended, declined, missed, failed }

    private func saveCallRecord(state: CallStateRecord) {
        guard let call = currentCall else { return }
        let callState: CallState
        switch state {
        case .ended:    callState = .ended
        case .declined: callState = .declined
        case .missed:   callState = .missed
        case .failed:   callState = .failed
        }
        let record = Call(
            id: call.id,
            callerId:      call.direction == .incoming ? call.remoteUserId : "me",
            callerName:    call.direction == .incoming ? call.remoteName   : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
            recipientId:   call.direction == .outgoing ? call.remoteUserId : "me",
            recipientName: call.direction == .outgoing ? call.remoteName   : (UserDefaults.standard.string(forKey: "userName") ?? "Me"),
            direction:     call.direction,
            state:         callState,
            startedAt:     Date().addingTimeInterval(-callDuration),
            endedAt:       Date(),
            isVerified:    true
        )
        Task { await StorageService.shared.saveCall(record) }
    }
}

private struct IncomingCallerPresentation {
    let displayName: String
    let phoneNumber: String?
    let callKitName: String
}

private enum CallKitTrustDisplayState: String {
    case normal
    case likelySynthetic
    case highSynthetic
}

// MARK: - VoIP Call State

enum VoIPCallState: Equatable {
    case idle
    case calling
    case ringing
    case connecting
    case connected
    case ended
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:              return ""
        case .calling:           return "Calling..."
        case .ringing:           return "Incoming Call"
        case .connecting:        return "Connecting..."
        case .connected:         return "Connected"
        case .ended:             return "Call Ended"
        case .failed(let msg):   return "Failed: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .calling, .ringing, .connecting, .connected: return true
        default: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - VoIP Call Model

struct VoIPCall: Identifiable, Equatable {
    let id: String
    var remoteUserId: String
    let remoteName: String
    let remotePhone: String?
    let direction: CallDirection

    static func == (lhs: VoIPCall, rhs: VoIPCall) -> Bool { lhs.id == rhs.id }
}
