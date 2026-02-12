import SwiftUI

/// Full-screen VoIP call view — handles both outgoing (calling...) and
/// connected states with real-time AI deepfake detection.
struct VoIPActiveCallView: View {
    @ObservedObject var callService = VoIPCallService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.95),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                // Call state text
                Text(callService.callState.displayText)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.8))
                    .animation(.easeInOut, value: callService.callState)

                Spacer().frame(height: 24)

                // Avatar
                ZStack {
                    // Pulsing ring when calling
                    if callService.callState == .calling || callService.callState == .connecting {
                        Circle()
                            .stroke(Color.green.opacity(0.3), lineWidth: 3)
                            .frame(width: 160, height: 160)
                            .scaleEffect(1.2)
                            .opacity(0.5)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: callService.callState)
                    }

                    // Avatar ring color based on detection
                    Circle()
                        .fill(avatarColor.opacity(0.25))
                        .frame(width: 140, height: 140)

                    Text(initials)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundColor(avatarColor)
                }

                Spacer().frame(height: 16)

                // Remote name
                Text(callService.currentCall?.remoteName ?? "Unknown")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)

                Spacer().frame(height: 8)

                // Duration
                if callService.callState == .connected {
                    Text(callService.formattedDuration)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .monospacedDigit()
                }

                Spacer().frame(height: 20)

                // AI Detection status
                if callService.callState == .connected {
                    deepfakeDetectionSection
                }

                Spacer()

                // Controls
                if callService.callState == .connected || callService.callState == .calling || callService.callState == .connecting {
                    callControls
                }

                // End state
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
        }
        .interactiveDismissDisabled(callService.callState.isActive)
        .onChange(of: callService.callState) { newState in
            if newState == .idle {
                dismiss()
            }
        }
    }

    // MARK: - AI Detection Section

    @ViewBuilder
    private var deepfakeDetectionSection: some View {
        if let result = callService.deepfakeResult {
            VStack(spacing: 12) {
                // Main status
                HStack(spacing: 8) {
                    Image(systemName: result.isHuman ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                    Text(result.isHuman ? "Human Detected" : "AI Detected")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .foregroundColor(result.isHuman ? .green : .red)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill((result.isHuman ? Color.green : Color.red).opacity(0.2))
                        .overlay(
                            Capsule()
                                .stroke((result.isHuman ? Color.green : Color.red).opacity(0.5), lineWidth: 1)
                        )
                )

                // Confidence
                Text("Confidence: \(Int(result.confidence * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))

                // Processing time
                Text("\(String(format: "%.0f", result.processingTimeMs))ms")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
            }
        } else {
            // Analyzing state
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Analyzing audio with AI...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // MARK: - Call Controls

    @ViewBuilder
    private var callControls: some View {
        VStack(spacing: 40) {
            // Mute / Speaker
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

            // End call
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
        guard let result = callService.deepfakeResult else {
            return .white
        }
        return result.isHuman ? .green : .red
    }
}

// MARK: - State extension
extension VoIPCallState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Preview
struct VoIPActiveCallView_Previews: PreviewProvider {
    static var previews: some View {
        VoIPActiveCallView()
    }
}
