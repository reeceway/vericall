import SwiftUI

/// Voice enrollment onboarding screen
/// Records 5 phrases and shows progress
public struct VoiceEnrollmentView: View {
    
    @StateObject private var enrollmentService = VoiceEnrollmentService()
    let contactId: String
    let contactName: String
    let onComplete: () -> Void
    let onCancel: () -> Void
    
    @State private var showPermissionAlert = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    public init(contactId: String, contactName: String, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.contactId = contactId
        self.contactName = contactName
        self.onComplete = onComplete
        self.onCancel = onCancel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
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
        .navigationTitle("Voice Enrollment")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel", action: onCancel)
            }
        }
        .alert("Microphone Permission Required", isPresented: $showPermissionAlert) {
            Button("Settings", role: .none) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VeriCall needs microphone access to record your voice for authentication.")
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
    
    // MARK: - Subviews
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Enroll \(contactName)")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Record 5 phrases to create a secure voice signature")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
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
    
    private var phraseCard: some View {
        VStack(spacing: 16) {
            if case .recording = enrollmentService.state {
                // Recording countdown
                recordingIndicator
            } else if case .processing = enrollmentService.state {
                // Processing indicator
                processingIndicator
            } else {
                // Next phrase prompt
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
            // Recording pulse
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 100, height: 100)
                    .scaleEffect(1.2)
                    .opacity(0.5)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: UUID())
                
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
            
            // Countdown
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
            
            Text("Extracting spectral features")
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
    
    private var visualizerSection: some View {
        VStack(spacing: 12) {
            Text("Audio Level")
                .font(.caption)
                .foregroundColor(.secondary)
            
            AudioVisualizerView(
                audioLevels: $enrollmentService.audioSpectrum,
                currentLevel: $enrollmentService.currentAudioLevel,
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
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if case .recording = enrollmentService.state {
                // Stop recording button
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
                // Start recording button
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
                .disabled(enrollmentService.progress.isComplete || case .processing = enrollmentService.state)
                .opacity(enrollmentService.progress.isComplete || case .processing = enrollmentService.state ? 0.5 : 1)
            }
            
            // Retry button (only show if we have at least one phrase recorded)
            if enrollmentService.progress.currentPhrase > 0 && !isRecording {
                Button(action: resetEnrollment) {
                    Text("Start Over")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private var isRecording: Bool {
        if case .recording = enrollmentService.state {
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
            // Save the final signature
            if let signature = enrollmentService.getFinalSignature(contactId: contactId) {
                do {
                    try VoiceKeychainService().saveSignature(signature)
                    onComplete()
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
struct VoiceEnrollmentView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            VoiceEnrollmentView(
                contactId: "contact-123",
                contactName: "John Doe",
                onComplete: {},
                onCancel: {}
            )
        }
    }
}