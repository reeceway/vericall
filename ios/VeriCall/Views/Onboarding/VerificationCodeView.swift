import SwiftUI

struct VerificationCodeView: View {
    let phoneNumber: String
    let companyAccessCode: String?
    @Binding var code: String
    let onVerified: () -> Void
    let onBack: () -> Void
    
    @EnvironmentObject var authService: AuthService
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var resendTimer = 30
    @State private var canResend = false
    @State private var submittedCode: String?
    @State private var resendCountdownTimer: Timer?
    
    @FocusState private var focusedField: Int?
    
    private let codeLength = 6
    
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
                
                Text("Verification")
                    .font(.headline)
                    .foregroundColor(.veriDark)
                
                Spacer()
                
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
                        Text("Enter verification code")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.veriDark)
                            .multilineTextAlignment(.center)
                        
                        Text("We sent a 6-digit code to\n\(formatPhoneNumber(phoneNumber))")
                            .font(.body)
                            .foregroundColor(.veriGray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)
                    
                    // Code Input Fields
                    HStack(spacing: 12) {
                        ForEach(0..<codeLength, id: \.self) { index in
                            CodeDigitBox(
                                digit: codeDigit(at: index),
                                isFocused: focusedField == index
                            )
                            .onTapGesture {
                                focusedField = min(index, code.count)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Hidden TextField for input handling
                    TextField("", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: code.count)
                        .disabled(isLoading)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .onChange(of: code) { newValue in
                            let sanitized = String(newValue.filter { $0.isNumber }.prefix(codeLength))
                            if sanitized != newValue {
                                code = sanitized
                                return
                            }

                            if sanitized.count < codeLength {
                                submittedCode = nil
                                errorMessage = nil
                            }

                            if sanitized.count == codeLength {
                                verifyCode()
                            }
                        }
                    
                    
                    if isLoading {
                        ProgressView()
                            .padding(.top, 16)
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                    
                    // Resend Code
                    Button(action: resendCode) {
                        if canResend {
                            Text("Resend code")
                                .font(.subheadline)
                                .foregroundColor(.veriBlue)
                        } else {
                            Text("Resend code in \(resendTimer)s")
                                .font(.subheadline)
                                .foregroundColor(.veriGray)
                        }
                    }
                    .disabled(!canResend || isLoading)
                    .padding(.top, 24)
                    
                    Spacer()
                }
            }
        }
        .background(Color.veriBackground.ignoresSafeArea())
        .onAppear {
            focusedField = 0
            startResendTimer()
        }
        .onDisappear {
            stopResendTimer()
        }
    }
    
    private func codeDigit(at index: Int) -> String {
        if index < code.count {
            let charIndex = code.index(code.startIndex, offsetBy: index)
            return String(code[charIndex])
        }
        return ""
    }
    
    private func formatPhoneNumber(_ number: String) -> String {
        let cleaned = number.filter { $0.isNumber }
        if cleaned.count == 11 && cleaned.hasPrefix("1") {
            let area = cleaned.dropFirst(1).prefix(3)
            let prefix = cleaned.dropFirst(4).prefix(3)
            let line = cleaned.dropFirst(7)
            return "+1 (\(area)) \(prefix)-\(line)"
        }
        return number
    }
    
    private func verifyCode() {
        guard code.count == codeLength, !isLoading, submittedCode != code else { return }
        
        submittedCode = code
        isLoading = true
        errorMessage = nil
        focusedField = nil
        
        Task { @MainActor in
            do {
                _ = try await authService.verifyOTP(phoneNumber: phoneNumber, code: code)
                isLoading = false
                onVerified()
            } catch {
                isLoading = false
                submittedCode = nil
                errorMessage = friendlyVerificationErrorMessage(error)
                code = ""
                focusedField = 0
            }
        }
    }

    private func resendCode() {
        guard canResend else { return }

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let accessCode = Constants.sendCompanyAccessCodeToBackend ? companyAccessCode : nil
                _ = try await authService.requestOTP(phoneNumber: phoneNumber, companyAccessCode: accessCode)
                isLoading = false
                submittedCode = nil
                code = ""
                focusedField = 0
                canResend = false
                resendTimer = 30
                startResendTimer()
            } catch {
                isLoading = false
                errorMessage = friendlyVerificationErrorMessage(error)
            }
        }
    }

    private func friendlyVerificationErrorMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't verify that code right now. Check your connection and try again."
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
        case .httpError(400, let message), .httpError(403, let message):
            let lowered = message.lowercased()
            if lowered.contains("access grant") || lowered.contains("access code") {
                return "Your access session expired. Go back one step and request a new code."
            }
            return "That verification code wasn't accepted. Request a new code and try again."
        case .httpError(429, _):
            return "Too many verification attempts. Wait a moment, then try again."
        case .networkError:
            return "We couldn't reach the server. Check your connection and try again."
        case .unauthorized:
            return "This verification session expired. Request a new code and try again."
        default:
            return "We couldn't verify that code right now. Request a new code and try again."
        }
    }
    
    private func startResendTimer() {
        stopResendTimer()
        resendCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if resendTimer > 0 {
                resendTimer -= 1
            } else {
                canResend = true
                timer.invalidate()
                resendCountdownTimer = nil
            }
        }
    }

    private func stopResendTimer() {
        resendCountdownTimer?.invalidate()
        resendCountdownTimer = nil
    }
}

struct CodeDigitBox: View {
    let digit: String
    let isFocused: Bool
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? Color.veriBlue : Color.gray.opacity(0.2), lineWidth: isFocused ? 2 : 1)
                )
            
            if digit.isEmpty {
                // Empty placeholder
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            } else {
                Text(digit)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.veriDark)
            }
        }
        .frame(width: 48, height: 56)
    }
}

#Preview {
    VerificationCodeView(
        phoneNumber: "+15551234567",
        companyAccessCode: nil,
        code: .constant(""),
        onVerified: {},
        onBack: {}
    )
    .environmentObject(AuthService())
}
