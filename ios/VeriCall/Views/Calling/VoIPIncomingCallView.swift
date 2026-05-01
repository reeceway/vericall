import SwiftUI

/// Shown when a VoIP call is ringing — Accept or Decline.
struct VoIPIncomingCallView: View {
    @ObservedObject var callService = VoIPCallService.shared
    @Environment(\.dismiss) private var dismiss
    private let isVideoDemoMode = VideoDemoKind.current() != nil
    private let isCallKitDemoMode = VideoDemoKind.current() == .callkitIncoming
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black,
                    isCallKitDemoMode ? Color.black : Color(red: 0.02, green: 0.1, blue: 0.02)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer().frame(height: isCallKitDemoMode ? 96 : 80)
                
                // Incoming call label
                Text(isCallKitDemoMode ? "Incoming Call" : "\(Constants.appName) Incoming")
                    .font(.system(size: isCallKitDemoMode ? 20 : 21, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                
                Spacer().frame(height: 16)
                
                // Verification badge
                if isCallKitDemoMode {
                    EmptyView()
                } else if callService.isDeviceVerified {
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
                        .stroke((isCallKitDemoMode ? Color.white : Color.green).opacity(0.18), lineWidth: 2)
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseScale)
                    
                    Circle()
                        .fill((isCallKitDemoMode ? Color.white : (callService.isDeviceVerified ? Color.green : Color.gray)).opacity(0.18))
                        .frame(width: 120, height: 120)
                    
                    Text(initials)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(isCallKitDemoMode ? .white : (callService.isDeviceVerified ? .green : .white))
                }
                .overlay(alignment: .bottomTrailing) {
                    if callService.isDeviceVerified && !isCallKitDemoMode {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.title)
                            .background(Circle().fill(Color.black))
                    }
                }
                
                Spacer().frame(height: 24)
                
                // Caller name
                Text(callService.currentCall?.remoteName ?? "Unknown")
                    .font(.system(size: isCallKitDemoMode ? 38 : 36, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer().frame(height: 8)
                
                Text(isCallKitDemoMode ? "Vicall Audio" : "\(Constants.appName) Voice")
                    .font(.system(size: isCallKitDemoMode ? 22 : 20, weight: .regular))
                    .foregroundColor(.white.opacity(isCallKitDemoMode ? 0.72 : 0.6))
                
                if callService.isDeviceVerified && !isCallKitDemoMode {
                    Text("Voice check starts when you answer")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 8)
                }
                
                Spacer()
                
                // Accept / Decline buttons
                HStack(spacing: 60) {
                    // Decline
                    Button(action: {
                        if let callId = callService.currentCall?.id {
                            CallKitManager.shared.performEndCall(callId: callId)
                        } else {
                            callService.declineCall()
                        }
                        dismiss()
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: isCallKitDemoMode ? 84 : 80, height: isCallKitDemoMode ? 84 : 80)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 28, weight: .semibold))
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
                        if let callId = callService.currentCall?.id {
                            CallKitManager.shared.performAnswerCall(callId: callId)
                        } else {
                            Task {
                                await callService.answerCall()
                            }
                        }
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: isCallKitDemoMode ? 84 : 80, height: isCallKitDemoMode ? 84 : 80)
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 28, weight: .semibold))
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
