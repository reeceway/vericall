#!/usr/bin/env python3
filepath = "/Users/reeceway/vericall/ios/VeriCall/App/VeriCallApp.swift"

content = '''import SwiftUI

@main
struct VeriCallApp: App {
    @StateObject private var authService = AuthService()
    
    // Initialize NativeCallObserver to monitor regular phone calls
    private let nativeCallObserver = NativeCallObserver.shared
    
    init() {
        // Request notification permissions for call verification alerts
        Task {
            await NotificationService.shared.requestAuthorization()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
        }
    }
}
'''

with open(filepath, 'w') as f:
    f.write(content)

print("VeriCallApp.swift updated")
