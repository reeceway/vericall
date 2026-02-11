import SwiftUI

/// Voice enrollment screen for the user's own voice thumbprint
/// This is shown after first login to capture the user's voice signature
struct SelfVoiceEnrollmentView: View {
    
    @StateObject private var enrollmentService = VoiceEnrollmentService()
    @EnvironmentObject var authService: AuthService
    
    let onComplete: () -> Void
    
    @State private var showPermissionAlert = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCompleteView = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                if showCompleteView {
                    selfEnrollmentCompleteView
                } else {
                    mainEnrollmentView
                }
            }
            .navigationTitle("Voice Setup")
            .navigationBarTitleDisplayMode(.large)
            .alert("Microphone Permission Required", isPresented: $showPermissionAlert) {
                Button("Settings", role: .none) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("VeriCall needs microphone access to record your voice for secure verification.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
            .task {
                await initializeEnrollment()
            }
            .onChange(of: enrollmentService.state) { newState in
                handleStateChange(newState)
            }
        }
    }
    
    // MARK: - Main Enrollment View
    
    private var mainEnrollmentView: some View {
        VStack(spacing: 0) {
            // Header explanation
            headerSection
            
            ScrollView {
                VStack(spacing: 24) {
                    // Progress indicator
                    progressSection
                    
                    // Current phrase card
                    phraseCard
                    
                    // Audio visualizer
                    visualizerSection
                    
                    // Action buttons
                    actionButtons
                }
                .padding()
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 50))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("Create Your Voice ID")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Record 5 phrases to create your unique voice thumbprint. This 192-dimensional signature stays on your device and is used to verify your identity during calls.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 20)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Progress Section
    
    private var progressSection: some View {
        VStack(spacing: 16) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 16)
                    
                    RoundedRectangle(cornerRadius: 8)
                        .fill(progressGradient)
                        .frame(width: geometry.size.width * CGFloat(enrollmentService.progress.percentageComplete / 100), height: 16)
                        .animation(.easeInOut(duration: 0.3), value: enrollmentService.progress.percentageComplete)
                }
            }
            .frame(height: 16)
            
            // Progress text
            HStack {
                Text("Phrase \(enrollmentService.progress.currentPhrase + 1) of \(enrollmentService.progress.totalPhrases)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(Int(enrollmentService.progress.percentageComplete))%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
            
            // Phrase dots
            HStack(spacing: 8) {
                ForEach(0..<enrollmentService.progress.totalPhrases, id: \.self) { index in
                    Circle()
                        .fill(phraseDotColor(for: index))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: index == enrollmentService.progress.currentPhrase ? 2 : 0)
                        )
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }
    
    // MARK: - Phrase Card
    
    private var phraseCard: some View {
        VStack(spacing: 16) {
            if case .recording = enrollmentService.state {
                recordingIndicator
            } else if case .processing = enrollmentService.state {
                processingIndicator
            } else {
                phrasePrompt
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
        )
    }
    
    private var recordingIndicator: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 100, height: 100)
                    .scaleEffect(1.2)
                    .opacity(0.5)
                
                Circle()
                    .fill(Color.red)
                    .frame(width: 80, height: 80)
                
                Image(systemName: "mic.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
            }
            
            Text("Recording...")
                .font(.title3)
                .fontWeight(.semibold)
            
            if case .recording(_, let progress) = enrollmentService.state {
                Text("\(Int((1.0 - progress) * 5)) seconds remaining")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                ProgressView(value: progress)
                    .tint(.red)
                    .frame(width: 200)
            }
        }
    }
    
    private var processingIndicator: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.accentColor)
            
            Text("Processing voice...")
                .font(.title3)
                .fontWeight(.semibold)
            
            Text("Extracting your 192-dimensional voice signature")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var phrasePrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            if enrollmentService.progress.currentPhrase < enrollmentService.enrollmentPrompts.count {
                Text(enrollmentService.enrollmentPrompts[enrollmentService.progress.currentPhrase])
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            
            Text("Tap the button below and speak clearly")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Visualizer Section
    
    private var visualizerSection: some View {
        VStack(spacing: 12) {
            Text("Audio Level")
                .font(.caption)
                .foregroundColor(.secondary)
            
            AudioVisualizerView(
                audioLevels: Binding(get: { enrollmentService.audioSpectrum }, set: { _ in }),
                currentLevel: Binding(get: { enrollmentService.currentAudioLevel }, set: { _ in }),
                barColor: .accentColor,
                barCount: 24
            )
            .frame(height: 80)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .opacity(isRecording ? 1 : 0.3)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if case .recording = enrollmentService.state {
                Button(action: { Task { await enrollmentService.stopRecordingPhrase() } }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Recording")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(16)
                }
            } else {
                Button(action: { Task { try? await enrollmentService.startRecordingPhrase() } }) {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Start Recording")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(16)
                }
                .disabled(enrollmentService.progress.isComplete || isProcessing)
                .opacity(enrollmentService.progress.isComplete || isProcessing ? 0.5 : 1)
            }
            
            if enrollmentService.progress.currentPhrase > 0 && !isRecording {
                Button(action: resetEnrollment) {
                    Text("Start Over")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Complete View
    
    private var selfEnrollmentCompleteView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Success animation
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 200, height: 200)
                    
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 160, height: 160)
                    
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.green, .mint],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white)
                        )
                }
                
                VStack(spacing: 8) {
                    Text("Voice ID Created!")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Your unique voice thumbprint is now stored securely on your device")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            
            Spacer()
            
            // Info cards
            VStack(spacing: 16) {
                infoCard(
                    icon: "lock.shield.fill",
                    title: "Secure & Private",
                    description: "Your 192-dimensional voice signature is stored only on this device, in the secure Keychain.",
                    color: .blue
                )
                
                infoCard(
                    icon: "person.text.rectangle.fill",
                    title: "Unique to You",
                    description: "Your voice signature captures unique spectral characteristics of your voice.",
                    color: .purple
                )
                
                infoCard(
                    icon: "phone.badge.checkmark.fill",
                    title: "Call Verification",
                    description: "During calls, others can verify it's really you speaking.",
                    color: .green
                )
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Continue button
            Button(action: {
                onComplete()
            }) {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Continue to VeriCall")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(16)
            }
            .padding()
        }
    }
    
    private func infoCard(icon: String, title: String, description: String, color: Color) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }
    
    // MARK: - Helpers
    
    private var isRecording: Bool {
        if case .recording = enrollmentService.state {
            return true
        }
        return false
    }
    
    private var isProcessing: Bool {
        if case .processing = enrollmentService.state {
            return true
        }
        return false
    }
    
    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [.accentColor, .accentColor.opacity(0.7)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    private func phraseDotColor(for index: Int) -> Color {
        if index < enrollmentService.progress.currentPhrase {
            return .green
        } else if index == enrollmentService.progress.currentPhrase {
            return .accentColor
        } else {
            return Color.gray.opacity(0.3)
        }
    }
    
    // MARK: - Actions
    
    private func initializeEnrollment() async {
        do {
            try await enrollmentService.startEnrollment()
        } catch EnrollmentError.microphonePermissionDenied {
            showPermissionAlert = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func handleStateChange(_ state: EnrollmentState) {
        switch state {
        case .completed:
            // Save the signature for "self"
            if let signature = enrollmentService.getFinalSignature(contactId: "self") {
                do {
                    try VoiceKeychainService().saveSignature(signature)
                    
                    // Mark voice enrollment as complete in UserDefaults
                    UserDefaults.standard.set(true, forKey: Constants.UserDefaultsKeys.hasCompletedVoiceEnrollment)
                    
                    // Show completion view
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        showCompleteView = true
                    }
                } catch {
                    errorMessage = "Failed to save voice signature: \(error.localizedDescription)"
                    showError = true
                }
            }
        case .failed(let error):
            errorMessage = error.localizedDescription
            showError = true
        default:
            break
        }
    }
    
    private func resetEnrollment() {
        enrollmentService.reset()
    }
}

// MARK: - Preview
struct SelfVoiceEnrollmentView_Previews: PreviewProvider {
    static var previews: some View {
        SelfVoiceEnrollmentView(onComplete: {})
            .environmentObject(AuthService())
    }
}
