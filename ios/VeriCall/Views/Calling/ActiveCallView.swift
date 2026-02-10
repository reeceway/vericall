import SwiftUI

struct ActiveCallView: View {
    @StateObject private var viewModel: ActiveCallViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(call: Call) {
        _viewModel = StateObject(wrappedValue: ActiveCallViewModel(call: call))
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.9),
                    Color.black.opacity(0.8),
                    Color.black.opacity(0.7)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 80)
                
                // Call status and info
                VStack(spacing: 20) {
                    // Call state
                    Text(viewModel.call.state.displayText)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.8))
                        .animation(.easeInOut, value: viewModel.call.state)
                    
                    // Verification badge
                    if viewModel.call.isVerified {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.title3)
                            Text("✓ Device Verified")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.2))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                                )
                        )
                    }
                    
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(viewModel.call.isVerified ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
                            .frame(width: 140, height: 140)
                        
                        Text(viewModel.callerInitials)
                            .font(.system(size: 56, weight: .medium))
                            .foregroundColor(viewModel.call.isVerified ? .green : .white)
                    }
                    
                    // Caller name
                    Text(viewModel.call.callerName)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.white)
                    
                    // Call duration
                    Text(viewModel.formattedDuration)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .monospacedDigit()
                    
                    // Voice match percentage
                    if let voiceMatch = viewModel.call.voiceMatchPercentage {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.title3)
                                Text("Voice Match: \(Int(voiceMatch))%")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(voiceMatchColor(voiceMatch))
                            
                            // Progress bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 6)
                                        .cornerRadius(3)
                                    
                                    Rectangle()
                                        .fill(voiceMatchColor(voiceMatch))
                                        .frame(width: geometry.size.width * CGFloat(voiceMatch / 100), height: 6)
                                        .cornerRadius(3)
                                        .animation(.easeInOut(duration: 0.3), value: voiceMatch)
                                }
                            }
                            .frame(height: 6)
                            .frame(maxWidth: 200)
                        }
                        .padding(.top, 8)
                    } else {
                        // Analyzing voice placeholder
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Analyzing voice...")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.top, 8)
                    }
                }
                
                Spacer()
                
                // Call controls
                VStack(spacing: 40) {
                    // Top row - Mute, Speaker
                    HStack(spacing: 60) {
                        // Mute button
                        CallControlButton(
                            icon: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                            label: viewModel.isMuted ? "Unmute" : "Mute",
                            color: viewModel.isMuted ? .red : .white,
                            backgroundColor: viewModel.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.2),
                            action: { viewModel.toggleMute() }
                        )
                        
                        // Speaker button
                        CallControlButton(
                            icon: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                            label: viewModel.isSpeakerOn ? "Speaker" : "Speaker",
                            color: viewModel.isSpeakerOn ? .green : .white,
                            backgroundColor: viewModel.isSpeakerOn ? Color.green.opacity(0.3) : Color.white.opacity(0.2),
                            action: { viewModel.toggleSpeaker() }
                        )
                    }
                    
                    // Hold button (optional)
                    HStack(spacing: 60) {
                        // Keypad button
                        CallControlButton(
                            icon: "number",
                            label: "Keypad",
                            color: .white,
                            backgroundColor: Color.white.opacity(0.2),
                            action: { viewModel.showKeypad() }
                        )
                        
                        // Hold button
                        CallControlButton(
                            icon: "pause.fill",
                            label: viewModel.isOnHold ? "Resume" : "Hold",
                            color: viewModel.isOnHold ? .orange : .white,
                            backgroundColor: viewModel.isOnHold ? Color.orange.opacity(0.3) : Color.white.opacity(0.2),
                            action: { viewModel.toggleHold() }
                        )
                    }
                    
                    // End call button
                    Button(action: { viewModel.endCall() }) {
                        HStack(spacing: 12) {
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                            Text("End Call")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(
                            Capsule()
                                .fill(Color.red)
                        )
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 60)
            }
            .padding()
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .sheet(isPresented: $viewModel.showKeypadSheet) {
            CallKeypadView { digit in
                viewModel.sendDTMF(digit)
            }
        }
        .alert("Call Ended", isPresented: $viewModel.callEnded) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(viewModel.endReason)
        }
    }
    
    private func voiceMatchColor(_ percentage: Double) -> Color {
        if percentage >= 90 {
            return .green
        } else if percentage >= 70 {
            return .yellow
        } else if percentage >= 50 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Call Control Button
struct CallControlButton: View {
    let icon: String
    let label: String
    let color: Color
    let backgroundColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(backgroundColor)
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                }
                
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Keypad View
struct CallKeypadView: View {
    let onDigitTap: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    private let digits = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                ForEach(digits, id: \.self) { row in
                    HStack(spacing: 40) {
                        ForEach(row, id: \.self) { digit in
                            Button(action: {
                                onDigitTap(digit)
                            }) {
                                Text(digit)
                                    .font(.system(size: 36, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 80, height: 80)
                                    .background(
                                        Circle()
                                            .fill(Color.gray.opacity(0.2))
                                    )
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("Keypad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - ViewModel
@MainActor
class ActiveCallViewModel: ObservableObject {
    @Published var call: Call
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var isOnHold = false
    @Published var callDuration: TimeInterval = 0
    @Published var showKeypadSheet = false
    @Published var callEnded = false
    @Published var endReason = "Call ended"
    
    private let callManager = CallManager.shared
    private var timer: Timer?
    
    var callerInitials: String {
        let name = call.direction == .incoming ? call.callerName : call.recipientName
        let components = name.split(separator: " ")
        if components.count > 1 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
        }
    }
    
    var formattedDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    init(call: Call) {
        self.call = call
        self.callDuration = call.duration
    }
    
    func onAppear() {
        startDurationTimer()
        
        // Listen for call updates
        Task {
            for await updatedCall in callManager.$currentCall.values {
                if let updatedCall = updatedCall, updatedCall.id == call.id {
                    await MainActor.run {
                        self.call = updatedCall
                        
                        if updatedCall.state == .ended || updatedCall.state == .failed {
                            self.endReason = updatedCall.state.displayText
                            self.callEnded = true
                        }
                    }
                } else if updatedCall == nil {
                    await MainActor.run {
                        self.callEnded = true
                    }
                }
            }
        }
    }
    
    func onDisappear() {
        timer?.invalidate()
        timer = nil
    }
    
    func toggleMute() {
        isMuted.toggle()
        Task {
            do {
                try await callManager.setMute(isMuted)
            } catch {
                await MainActor.run {
                    isMuted.toggle() // Revert on error
                }
            }
        }
    }
    
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        Task {
            do {
                try await callManager.setSpeaker(isSpeakerOn)
            } catch {
                await MainActor.run {
                    isSpeakerOn.toggle() // Revert on error
                }
            }
        }
    }
    
    func toggleHold() {
        isOnHold.toggle()
        Task {
            do {
                if isOnHold {
                    try await callManager.holdCall()
                } else {
                    try await callManager.resumeCall()
                }
            } catch {
                await MainActor.run {
                    isOnHold.toggle() // Revert on error
                }
            }
        }
    }
    
    func showKeypad() {
        showKeypadSheet = true
    }
    
    func sendDTMF(_ digit: String) {
        Task {
            try? await callManager.sendDTMF(digit)
        }
    }
    
    func endCall() {
        Task {
            do {
                try await callManager.endCall()
                callEnded = true
            } catch {
                endReason = error.localizedDescription
                callEnded = true
            }
        }
    }
    
    private func startDurationTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.callDuration += 1
            }
        }
    }
}

// MARK: - Preview
struct ActiveCallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Active call with voice match
            ActiveCallView(call: Call(
                id: "1",
                callerId: "user123",
                callerName: "Alice Johnson",
                recipientId: "user456",
                recipientName: "Me",
                direction: .incoming,
                state: .connected,
                startedAt: Date().addingTimeInterval(-125),
                endedAt: nil,
                isVerified: true,
                voiceMatchPercentage: 87.5
            ))
        }
    }
}
