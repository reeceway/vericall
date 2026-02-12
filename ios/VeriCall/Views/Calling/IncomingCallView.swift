import SwiftUI

struct IncomingCallView: View {
    @StateObject private var viewModel: IncomingCallViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(call: Call) {
        _viewModel = StateObject(wrappedValue: IncomingCallViewModel(call: call))
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.9),
                    Color.black.opacity(0.7)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 60)
                
                // Caller info
                VStack(spacing: 16) {
                    // Incoming call label
                    Text("Incoming Call")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.8))
                    
                    // Verification badge (prominent)
                    if viewModel.call.isVerified {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.title2)
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
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.body)
                            Text("Unverified Caller")
                                .font(.subheadline)
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.2))
                        )
                    }
                    
                    // Caller avatar
                    ZStack {
                        Circle()
                            .fill(viewModel.call.isVerified ? Color.green.opacity(0.3) : Color.gray.opacity(0.3))
                            .frame(width: 120, height: 120)
                        
                        Text(viewModel.callerInitials)
                            .font(.system(size: 48, weight: .medium))
                            .foregroundColor(viewModel.call.isVerified ? .green : .white)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if viewModel.call.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                                .font(.title)
                                .background(Circle().fill(Color.black))
                        }
                    }
                    
                    // Caller name
                    Text(viewModel.call.callerName)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(.white)
                    
                    // Phone number or additional info
                    Text(viewModel.call.callerId)
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                    
                    // Call duration timer
                    if viewModel.callDuration > 0 {
                        Text(viewModel.formattedDuration)
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 60) {
                    // Decline button
                    Button(action: {
                        viewModel.declineCall()
                        dismiss()
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 80, height: 80)
                                Image(systemName: "phone.down.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Decline")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Accept button
                    Button(action: {
                        viewModel.acceptCall()
                        dismiss()
                    }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 80, height: 80)
                                Image(systemName: "phone.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Accept")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .padding()
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }
}

// MARK: - ViewModel
@MainActor
class IncomingCallViewModel: ObservableObject {
    @Published var call: Call
    @Published var callDuration: TimeInterval = 0
    
    private let callManager = CallManager.shared
    private var timer: Timer?
    
    var callerInitials: String {
        let name = call.callerName
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
    }
    
    func onAppear() {
        // Start timer if call is already connected
        if call.state == .connected {
            startDurationTimer()
        }
        
        // Listen for call state changes
        Task {
            for await updatedCall in callManager.$currentCall.values {
                if let updatedCall = updatedCall, updatedCall.id == call.id {
                    await MainActor.run {
                        self.call = updatedCall
                        if updatedCall.state == .connected {
                            self.startDurationTimer()
                        }
                    }
                }
            }
        }
    }
    
    func onDisappear() {
        timer?.invalidate()
        timer = nil
    }
    
    func acceptCall() {
        Task {
            do {
                try await callManager.acceptCall(call)
                startDurationTimer()
            } catch {
                print("Failed to accept call: \(error)")
            }
        }
    }
    
    func declineCall() {
        Task {
            do {
                try await callManager.declineCall(call)
            } catch {
                print("Failed to decline call: \(error)")
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
struct IncomingCallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Verified caller
            IncomingCallView(call: Call(
                id: "1",
                callerId: "user123",
                callerName: "Alice Johnson",
                recipientId: "user456",
                recipientName: "Me",
                direction: .incoming,
                state: .ringing,
                startedAt: nil,
                endedAt: nil,
                isVerified: true
            ))

            // Unverified caller
            IncomingCallView(call: Call(
                id: "2",
                callerId: "user789",
                callerName: "Unknown Caller",
                recipientId: "user456",
                recipientName: "Me",
                direction: .incoming,
                state: .ringing,
                startedAt: nil,
                endedAt: nil,
                isVerified: false
            ))
        }
    }
}
