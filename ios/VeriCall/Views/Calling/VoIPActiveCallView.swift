import SwiftUI

/// Full-screen Twilio call view with live spoof detection status.
struct VoIPActiveCallView: View {
    @ObservedObject var callService = VoIPCallService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var demoBanner: VideoDemoBannerData?
    private let isVideoDemoMode = VideoDemoKind.current() != nil

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                gradient: Gradient(colors: [
                    isVideoDemoMode ? Color.black : Color.black.opacity(0.95),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                Text(callService.callState.displayText)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.8))
                    .animation(.easeInOut, value: callService.callState)

                Spacer().frame(height: 24)

                ZStack {
                    if callService.callState == .calling || callService.callState == .connecting {
                        Circle()
                            .stroke(Color.green.opacity(0.3), lineWidth: 3)
                            .frame(width: 160, height: 160)
                            .scaleEffect(1.2)
                            .opacity(0.5)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: callService.callState)
                    }

                    Circle()
                        .fill(avatarColor.opacity(0.25))
                        .frame(width: 140, height: 140)

                    Text(initials)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundColor(avatarColor)
                }

                Spacer().frame(height: 16)

                Text(callService.currentCall?.remoteName ?? "Unknown")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)

                Spacer().frame(height: 8)

                if callService.callState == .connected {
                    Text(callService.formattedDuration)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .monospacedDigit()
                }

                Spacer().frame(height: 24)

                if callService.callState == .connected {
                    aiVerificationSection
                }

                Spacer()

                if callService.callState == .connected ||
                   callService.callState == .calling ||
                   callService.callState == .connecting {
                    callControls
                }

                if callService.callState == .ended || callService.callState.isFailure {
                    VStack(spacing: 16) {
                        Image(systemName: "phone.down.fill")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(callService.callState.displayText)
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .padding(.bottom, 60)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            dismiss()
                        }
                    }
                }

                Spacer().frame(height: 40)
            }
            .padding()

            if let demoBanner {
                VideoDemoNotificationBanner(banner: demoBanner)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .interactiveDismissDisabled(callService.callState.isActive)
        .onChange(of: callService.callState) { newState in
            if newState == .idle { dismiss() }
        }
        .task {
            await configureVideoDemoBanner()
        }
    }

    // MARK: - AI Verification Section

    @ViewBuilder
    private var aiVerificationSection: some View {
        VStack(spacing: 10) {
            aiVoiceChip
            if showsAIDiagnostics {
                Text(callService.aiDiagnosticsText)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var aiVoiceChip: some View {
        if let spoof = callService.spoofResult {
            spoofChip(for: spoof)
        } else {
            LoadingChip()
        }
    }

    @ViewBuilder
    private func spoofChip(for spoof: SpoofResult) -> some View {
        let chipColor = chipColor(for: spoof)
        VerificationChip(
            icon: chipIcon(for: spoof),
            label: chipLabel(for: spoof),
            sublabel: chipSublabel(for: spoof),
            color: chipColor
        )
    }

    // MARK: - Call Controls

    @ViewBuilder
    private var callControls: some View {
        VStack(spacing: 40) {
            if callService.callState == .connected {
                HStack(spacing: 60) {
                    CallControlButton(
                        icon: callService.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: callService.isMuted ? "Unmute" : "Mute",
                        color: callService.isMuted ? .red : .white,
                        backgroundColor: callService.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.2),
                        action: { callService.toggleMute() }
                    )
                    CallControlButton(
                        icon: callService.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                        label: "Speaker",
                        color: callService.isSpeakerOn ? .green : .white,
                        backgroundColor: callService.isSpeakerOn ? Color.green.opacity(0.3) : Color.white.opacity(0.2),
                        action: { callService.toggleSpeaker() }
                    )
                }
            }

            Button(action: { callService.endCall() }) {
                HStack(spacing: 12) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                    Text("End Call")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(Capsule().fill(Color.red))
            }
            .padding(.horizontal, 40)
        }
        .padding(.bottom, 40)
    }

    // MARK: - Helpers

    private var initials: String {
        let name = callService.currentCall?.remoteName ?? ""
        let parts = name.split(separator: " ")
        if parts.count > 1 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        if let spoof = callService.spoofResult {
            return chipColor(for: spoof)
        }
        return .white
    }

    private var showsAIDiagnostics: Bool {
        UserDefaults.standard.bool(forKey: AIAnalysisService.debugCaptureEnabledKey)
    }

    private func chipLabel(for spoof: SpoofResult) -> String {
        switch spoof.verdict {
        case .human:
            return "Human Voice"
        case .likelyFake:
            return "Highly Likely Synthetic"
        case .uncertain:
            return spoof.supportingWindows < AudioConfiguration.spoofWarmupWindowsCall
                ? "Checking Voice"
                : "Likely Synthetic Voice"
        }
    }

    private func chipSublabel(for spoof: SpoofResult) -> String {
        switch spoof.verdict {
        case .human:
            return "Live speech verified"
        case .likelyFake:
            return "Do not trust this voice"
        case .uncertain:
            if spoof.supportingWindows < AudioConfiguration.spoofWarmupWindowsCall {
                return "Collecting live speech"
            }
            return "Do not trust this voice yet"
        }
    }

    private func chipIcon(for spoof: SpoofResult) -> String {
        switch spoof.verdict {
        case .human:
            return "checkmark.shield.fill"
        case .likelyFake:
            return "exclamationmark.triangle.fill"
        case .uncertain:
            return "waveform.badge.magnifyingglass"
        }
    }

    private func chipColor(for spoof: SpoofResult) -> Color {
        switch spoof.verdict {
        case .human:
            return .green
        case .likelyFake:
            return .red
        case .uncertain:
            return .orange
        }
    }

    private func configureVideoDemoBanner() async {
        await MainActor.run {
            demoBanner = nil
        }

        guard let banner = VideoDemoKind.current()?.activeCallBanner else { return }

        try? await Task.sleep(for: .seconds(0.9))
        guard !Task.isCancelled else { return }

        await MainActor.run {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                demoBanner = banner
            }
        }
    }
}

// MARK: - Chip Components

private struct VerificationChip: View {
    let icon: String
    let label: String
    let sublabel: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline)
                Text(label).font(.subheadline).fontWeight(.semibold)
            }
            .foregroundColor(color)
            Text(sublabel).font(.caption2).foregroundColor(color.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.4), lineWidth: 1))
        )
    }
}

private struct LoadingChip: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.75)
                Text("Listening for Caller").font(.subheadline).fontWeight(.semibold).foregroundColor(.white.opacity(0.7))
            }
            Text("Waiting for speech").font(.caption2).foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
        )
    }
}

struct VoIPActiveCallView_Previews: PreviewProvider {
    static var previews: some View {
        VoIPActiveCallView()
    }
}
