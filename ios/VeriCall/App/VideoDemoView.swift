import SwiftUI
import UserNotifications

enum VideoDemoKind: String, CaseIterable {
    case install
    case makeCall = "make-call"
    case callkitIncoming = "callkit-incoming"
    case answerGreenNotification = "answer-green-notification"
    case callUiGreenChip = "call-ui-green-chip"
    case callUiRedChip = "call-ui-red-chip"
    case cloneNotificationRed = "clone-notification-red"

    static func current() -> VideoDemoKind? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["VICALL_VIDEO_DEMO_KIND"], let kind = VideoDemoKind(rawValue: value) {
            return kind
        }

        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-vicall-video-demo") else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return .install }
        return VideoDemoKind(rawValue: args[valueIndex]) ?? .install
    }
}

struct VideoDemoBannerData {
    let tint: Color
    let icon: String
    let title: String
    let body: String
}

extension VideoDemoKind {
    var activeCallBanner: VideoDemoBannerData? {
        switch self {
        case .answerGreenNotification:
            return VideoDemoBannerData(
                tint: Color(red: 0.10, green: 0.75, blue: 0.38),
                icon: "checkmark.shield.fill",
                title: "Device Verified",
                body: "Reece Way is calling. Vicall verified the live caller."
            )
	        case .cloneNotificationRed:
	            return VideoDemoBannerData(
	                tint: Color(red: 0.86, green: 0.22, blue: 0.22),
	                icon: "exclamationmark.triangle.fill",
	                title: "Highly likely synthetic voice",
	                body: "Do not trust this voice. Vicall flagged it as highly likely synthetic."
	            )
        default:
            return nil
        }
    }
}

