import SwiftUI

struct PhoneInputView: View {
    @Binding var phoneNumber: String
    let onContinue: () -> Void
    let onBack: () -> Void
    
    @EnvironmentObject var authService: AuthService
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isValid = false
    @FocusState private var isPhoneFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Navigation Bar
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.veriDark)
                }
                
                Spacer()
                
                Text("Phone Number")
                    .font(.headline)
                    .foregroundColor(.veriDark)
                
                Spacer()
                
                // Spacer for alignment
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .opacity(0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        Text("What's your phone number?")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.veriDark)
                            .multilineTextAlignment(.center)
                        
                        Text("We'll send you a verification code")
                            .font(.body)
                            .foregroundColor(.veriGray)
                    }
                    .padding(.top, 40)
                    
                    // Phone Input
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
                            // Country Code
                            HStack(spacing: 4) {
                                Text("🇺🇸")
                                    .font(.title3)
                                Text("+1")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.veriDark)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            
                            // Phone Number Field
                            TextField("(555) 000-0000", text: $phoneNumber)
                                .font(.body.weight(.medium))
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .focused($isPhoneFieldFocused)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isValid ? Color.veriBlue : Color.gray.opacity(0.2), lineWidth: isValid ? 2 : 1)
                                )
                                .onChange(of: phoneNumber) { _ in
                                    formatPhoneNumber()
                                    validatePhoneNumber()
                                }
                        }
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer()
                }
            }
            
            // Continue Button
            VStack(spacing: 0) {
                Divider()
                
                Button(action: submitPhoneNumber) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Continue")
                            .font(.headline)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(isValid ? Color.veriBlue : Color.gray.opacity(0.4))
                .cornerRadius(16)
                .disabled(!isValid || isLoading)
                .buttonStyle(ScaleButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color.white)
        }
        .background(Color.veriBackground.ignoresSafeArea())
        .onAppear {
            isPhoneFieldFocused = true
        }
    }
    
    private func formatPhoneNumber() {
        // Strip non-numeric characters
        let cleaned = phoneNumber.filter { $0.isNumber }
        
        // Limit to 10 digits
        let limited = String(cleaned.prefix(10))
        
        // Format as (XXX) XXX-XXXX
        var formatted = ""
        for (index, char) in limited.enumerated() {
            if index == 0 {
                formatted += "("
            } else if index == 3 {
                formatted += ") "
            } else if index == 6 {
                formatted += "-"
            }
            formatted.append(char)
        }
        
        phoneNumber = formatted
    }
    
    private func validatePhoneNumber() {
        let cleaned = phoneNumber.filter { $0.isNumber }
        isValid = cleaned.count == 10
        errorMessage = nil
    }
    
    private func submitPhoneNumber() {
        let cleaned = phoneNumber.filter { $0.isNumber }
        let fullNumber = "+1\(cleaned)"

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                _ = try await authService.requestOTP(phoneNumber: fullNumber)
                isLoading = false
                onContinue()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    PhoneInputView(
        phoneNumber: .constant(""),
        onContinue: {},
        onBack: {}
    )
    .environmentObject(AuthService())
}
