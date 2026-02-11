#!/usr/bin/env python3
filepath = "/Users/reeceway/vericall/ios/VeriCall/Services/NativeCallObserver.swift"

with open(filepath, 'r') as f:
    content = f.read()

# Add KeychainService to the services
old_services = '''    // MARK: - Services
    private let callObserver = CXCallObserver()
    private let apiService = APIService.shared
    private let webSocketService = WebSocketService.shared'''

new_services = '''    // MARK: - Services
    private let callObserver = CXCallObserver()
    private let apiService = APIService.shared
    private let webSocketService = WebSocketService.shared
    private let authKeychain = KeychainService.shared'''

if old_services in content:
    content = content.replace(old_services, new_services)
    print("Added KeychainService")
else:
    print("Could not find services section")

# Update the lookupVeriCallUser call to include access token
old_lookup = '''            let recipientInfo = try await apiService.lookupVeriCallUser(phoneNumber: phoneNumber)'''

new_lookup = '''            // Get access token
            guard let accessToken = try? await authKeychain.retrieveString(
                service: "VeriCall",
                account: Constants.KeychainKeys.accessToken
            ) else {
                print("[NativeCallObserver] ❌ No access token - not logged in")
                verificationStatus = .handshakeFailed
                return
            }
            
            guard let recipientInfo = try await apiService.lookupVeriCallUser(phoneNumber: phoneNumber, accessToken: accessToken) else {
                print("[NativeCallObserver] ❌ Recipient doesn't have VeriCall")
                verificationStatus = .recipientNotOnVeriCall
                await notificationService.showCallVerificationNotification(
                    callerName: phoneNumber,
                    callerId: phoneNumber,
                    isDeviceVerified: false,
                    hasVoiceThumbprint: false
                )
                return
            }'''

if old_lookup in content:
    content = content.replace(old_lookup, new_lookup)
    print("Updated lookupVeriCallUser call")
else:
    print("Could not find lookupVeriCallUser call")

# Fix the recipientUserId check since we now have optional already handled
old_check = '''            guard let recipientUserId = recipientInfo.userId else {
                print("[NativeCallObserver] ❌ Recipient doesn't have VeriCall")
                verificationStatus = .recipientNotOnVeriCall
                
                // Show notification that they're not on VeriCall
                await notificationService.showCallVerificationNotification(
                    callerName: phoneNumber,
                    callerId: phoneNumber,
                    isDeviceVerified: false,
                    hasVoiceThumbprint: false
                )
                return
            }
            
            remoteUserName = recipientInfo.displayName ?? phoneNumber'''

new_check = '''            let recipientUserId = recipientInfo.id
            remoteUserName = recipientInfo.displayName ?? phoneNumber'''

if old_check in content:
    content = content.replace(old_check, new_check)
    print("Fixed recipientUserId check")
else:
    print("Could not find recipientUserId check")

with open(filepath, 'w') as f:
    f.write(content)

print("Done!")
