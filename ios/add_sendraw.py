#!/usr/bin/env python3
import os

filepath = "VeriCall/Services/WebSocketService.swift"

with open(filepath, 'r') as f:
    content = f.read()

# The method to insert
sendraw_method = '''
    // MARK: - Send Raw Message (for native call handshakes)
    func sendRaw(message: [String: Any]) async throws {
        guard connectionStatus.isConnected else {
            throw CallError.webSocketDisconnected
        }
        
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CallError.signalingError("Failed to encode raw message")
        }
        
        try await webSocketTask?.send(.string(jsonString))
    }
'''

# Find sendHeartbeat and insert before it
if 'func sendRaw' in content:
    print("sendRaw already exists")
elif 'func sendHeartbeat()' in content:
    content = content.replace(
        'func sendHeartbeat()',
        sendraw_method + '\n    func sendHeartbeat()'
    )
    with open(filepath, 'w') as f:
        f.write(content)
    print("SUCCESS: Added sendRaw method")
else:
    print("ERROR: Could not find sendHeartbeat")
