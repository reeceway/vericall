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
