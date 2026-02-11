#!/usr/bin/env python3
import os

filepath = "VeriCall/Services/APIService.swift"

with open(filepath, 'r') as f:
    content = f.read()

# The method to insert
lookup_method = '''
    // MARK: - Lookup VeriCall User by Phone Number
    func lookupVeriCallUser(phoneNumber: String, accessToken: String) async throws -> User? {
        let body = try JSONEncoder().encode(["phone_number": phoneNumber])
        
        do {
            let response: UserLookupResponse = try await makeRequest(
                endpoint: baseURL + "/users/lookup",
                method: "POST",
                body: body,
                accessToken: accessToken
            )
            return response.user
        } catch APIError.serverError(404, _) {
            // User not found - not a VeriCall user
            return nil
        }
    }
    
'''

# Find the Generic Request marker and insert before it
if 'func lookupVeriCallUser' in content:
    print("lookupVeriCallUser already exists")
elif '// MARK: - Generic Request' in content:
    content = content.replace(
        '// MARK: - Generic Request',
        lookup_method + '// MARK: - Generic Request'
    )
    with open(filepath, 'w') as f:
        f.write(content)
    print("SUCCESS: Added lookupVeriCallUser method")
else:
    print("ERROR: Could not find Generic Request marker")
