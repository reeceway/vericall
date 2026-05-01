import SwiftUI

struct OnboardingContainerView: View {
    @EnvironmentObject var authService: AuthService
    @State private var currentStep: OnboardingStep = .welcome
    @State private var phoneNumber: String = ""
    @State private var verificationCode: String = ""
    @AppStorage(Constants.companyAccessCodeUserDefaultsKey) private var companyAccessCode: String = ""
    
    enum OnboardingStep {
        case welcome
        case accessCode
        case phoneInput
        case verification
        case profileSetup
        case voiceEnrollment
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let notice = authService.accountDeletionNotice {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.headline)
                        Text(notice)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            authService.accountDeletionNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(Color.green.opacity(0.12))
                }

                Group {
                    switch currentStep {
                    case .welcome:
                        WelcomeView(onGetStarted: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                currentStep = nextStepAfterWelcome
                            }
                        })

                    case .accessCode:
                        AccessCodeView(
                            accessCode: $companyAccessCode,
                            onContinue: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .phoneInput
                                }
                            },
                            onBack: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .welcome
                                }
                            }
                        )

                    case .phoneInput:
                        PhoneInputView(
                            phoneNumber: $phoneNumber,
                            companyAccessCode: companyAccessCode,
                            onContinue: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .verification
                                }
                            },
                            onBack: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = requiresFreshAccessCode ? .accessCode : .welcome
                                }
                            }
                        )

                    case .verification:
                        VerificationCodeView(
                            phoneNumber: phoneNumber,
                            companyAccessCode: companyAccessCode,
                            code: $verificationCode,
                            onVerified: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .profileSetup
                                }
                            },
                            onBack: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .phoneInput
                                }
                            }
                        )

                    case .profileSetup:
                        ProfileSetupView(
                            onComplete: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    currentStep = .voiceEnrollment
                                }
                            }
                        )

                    case .voiceEnrollment:
                        SelfVoiceEnrollmentView(
                            onComplete: {
                                // Enrollment done (or skipped) — auth state triggers navigation
                            }
                        )
                    }
                }
            }
        }
        .onAppear {
            companyAccessCode = Constants.normalizedCompanyAccessCode(companyAccessCode)
        }
        .onChange(of: companyAccessCode) { newValue in
            let normalized = Constants.normalizedCompanyAccessCode(newValue)
            if normalized != newValue {
                companyAccessCode = normalized
                return
            }

            guard Constants.requireCompanyAccessCode else { return }
            guard normalized.isEmpty else { return }

            switch currentStep {
            case .phoneInput, .verification:
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentStep = .accessCode
                }
            default:
                break
            }
        }
    }

    private var requiresFreshAccessCode: Bool {
        Constants.requireCompanyAccessCode && Constants.normalizedCompanyAccessCode(companyAccessCode).isEmpty
    }

    private var nextStepAfterWelcome: OnboardingStep {
        requiresFreshAccessCode ? .accessCode : .phoneInput
    }
}

struct AccessCodeView: View {
    @Binding var accessCode: String
    let onContinue: () -> Void
    let onBack: () -> Void

    @EnvironmentObject var authService: AuthService
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var isCodeFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.veriDark)
                }

                Spacer()

                Text("Company Access")
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
                VStack(spacing: 28) {
                    ZStack {
                        Circle()
                            .fill(Color.veriBlue.opacity(0.12))
                            .frame(width: 112, height: 112)

                        Image(systemName: "key.radiowaves.forward.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundColor(.veriBlue)
                    }
                    .padding(.top, 48)

                    VStack(spacing: 12) {
                        Text("Enter your access code")
                            .font(.system(size: 28, weight: .black, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(.veriDark)
                            .multilineTextAlignment(.center)

                        Text("Use the company code or invite link from your MSP.")
                            .font(.body)
                            .foregroundColor(.veriGray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 10) {
                        TextField("ACME-2026", text: $accessCode)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($isCodeFieldFocused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .background(Color.white)
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.veriBlue.opacity(0.45), lineWidth: 1.5)
                            )
                            .onChange(of: accessCode) { newValue in
                                accessCode = Constants.normalizedCompanyAccessCode(newValue)
                                errorMessage = nil
                            }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }

            VStack(spacing: 0) {
                Divider()

                Button(action: submitAccessCode) {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Continue")
                                .font(.headline)
                            Image(systemName: "arrow.right")
                                .font(.headline)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background((accessCode.isEmpty || isSubmitting) ? Color.gray.opacity(0.4) : Color.veriBlue)
                    .cornerRadius(16)
                }
                .disabled(accessCode.isEmpty || isSubmitting)
                .buttonStyle(ScaleButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color.white)
        }
        .background(Color.veriBackground.ignoresSafeArea())
        .onAppear {
            accessCode = Constants.normalizedCompanyAccessCode(accessCode)
            isCodeFieldFocused = accessCode.isEmpty
        }
    }

    private func submitAccessCode() {
        let normalized = Constants.normalizedCompanyAccessCode(accessCode)
        guard !normalized.isEmpty else {
            errorMessage = "Enter the access code your MSP gave you."
            return
        }

        isSubmitting = true
        errorMessage = nil

        Task { @MainActor in
            defer { isSubmitting = false }

            do {
                let validation = try await authService.validateCompanyAccessCode(phoneNumber: nil, code: normalized)
                guard validation.valid else {
                    errorMessage = validation.message ?? "That access code wasn't accepted. Check the code and try again."
                    return
                }

                accessCode = normalized
                onContinue()
            } catch {
                errorMessage = friendlyAccessCodeErrorMessage(error)
            }
        }
    }

    private func friendlyAccessCodeErrorMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "We couldn't verify that code right now. Check your connection and try again."
        }

        switch apiError {
        case .httpError(400, _):
            return "Enter the access code your MSP gave you."
        case .httpError(403, _):
            return "That access code wasn't accepted. Check the code and try again."
        case .httpError(429, _):
            return "Too many attempts. Wait a moment, then try again."
        case .httpError(_, let message):
            return message.isEmpty ? "We couldn't verify that code right now. Try again in a moment." : message
        case .networkError:
            return "We couldn't reach the server to verify that code. Check your connection and try again."
        default:
            return "We couldn't verify that code right now. Check your connection and try again."
        }
    }
}
