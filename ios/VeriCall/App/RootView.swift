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

// Placeholder for main app content
struct MainTabView: View {
    var body: some View {
        TabView {
            Text("Calls")
                .tabItem {
                    Image(systemName: "phone.fill")
                    Text("Calls")
                }
            
            Text("Contacts")
                .tabItem {
                    Image(systemName: "person.2.fill")
                    Text("Contacts")
                }
            
            Text("Settings")
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
        .accentColor(.veriBlue)
    }
}
