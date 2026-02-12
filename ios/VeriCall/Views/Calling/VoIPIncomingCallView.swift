import SwiftUI

/// Shown when a VoIP call is ringing — Accept or Decline.
struct VoIPIncomingCallView: View {
    @ObservedObject var callService = VoIPCallService.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.95),
                    Color(red: 0.02, green: 0.1, blue: 0.02)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                
                // Incoming call label
                Text("VeriCall Incoming")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.8))
                
                Spacer().frame(height: 16)
                
                // Verification badge
                if callService.isDeviceVerified {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2)
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
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Unverified Caller")
                            .font(.subheadline)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.2))
                    )
                }
                
                Spacer().frame(height: 32)
                
                // Avatar with pulse animation
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.2), lineWidth: 2)
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseScale)
                    
                    Circle()
                        .fill(callService.isDeviceVerified ? Color.green.opacity(0.3) : Color.gray.opacity(0.3))
                        .frame(width: 120, height: 120)
                    
                    Text(initials)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(callService.isDeviceVerified ? .green : .white)
                }
                .overlay(alignment: .bottomTrailing) {
                    if callService.isDeviceVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.title)
                            .background(Circle().fill(Color.black))
                    }
                }
                
                Spacer().frame(height: 24)
                
                // Caller name
                Text(callService.currentCall?.remoteName ?? "Unknown")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer().frame(height: 8)
                
                Text("VoIP Call")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
                
                if callService.isDeviceVerified {
                    Text("AI deepfake detection will begin when answered")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 8)
                }
                
                Spacer()
                
                // Accept / Decline buttons
                HStack(spacing: 60) {
                    // Decline
                    Button(action: {
                        callService.declineCall()
                        dismiss()
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 80, height: 80)
                                Image(systemName: "phone.down.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Decline")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Accept
                    Button(action: {
                        Task {
                            await callService.answerCall()
                        }
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 80, height: 80)
                                Image(systemName: "phone.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Accept")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .padding()
        }
        .interactiveDismissDisabled()
        .onChange(of: callService.callState) { newState in
            // Transition to active call view when answered
            if newState == .connecting || newState == .connected {
                dismiss()
            }
            if newState == .idle {
                dismiss()
            }
        }
    }
    
    // MARK: - Pulse animation state
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6
    
    private var initials: String {
        let name = callService.currentCall?.remoteName ?? ""
        let parts = name.split(separator: " ")
        if parts.count > 1 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

struct VoIPIncomingCallView_Previews: PreviewProvider {
    static var previews: some View {
        VoIPIncomingCallView()
    }
}
