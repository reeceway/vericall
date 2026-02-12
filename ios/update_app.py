#!/usr/bin/env python3

filepath = "VeriCall/App/VeriCallApp.swift"

with open(filepath, 'r') as f:
    content = f.read()

# Check if already has NativeCallObserver
if 'NativeCallObserver' in content:
    print("NativeCallObserver already initialized")
    exit(0)

new_content = '''import SwiftUI

@main
struct VeriCallApp: App {
    @StateObject private var authService = AuthService()
    
    // Initialize native call observer to monitor regular phone calls
    private let nativeCallObserver = NativeCallObserver.shared
    
    init() {
        // Request notification permissions for call verification alerts
        NotificationService.shared.requestPermission()
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .onAppear {
                    // Start monitoring native calls when app appears
                    nativeCallObserver.startMonitoring()
                }
        }
    }
}
'''

with open(filepath, 'w') as f:
    f.write(new_content)

print("SUCCESS: Updated VeriCallApp.swift with NativeCallObserver initialization")
