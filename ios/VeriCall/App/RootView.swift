import SwiftUI

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @State private var hasCompletedVoiceEnrollment: Bool = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.hasCompletedVoiceEnrollment)
    
    var body: some View {
        Group {
            if authService.isAuthenticated {
                // Check if user needs to complete voice enrollment
                if hasCompletedVoiceEnrollment {
                    MainTabView()
                } else {
                    SelfVoiceEnrollmentView(onComplete: {
                        withAnimation {
                            hasCompletedVoiceEnrollment = true
                        }
                    })
                    .environmentObject(authService)
                }
            } else {
                OnboardingContainerView()
            }
        }
        .task {
            await authService.checkExistingAuth()
            // Refresh the voice enrollment status when view appears
            hasCompletedVoiceEnrollment = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.hasCompletedVoiceEnrollment)
        }
        .onChange(of: authService.isAuthenticated) {
            // When user logs out, check if voice signature still exists
            if !authService.isAuthenticated {
                let keychainService = VoiceKeychainService()
                if !keychainService.signatureExists(for: "self") {
                    UserDefaults.standard.set(false, forKey: Constants.UserDefaultsKeys.hasCompletedVoiceEnrollment)
                    hasCompletedVoiceEnrollment = false
                }
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @ObservedObject private var callObserver = NativeCallObserver.shared
    @ObservedObject private var voipCallService = VoIPCallService.shared
    @State private var showVoIPIncoming = false
    @State private var showVoIPActive = false

    var body: some View {
        VStack(spacing: 0) {
            // Call verification banner - shown during active calls
            if callObserver.verificationStatus.isActive {
                CallVerificationBanner(
                    status: callObserver.verificationStatus,
                    remoteName: callObserver.remoteUserName,
                    voiceMatch: callObserver.voiceMatchPercentage
                )
            }

            TabView {
                CallHistoryView()
                    .tabItem {
                        Image(systemName: "phone.fill")
                        Text("Calls")
                    }

                ContactListView()
                    .tabItem {
                        Image(systemName: "person.2.fill")
                        Text("Contacts")
                    }

                SettingsView()
                    .environmentObject(authService)
                    .tabItem {
                        Image(systemName: "gear")
                        Text("Settings")
                    }
            }
            .accentColor(.veriBlue)
        }
        .onAppear {
            // Ensure WebSocket is connected and NativeCallObserver is initialized
            _ = NativeCallObserver.shared
        }
        .fullScreenCover(isPresented: $showVoIPIncoming) {
            VoIPIncomingCallView()
        }
        .fullScreenCover(isPresented: $showVoIPActive) {
            VoIPActiveCallView()
        }
        .onChange(of: voipCallService.callState) {
            switch voipCallService.callState {
            case .ringing:
                showVoIPIncoming = true
                showVoIPActive = false
            case .connecting, .connected, .calling:
                showVoIPIncoming = false
                showVoIPActive = true
            case .ended, .failed:
                // Keep active view visible briefly for "Call Ended" display
                showVoIPIncoming = false
            case .idle:
                showVoIPIncoming = false
                showVoIPActive = false
            }
        }
    }
}

// MARK: - Call Verification Banner
struct CallVerificationBanner: View {
    let status: NativeCallVerificationStatus
    let remoteName: String?
    let voiceMatch: Double?

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(textColor)

                if let name = remoteName {
                    Text(name)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if let match = voiceMatch {
                    Text("Voice match: \(Int(match))%")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Spacer()

            if status == .verifyingVoice || status == .sendingHandshake || status == .awaitingResponse || status == .monitoring {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(backgroundColor)
        .animation(.easeInOut(duration: 0.3), value: status)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .verified, .verifyingVoice:
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.white)
        case .unverified:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.white)
        case .monitoring, .sendingHandshake, .awaitingResponse:
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(.white)
        case .handshakeTimeout, .handshakeFailed, .recipientNotOnVeriCall, .notEnrolled:
            Image(systemName: "shield.slash")
                .foregroundColor(.white)
        case .idle:
            EmptyView()
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .verified, .verifyingVoice:
            return .green
        case .unverified:
            return .red
        case .monitoring, .sendingHandshake, .awaitingResponse:
            return .orange
        case .handshakeTimeout, .handshakeFailed, .recipientNotOnVeriCall, .notEnrolled:
            return .gray
        case .idle:
            return .clear
        }
    }

    private var textColor: Color {
        .white
    }
}
