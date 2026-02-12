import SwiftUI

/// Full-screen VoIP call view — handles both outgoing (calling...) and
/// connected states with real-time voice match percentage.
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
                
                Spacer().frame(height: 16)
                
                // Device verified badge
                if callService.isDeviceVerified {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3)
                        Text("✓ Device Verified")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.2))
                            .overlay(Capsule().stroke(Color.green.opacity(0.5), lineWidth: 1))
                    )
                }
                
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
                    
                    Circle()
                        .fill(callService.isDeviceVerified ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
                        .frame(width: 140, height: 140)
                    
                    Text(initials)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundColor(callService.isDeviceVerified ? .green : .white)
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
                
                // Voice match
                if callService.callState == .connected {
                    voiceMatchSection
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
    
    // MARK: - Voice Match Section
    
    @ViewBuilder
    private var voiceMatchSection: some View {
        if let match = callService.voiceMatchPercentage {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.title3)
                    Text("Voice Match: \(Int(match))%")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .foregroundColor(voiceMatchColor(match))
                
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 6)
                            .cornerRadius(3)
                        Rectangle()
                            .fill(voiceMatchColor(match))
                            .frame(width: geo.size.width * CGFloat(match / 100), height: 6)
                            .cornerRadius(3)
                            .animation(.easeInOut(duration: 0.3), value: match)
                    }
                }
                .frame(height: 6)
                .frame(maxWidth: 220)
                
                if match >= 85 {
                    Text("✅ Voice Verified")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if match >= 72 {
                    Text("⚠️ Partial Match")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if match > 0 {
                    Text("❌ Voice Mismatch")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } else if callService.isDeviceVerified {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Analyzing voice...")
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
    
    private func voiceMatchColor(_ pct: Double) -> Color {
        if pct >= 85 { return .green }
        if pct >= 72 { return .orange }
        return .red
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
