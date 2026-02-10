import SwiftUI

struct OnboardingContainerView: View {
    @State private var currentStep: OnboardingStep = .welcome
    @State private var phoneNumber: String = ""
    @State private var verificationCode: String = ""
    
    enum OnboardingStep {
        case welcome
        case phoneInput
        case verification
        case profileSetup
    }
    
    var body: some View {
        NavigationStack {
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeView(onGetStarted: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            currentStep = .phoneInput
                        }
                    })
                    
                case .phoneInput:
                    PhoneInputView(
                        phoneNumber: $phoneNumber,
                        onContinue: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                currentStep = .verification
                            }
                        },
                        onBack: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                currentStep = .welcome
                            }
                        }
                    )
                    
                case .verification:
                    VerificationCodeView(
                        phoneNumber: phoneNumber,
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
                            // Profile setup complete - auth state will trigger navigation change
                        }
                    )
                }
            }
        }
    }
}
