import SwiftUI

struct RootView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainTabView()
            } else {
                OnboardingContainerView()
            }
        }
        .task {
            await authService.checkExistingAuth()
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
            // Call verification banner - shown during active native calls
            if callObserver.verificationStatus.isActive {
                CallVerificationBanner(
                    status: callObserver.verificationStatus,
                    remoteName: callObserver.remoteUserName
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

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                if let name = remoteName {
                    Text(name)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Spacer()

            if status == .sendingHandshake || status == .awaitingResponse || status == .monitoring {
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
        case .verified:
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.white)
        case .unverified:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.white)
        case .monitoring, .sendingHandshake, .awaitingResponse:
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(.white)
        case .handshakeTimeout, .handshakeFailed, .recipientNotOnVeriCall:
            Image(systemName: "shield.slash")
                .foregroundColor(.white)
        case .idle:
            EmptyView()
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .verified:
            return .green
        case .unverified:
            return .red
        case .monitoring, .sendingHandshake, .awaitingResponse:
            return .orange
        case .handshakeTimeout, .handshakeFailed, .recipientNotOnVeriCall:
            return .gray
        case .idle:
            return .clear
        }
    }
}
