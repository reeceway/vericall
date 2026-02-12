#!/usr/bin/env python3
filepath = "/Users/reeceway/vericall/ios/VeriCall/Services/WebSocketService.swift"

with open(filepath, 'r') as f:
    content = f.read()

old_code = '''    private func handleBinaryMessage(_ data: Data) {
        do {
            let signal = try JSONDecoder().decode(CallSignal.self, from: data)
            signalContinuation?.yield(signal)
        } catch {
            print("Failed to decode signal: \\(error)")
        }
    }'''

new_code = '''    private func handleBinaryMessage(_ data: Data) {
        // First try to parse as generic JSON to check message type
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageType = json["type"] as? String {
            
            // Handle native call handshake messages
            if messageType.hasPrefix("native_call:") {
                Task { @MainActor in
                    await handleNativeCallMessage(json: json, type: messageType)
                }
                return
            }
        }
        
        // Otherwise decode as CallSignal
        do {
            let signal = try JSONDecoder().decode(CallSignal.self, from: data)
            signalContinuation?.yield(signal)
        } catch {
            print("Failed to decode signal: \\(error)")
        }
    }
    
    @MainActor
    private func handleNativeCallMessage(json: [String: Any], type: String) async {
        let observer = NativeCallObserver.shared
        
        switch type {
        case "native_call:handshake":
            // Someone is calling us and sent their thumbprint
            if let fromUserId = json["fromUserId"] as? String,
               let thumbprint = json["voiceThumbprint"] as? [Double],
               let phoneNumber = json["phoneNumber"] as? String {
                let floatThumbprint = thumbprint.map { Float($0) }
                let displayName = json["displayName"] as? String
                await observer.handleReceivedHandshake(
                    fromUserId: fromUserId,
                    displayName: displayName,
                    voiceThumbprint: floatThumbprint,
                    phoneNumber: phoneNumber
                )
            }
            
        case "native_call:request_thumbprint":
            // They're requesting our thumbprint
            if let fromUserId = json["fromUserId"] as? String,
               let phoneNumber = json["phoneNumber"] as? String {
                await observer.handleThumbprintRequest(fromUserId: fromUserId, phoneNumber: phoneNumber)
            }
            
        case "native_call:handshake_response":
            // Response to our outgoing call handshake
            if let fromUserId = json["fromUserId"] as? String,
               let thumbprint = json["voiceThumbprint"] as? [Double],
               let phoneNumber = json["phoneNumber"] as? String {
                let floatThumbprint = thumbprint.map { Float($0) }
                let displayName = json["displayName"] as? String
                await observer.handleReceivedHandshake(
                    fromUserId: fromUserId,
                    displayName: displayName,
                    voiceThumbprint: floatThumbprint,
                    phoneNumber: phoneNumber
                )
            }
            
        default:
            print("[WebSocketService] Unknown native call message type: \\(type)")
        }
    }'''

if old_code in content:
    content = content.replace(old_code, new_code)
    with open(filepath, 'w') as f:
        f.write(content)
    print("SUCCESS: Updated handleBinaryMessage")
else:
    print("ERROR: Could not find code to replace")
