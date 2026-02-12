#!/usr/bin/env python3
"""Add triggerOutgoingHandshake method to NativeCallObserver"""

FILE = '/Users/reeceway/vericall/ios/VeriCall/Services/NativeCallObserver.swift'

OLD_TEXT = '''    // MARK: - Public Methods
    
    /// Call this when user initiates an outgoing call through your app
    /// Sets the phone number so handshakes can be sent
    func userInitiatedCall(to phoneNumber: String) {
        print("[NativeCallObserver] 📱 User initiating call to \\(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
    }
}'''

NEW_TEXT = '''    // MARK: - Public Methods
    
    /// Call this when user initiates an outgoing call through your app
    /// Sets the phone number so handshakes can be sent
    func userInitiatedCall(to phoneNumber: String) {
        print("[NativeCallObserver] 📱 User initiating call to \\(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
    }
    
    /// Called by AppDelegate when a VoIP push requests we send our handshake
    /// (Used when someone is calling us and we need to identify ourselves)
    func triggerOutgoingHandshake(to phoneNumber: String) async {
        print("[NativeCallObserver] 🤝 VoIP push - sending handshake to \\(phoneNumber)")
        currentCallPhoneNumber = phoneNumber
        await sendHandshakesToRecipient(phoneNumber: phoneNumber)
    }
}'''

with open(FILE, 'r') as f:
    content = f.read()

content = content.replace(OLD_TEXT, NEW_TEXT)

with open(FILE, 'w') as f:
    f.write(content)

print("Added triggerOutgoingHandshake method")
