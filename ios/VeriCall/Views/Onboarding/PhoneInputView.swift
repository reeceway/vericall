import SwiftUI

struct PhoneInputView: View {
    @Binding var phoneNumber: String
    let companyAccessCode: String?
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
                let accessCode = Constants.sendCompanyAccessCodeToBackend ? companyAccessCode : nil
                _ = try await authService.requestOTP(phoneNumber: fullNumber, companyAccessCode: accessCode)
                isLoading = false
                onContinue()
            } catch {
                isLoading = false
                errorMessage = friendlyPhoneInputErrorMessage(error)
            }
        }
    }

    private func friendlyPhoneInputErrorMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError else {
            return error.localizedDescription
        }

        switch apiError {
        case .httpError(402, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Your company's MSP needs to finish billing setup before this access code can activate seats."
                : trimmed
        case .httpError(409, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "This company access code cannot activate another seat right now. Ask your MSP for a new code."
                : trimmed
        case .httpError(403, let message):
            let lowered = message.lowercased()
            if lowered.contains("access code") {
                return "That company access code wasn't accepted. Go back and check it, then try again."
            }
            return message.isEmpty ? "You don't have access to continue with this login." : message
        case .httpError(_, let message):
            return message.isEmpty ? error.localizedDescription : message
        default:
            return error.localizedDescription
        }
    }
}

#Preview {
    PhoneInputView(
        phoneNumber: .constant(""),
        companyAccessCode: nil,
        onContinue: {},
        onBack: {}
    )
    .environmentObject(AuthService())
}
