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
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            // When user logs out, check if voice signature still exists
            if !isAuthenticated {
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

    var body: some View {
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
}
