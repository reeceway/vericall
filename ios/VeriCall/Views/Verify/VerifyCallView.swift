import SwiftUI
import AVFoundation
import AudioToolbox

/// Main verification view - the core feature of VeriCall
/// User opens this during a call to verify if the caller is who they claim to be
struct VerifyCallView: View {
    @StateObject private var viewModel = VerifyCallViewModel()
    @State private var selectedContact: EnrolledContact?
    @State private var showingContactPicker = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient based on verification state
                backgroundGradient
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    if viewModel.isVerifying {
                        // Active verification UI
                        activeVerificationView
                    } else {
                        // Setup UI - select who to verify
                        setupView
                    }
                }
                .padding()
            }
            .navigationTitle("Verify Call")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingContactPicker) {
                EnrolledContactPicker(selectedContact: $selectedContact)
            }
            .onChange(of: selectedContact) { contact in
                if let contact = contact {
                    viewModel.selectedContact = contact
                }
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: LinearGradient {
        switch viewModel.verificationState {
        case .idle, .listening:
            return LinearGradient(
                colors: [Color(.systemBackground), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .verified:
            return LinearGradient(
                colors: [Color.green.opacity(0.1), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .mismatch:
            return LinearGradient(
                colors: [Color.red.opacity(0.2), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .uncertain:
            return LinearGradient(
                colors: [Color.orange.opacity(0.1), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
    
    // MARK: - Setup View
    
    private var setupView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.veriBlue)
            
            // Instructions
            VStack(spacing: 12) {
                Text("Verify a Caller")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Select who you're expecting to talk to, then put your phone on speaker and tap Start")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Contact selector
            Button(action: { showingContactPicker = true }) {
                HStack {
                    if let contact = viewModel.selectedContact {
                        // Selected contact
                        Circle()
                            .fill(Color.veriBlue.opacity(0.2))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Text(contact.initials)
                                    .font(.headline)
                                    .foregroundColor(.veriBlue)
                            )
                        
                        VStack(alignment: .leading) {
                            Text(contact.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Voice enrolled")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        // No selection
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundColor(.veriBlue)
                        
                        Text("Select a contact to verify")
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Start button
            Button(action: { viewModel.startVerification() }) {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("Start Verification")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.selectedContact != nil ? Color.veriBlue : Color.gray)
                .cornerRadius(16)
            }
            .disabled(viewModel.selectedContact == nil)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
    
    // MARK: - Active Verification View
    
    private var activeVerificationView: some View {
        VStack(spacing: 24) {
            // Contact being verified
            if let contact = viewModel.selectedContact {
                VStack(spacing: 8) {
                    Text("Verifying")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(contact.name)
                        .font(.title2)
                        .fontWeight(.bold)
                }
            }
            
            Spacer()
            
            // Main verification indicator
            ZStack {
                // Outer ring - pulsing when listening
                Circle()
                    .stroke(ringColor.opacity(0.3), lineWidth: 8)
                    .frame(width: 200, height: 200)
                
                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.matchPercentage))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.matchPercentage)
                
                // Inner content
                VStack(spacing: 8) {
                    // Status icon
                    Image(systemName: statusIcon)
                        .font(.system(size: 40))
                        .foregroundColor(ringColor)
                    
                    // Percentage
                    Text("\(Int(viewModel.matchPercentage * 100))%")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(ringColor)
                    
                    // Status text
                    Text(statusText)
                        .font(.headline)
                        .foregroundColor(ringColor)
                }
            }
            
            // Audio level indicator
            AudioLevelView(level: viewModel.audioLevel)
                .frame(height: 40)
                .padding(.horizontal, 32)
            
            Spacer()
            
            // Warning banner (if mismatch)
            if viewModel.verificationState == .mismatch {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                    Text("VOICE DOES NOT MATCH!")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red)
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            // Stop button
            Button(action: { viewModel.stopVerification() }) {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop Verification")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red.opacity(0.8))
                .cornerRadius(16)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
    
    // MARK: - Computed Properties
    
    private var ringColor: Color {
        switch viewModel.verificationState {
        case .idle, .listening:
            return .veriBlue
        case .verified:
            return .green
        case .mismatch:
            return .red
        case .uncertain:
            return .orange
        }
    }
    
    private var statusIcon: String {
        switch viewModel.verificationState {
        case .idle:
            return "waveform"
        case .listening:
            return "waveform"
        case .verified:
            return "checkmark.shield.fill"
        case .mismatch:
            return "exclamationmark.triangle.fill"
        case .uncertain:
            return "questionmark.circle.fill"
        }
    }
    
    private var statusText: String {
        switch viewModel.verificationState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening..."
        case .verified:
            return "Verified"
        case .mismatch:
            return "MISMATCH"
        case .uncertain:
            return "Uncertain"
        }
    }
}

// MARK: - Audio Level View

struct AudioLevelView: View {
    let level: Float
    private let barCount = 20
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: index))
                    .frame(width: 8)
                    .scaleEffect(y: barScale(for: index), anchor: .bottom)
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }
    
    private func barScale(for index: Int) -> CGFloat {
        let threshold = Float(index) / Float(barCount)
        return level > threshold ? 1.0 : 0.2
    }
    
    private func barColor(for index: Int) -> Color {
        let progress = Float(index) / Float(barCount)
        if progress < 0.5 {
            return .green
        } else if progress < 0.75 {
            return .yellow
        } else {
            return .red
        }
    }
}

// MARK: - ViewModel

enum VerificationState {
    case idle
    case listening
    case verified
    case mismatch
    case uncertain
}

@MainActor
class VerifyCallViewModel: ObservableObject {
    @Published var selectedContact: EnrolledContact?
    @Published var isVerifying = false
    @Published var verificationState: VerificationState = .idle
    @Published var matchPercentage: Double = 0.0
    @Published var audioLevel: Float = 0.0
    
    private let voiceVerifier = LocalVoiceVerifier()
    private let keychainService = VoiceKeychainService()
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    // Verification thresholds
    private let verifiedThreshold: Double = 0.75
    private let uncertainThreshold: Double = 0.55
    
    // Audio buffer for analysis
    private var audioBuffer: [Float] = []
    private let analysisWindowSize = 16000 * 2  // 2 seconds of audio
    
    // Alert tracking
    private var hasShownMismatchAlert = false
    private var consecutiveMismatches = 0
    private let mismatchAlertThreshold = 3  // Alert after 3 consecutive mismatches
    
    func startVerification() {
        guard let contact = selectedContact else { return }
        
        // Load stored voice signature
        guard let signature = keychainService.loadSignature(for: contact.id) else {
            print("[VerifyCall] No voice signature found for \(contact.name)")
            return
        }
        
        isVerifying = true
        verificationState = .listening
        hasShownMismatchAlert = false
        consecutiveMismatches = 0
        audioBuffer = []
        
        startAudioCapture(storedSignature: signature)
    }
    
    func stopVerification() {
        stopAudioCapture()
        isVerifying = false
        verificationState = .idle
        matchPercentage = 0.0
        audioLevel = 0.0
    }
    
    private func startAudioCapture(storedSignature: VoiceSignature) {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            print("[VerifyCall] Audio session error: \(error)")
            return
        }
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        let format = inputNode!.outputFormat(forBus: 0)
        
        inputNode!.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, storedSignature: storedSignature)
        }
        
        do {
            try audioEngine.start()
            print("[VerifyCall] Audio capture started")
        } catch {
            print("[VerifyCall] Failed to start audio engine: \(error)")
        }
    }
    
    private func stopAudioCapture() {
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("[VerifyCall] Failed to deactivate audio session: \(error)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, storedSignature: VoiceSignature) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frames = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        
        // Calculate audio level for visualization
        let level = samples.map { abs($0) }.max() ?? 0
        
        // Add to buffer
        audioBuffer.append(contentsOf: samples)
        
        // Keep buffer at analysis window size
        if audioBuffer.count > analysisWindowSize {
            audioBuffer.removeFirst(audioBuffer.count - analysisWindowSize)
        }
        
        Task { @MainActor in
            self.audioLevel = level
            
            // Only analyze when we have enough audio
            if self.audioBuffer.count >= self.analysisWindowSize {
                self.analyzeAudio(storedSignature: storedSignature)
            }
        }
    }
    
    private func analyzeAudio(storedSignature: VoiceSignature) {
        let result = voiceVerifier.verify(audioData: audioBuffer, against: storedSignature)
        let similarity = Double(result.similarity)
        
        // Smooth the percentage
        matchPercentage = matchPercentage * 0.7 + similarity * 0.3
        
        // Update state based on match
        let previousState = verificationState
        
        if matchPercentage >= verifiedThreshold {
            verificationState = .verified
            consecutiveMismatches = 0
        } else if matchPercentage >= uncertainThreshold {
            verificationState = .uncertain
            consecutiveMismatches = 0
        } else {
            verificationState = .mismatch
            consecutiveMismatches += 1
            
            // Trigger alert if persistent mismatch
            if consecutiveMismatches >= mismatchAlertThreshold && !hasShownMismatchAlert {
                triggerMismatchAlert()
                hasShownMismatchAlert = true
            }
        }
        
        // If state changed to mismatch, provide immediate feedback
        if previousState != .mismatch && verificationState == .mismatch {
            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
        
        print("[VerifyCall] Match: \(Int(matchPercentage * 100))% - State: \(verificationState)")
    }
    
    private func triggerMismatchAlert() {
        print("[VerifyCall] 🚨 VOICE MISMATCH ALERT!")
        
        // Strong haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        
        // Play alert sound
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        AudioServicesPlaySystemSound(1521)  // Haptic alert sound
        
        // Show local notification
        Task {
            await showMismatchNotification()
        }
    }
    
    private func showMismatchNotification() async {
        guard let contact = selectedContact else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "⚠️ VOICE MISMATCH"
        content.body = "The caller does NOT sound like \(contact.name)! Be cautious."
        content.sound = .defaultCritical
        content.interruptionLevel = .critical
        
        let request = UNNotificationRequest(
            identifier: "voice_mismatch_\(UUID().uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[VerifyCall] Failed to show notification: \(error)")
        }
    }
}

// MARK: - Enrolled Contact Model

struct EnrolledContact: Identifiable {
    let id: String
    let name: String
    let phoneNumber: String?
    
    var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Contact Picker

struct EnrolledContactPicker: View {
    @Binding var selectedContact: EnrolledContact?
    @Environment(\.dismiss) private var dismiss
    @State private var enrolledContacts: [EnrolledContact] = []
    
    private let keychainService = VoiceKeychainService()
    
    var body: some View {
        NavigationView {
            List {
                if enrolledContacts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No Enrolled Voices")
                            .font(.headline)
                        
                        Text("Add contacts and record their voice samples to verify callers.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(enrolledContacts) { contact in
                        Button(action: {
                            selectedContact = contact
                            dismiss()
                        }) {
                            HStack {
                                Circle()
                                    .fill(Color.veriBlue.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Text(contact.initials)
                                            .font(.headline)
                                            .foregroundColor(.veriBlue)
                                    )
                                
                                VStack(alignment: .leading) {
                                    Text(contact.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    
                                    if let phone = contact.phoneNumber {
                                        Text(phone)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                if selectedContact?.id == contact.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.veriBlue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadEnrolledContacts()
        }
    }
    
    private func loadEnrolledContacts() {
        // Load contacts that have voice signatures stored
        // For now, check for "self" signature and any stored contact signatures
        var contacts: [EnrolledContact] = []
        
        // Add self if enrolled
        if keychainService.signatureExists(for: "self") {
            let userName = UserDefaults.standard.string(forKey: "userName") ?? "Me"
            contacts.append(EnrolledContact(id: "self", name: userName, phoneNumber: nil))
        }
        
        // TODO: Load other enrolled contacts from storage
        // This would iterate through stored voice signatures
        
        enrolledContacts = contacts
    }
}

// MARK: - Preview

struct VerifyCallView_Previews: PreviewProvider {
    static var previews: some View {
        VerifyCallView()
    }
}
