import SwiftUI

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @State private var didStartAuthCheck = false

    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainTabView()
            } else {
                OnboardingContainerView()
            }
        }
        .task {
            guard !didStartAuthCheck else { return }
            didStartAuthCheck = true
            await authService.checkExistingAuth()
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @ObservedObject private var voipCallService = VoIPCallService.shared
    @State private var showVoIPIncoming = false
    @State private var showVoIPActive = false
    private let isVideoDemoMode = VideoDemoKind.current() != nil

    var body: some View {
        Group {
            if isVideoDemoMode {
                tabContent
                    .overlay {
                        demoCallOverlay
                    }
            } else {
                tabContent
                    .fullScreenCover(isPresented: $showVoIPIncoming) {
                        VoIPIncomingCallView()
                    }
                    .fullScreenCover(isPresented: $showVoIPActive) {
                        VoIPActiveCallView()
                    }
            }
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

    private var tabContent: some View {
        TabView {
            HomeView()
                .tabItem {
                    Image(systemName: "phone.fill")
                    Text("Home")
                }

            NavigationStack {
                ContactListView()
            }
                .tabItem {
                    Image(systemName: "person.2.fill")
                    Text("Contacts")
                }

            NavigationStack {
                SettingsView()
                    .environmentObject(authService)
            }
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
        .accentColor(.veriBlue)
    }

    @ViewBuilder
    private var demoCallOverlay: some View {
        ZStack {
            if showVoIPIncoming {
                VoIPIncomingCallView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showVoIPActive {
                VoIPActiveCallView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showVoIPIncoming)
        .animation(.easeInOut(duration: 0.22), value: showVoIPActive)
    }
}
