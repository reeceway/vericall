import SwiftUI

struct ProfileSetupView: View {
    let onComplete: () -> Void
    
    @EnvironmentObject var authService: AuthService
    @State private var displayName: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isValid = false
    @FocusState private var isNameFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Navigation Bar
            HStack {
                // Empty button for alignment
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .opacity(0)
                
                Spacer()
                
                Text("Your Profile")
                    .font(.headline)
                    .foregroundColor(.veriDark)
                
                Spacer()
                
                // Empty button for alignment
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
                        Text("What should we call you?")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.veriDark)
                            .multilineTextAlignment(.center)
                        
                        Text("This is how you'll appear to others")
                            .font(.body)
                            .foregroundColor(.veriGray)
                    }
                    .padding(.top, 40)
                    
                    // Avatar Preview
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.veriBlue.opacity(0.8), .veriBlue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 120, height: 120)
                        
                        if displayName.isEmpty {
                            Image(systemName: "person.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white)
                        } else {
                            Text(initials(from: displayName))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.vertical, 20)
                    
                    // Name Input
                    VStack(spacing: 16) {
                        TextField("Your name", text: $displayName)
                            .font(.body.weight(.medium))
                            .textContentType(.name)
                            .focused($isNameFieldFocused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .background(Color.white)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isValid ? Color.veriBlue : Color.gray.opacity(0.2), lineWidth: isValid ? 2 : 1)
                            )
                            .onChange(of: displayName) { _ in
                                validateName()
                            }
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Skip option for quick onboarding
                    Button("Skip for now") {
                        completeOnboarding()
                    }
                    .font(.subheadline)
                    .foregroundColor(.veriGray)
                    .padding(.top, 16)
                    
                    Spacer()
                }
            }
            
            // Continue Button
            VStack(spacing: 0) {
                Divider()
                
                Button(action: completeOnboarding) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Complete")
                            .font(.headline)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(isValid || displayName.isEmpty ? Color.veriBlue : Color.gray.opacity(0.4))
                .cornerRadius(16)
                .disabled(isLoading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color.white)
        }
        .background(Color.veriBackground.ignoresSafeArea())
        .onAppear {
            isNameFieldFocused = true
        }
    }
    
    private func validateName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        isValid = !trimmed.isEmpty && trimmed.count >= 2
        errorMessage = nil
    }
    
    private func initials(from name: String) -> String {
        let components = name.components(separatedBy: " ")
        let initials = components.compactMap { $0.first }.prefix(2)
        return String(initials).uppercased()
    }
    
    private func completeOnboarding() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                if !displayName.isEmpty {
                    try await authService.updateProfile(displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                isLoading = false
                onComplete()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ProfileSetupView(onComplete: {})
        .environmentObject(AuthService())
}