struct VideoDemoNotificationBanner: View {
    let banner: VideoDemoBannerData

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(banner.tint.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: banner.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(banner.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(banner.body)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

struct VideoDemoView: View {
    let kind: VideoDemoKind
    @EnvironmentObject var authService: AuthService
    @State private var seeded = false

    var body: some View {
        demoBody
            .task {
                guard !seeded else { return }
                seeded = true
                await prepareDemo()
            }
    }

    @ViewBuilder
    private var demoBody: some View {
        switch kind {
        case .install, .makeCall:
            MainTabView()
        case .callkitIncoming, .answerGreenNotification, .callUiGreenChip, .callUiRedChip, .cloneNotificationRed:
            MainTabView()
        }
    }

    private func prepareDemo() async {
        UserDefaults.standard.set("demo-token", forKey: "authToken")
        UserDefaults.standard.set("+14128628887", forKey: "userPhoneNumber")
        authService.isAuthenticated = true

        await seedCallHistoryIfNeeded()
        await MainActor.run {
            NotificationService.shared.setupNotificationCategories()
            resetCallService()
        }

        switch kind {
        case .install:
            return

        case .makeCall:
            await runMakeCallDemo()

        case .callkitIncoming:
            await runIncomingDemo(reportToCallKit: true)

        case .answerGreenNotification:
            await runAnswerGreenDemo()

        case .callUiGreenChip:
            await runConnectedDemo(kind: .human)

        case .callUiRedChip:
            await runConnectedDemo(kind: .synthetic)

        case .cloneNotificationRed:
            await runCloneNotificationDemo()
        }
    }

    private func seedCallHistoryIfNeeded() async {
        await StorageService.shared.clearCallHistory()

        let now = Date()
        let calls: [Call] = [
            Call(
                id: UUID().uuidString,
                callerId: "user_14128628887_prod1",
                callerName: "Reece Way",
                recipientId: "user_14125550112_prod1",
                recipientName: "Jordan Mills",
                direction: .incoming,
                state: .ended,
                startedAt: now.addingTimeInterval(-3900),
                endedAt: now.addingTimeInterval(-3840),
                isVerified: true
            ),
            Call(
                id: UUID().uuidString,
                callerId: "user_14125550146_prod1",
                callerName: "Avery Chen",
                recipientId: "user_14128628887_prod1",
                recipientName: "You",
                direction: .outgoing,
                state: .ended,
                startedAt: now.addingTimeInterval(-7600),
                endedAt: now.addingTimeInterval(-7510),
                isVerified: true
            ),
            Call(
                id: UUID().uuidString,
                callerId: "user_17245550139_prod1",
                callerName: "Billing Office",
                recipientId: "user_14128628887_prod1",
                recipientName: "You",
                direction: .incoming,
                state: .missed,
                startedAt: now.addingTimeInterval(-14800),
                endedAt: now.addingTimeInterval(-14775),
                isVerified: false
            ),
        ]

        for call in calls {
            await StorageService.shared.saveCall(call)
        }
    }

    @MainActor
    private func resetCallService() {
        let service = VoIPCallService.shared
        service.callState = .idle
        service.currentCall = nil
        service.isMuted = false
        service.isSpeakerOn = true
        service.callDuration = 0
        service.spoofResult = nil
        service.speakerResult = nil
        service.localSpoofResult = nil
        service.localSpeakerResult = nil
        service.isDeviceVerified = false
        service.hasRemoteEnrolledVoiceprint = false
        service.aiDiagnosticsText = "demo"
    }

    private func runMakeCallDemo() async {
        try? await Task.sleep(for: .seconds(1.0))
        await MainActor.run {
            setConnectedHumanCall(duration: 18)
        }
    }

    private func runIncomingDemo(reportToCallKit: Bool) async {
        let call = makeDemoVoIPCall()

        await MainActor.run {
            let service = VoIPCallService.shared
            service.currentCall = call
            service.callState = .ringing
            service.isDeviceVerified = true
        }

        guard reportToCallKit else { return }

        let delaySeconds = VideoDemoKind.current() == .callkitIncoming ? 0.08 : 0.8
        try? await Task.sleep(for: .seconds(delaySeconds))

        let systemCall = Call(
            id: call.id,
            callerId: call.remotePhone ?? call.remoteUserId,
            callerName: call.remoteName,
            recipientId: "user_14128628887_prod1",
            recipientName: "You",
            direction: .incoming,
            state: .ringing,
            startedAt: Date(),
            endedAt: nil,
            isVerified: true
        )

        await MainActor.run {
            CallKitManager.shared.reportIncomingCall(call: systemCall) { _ in } completion: { _ in }
        }
    }

    private func runAnswerGreenDemo() async {
        await runIncomingDemo(reportToCallKit: false)
        try? await Task.sleep(for: .seconds(2.0))

        await MainActor.run {
            setConnectedHumanCall(duration: 4)
        }
    }

    private enum ConnectedDemoState {
        case human
        case synthetic
    }

    private func runConnectedDemo(kind: ConnectedDemoState) async {
        await MainActor.run {
            switch kind {
            case .human:
                setConnectedHumanCall(duration: 258)
            case .synthetic:
                setConnectedSyntheticCall(duration: 258)
            }
        }
    }

    private func runCloneNotificationDemo() async {
        await MainActor.run {
            setConnectedSyntheticCall(duration: 258)
        }
    }

    @MainActor
    private func setConnectedHumanCall(duration: TimeInterval) {
        let service = VoIPCallService.shared
        service.currentCall = makeDemoVoIPCall()
        service.callState = .connected
        service.callDuration = duration
        service.isSpeakerOn = true
        service.isDeviceVerified = true
        service.spoofResult = SpoofResult(
            cloneProbability: 0.06,
            confidence: .high,
            threshold: AudioConfiguration.spoofHumanThresholdCall,
            supportingWindows: AudioConfiguration.spoofWarmupWindowsCall + 1,
            processingTimeMs: 18.0,
            rms: 0.014
        )
        service.aiDiagnosticsText = "Remote • Human Voice • 0.06"
    }

    @MainActor
    private func setConnectedSyntheticCall(duration: TimeInterval) {
        let service = VoIPCallService.shared
        service.currentCall = makeDemoVoIPCall()
        service.callState = .connected
        service.callDuration = duration
        service.isSpeakerOn = true
        service.isDeviceVerified = true
        service.spoofResult = SpoofResult(
            cloneProbability: 0.995,
            confidence: .high,
            threshold: AudioConfiguration.spoofHumanThresholdCall,
            supportingWindows: AudioConfiguration.spoofWarmupWindowsCall + 2,
            processingTimeMs: 19.0,
            rms: 0.016
        )
	        service.aiDiagnosticsText = "Remote • Highly Likely Synthetic • 0.995"
    }

    private func makeDemoVoIPCall() -> VoIPCall {
        VoIPCall(
            id: UUID().uuidString,
            remoteUserId: "user_14128628887_prod1",
            remoteName: "Reece Way",
            remotePhone: "+1 (412) 862-8887",
            direction: .incoming
        )
    }
}
