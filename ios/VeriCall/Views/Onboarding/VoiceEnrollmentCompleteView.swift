import SwiftUI

/// Success screen shown after voice enrollment is complete
public struct VoiceEnrollmentCompleteView: View {
    
    let contactName: String
    let onDone: () -> Void
    let onAddAnother: () -> Void
    
    @State private var showConfetti = false
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0
    
    public init(contactName: String, onDone: @escaping () -> Void, onAddAnother: @escaping () -> Void) {
        self.contactName = contactName
        self.onDone = onDone
        self.onAddAnother = onAddAnother
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Success animation
            successAnimation
            
            Spacer()
            
            // Info cards
            infoSection
            
            Spacer()
            
            // Action buttons
            actionButtons
        }
        .padding()
        .navigationTitle("Enrollment Complete")
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
            showConfetti = true
        }
    }
    
    // MARK: - Subviews
    
    private var successAnimation: some View {
        VStack(spacing: 24) {
            ZStack {
                // Background circles
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 200, height: 200)
                
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 160, height: 160)
                
                // Success icon
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
                    .scaleEffect(scale)
                    .opacity(opacity)
                
                // Confetti effect
                if showConfetti {
                    ConfettiView()
                }
            }
            
            VStack(spacing: 8) {
                Text("Voice Enrolled!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .opacity(opacity)
                
                Text("\(contactName) can now be verified by voice")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(opacity)
            }
        }
    }
    
    private var infoSection: some View {
        VStack(spacing: 16) {
            InfoCard(
                icon: "lock.shield.fill",
                title: "Secure Storage",
                description: "Voice signature stored in device Keychain. Never leaves your phone.",
                color: .blue
            )
            
            InfoCard(
                icon: "waveform.path",
                title: "192-Dimensional Fingerprint",
                description: "Unique spectral signature extracted using on-device processing.",
                color: .purple
            )
            
            InfoCard(
                icon: "checkmark.shield.fill",
                title: "Ready for Verification",
                description: "Voice will be checked during calls to confirm identity.",
                color: .green
            )
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: onDone) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Done")
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
            
            Button(action: onAddAnother) {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("Enroll Another Contact")
                }
                .font(.subheadline)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(16)
            }
        }
    }
}

// MARK: - Info Card
private struct InfoCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
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
}

// MARK: - Confetti View
private struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []
    let colors: [Color] = [.green, .blue, .purple, .orange, .pink, .yellow]
    
    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                ConfettiPiece(particle: particle)
            }
        }
        .onAppear {
            generateParticles()
        }
    }
    
    private func generateParticles() {
        for i in 0..<30 {
            let particle = ConfettiParticle(
                id: i,
                x: Double.random(in: -100...100),
                y: Double.random(in: -100...100),
                color: colors.randomElement()!,
                size: Double.random(in: 8...16),
                rotation: Double.random(in: 0...360),
                delay: Double.random(in: 0...0.5)
            )
            particles.append(particle)
        }
    }
}

private struct ConfettiPiece: View {
    let particle: ConfettiParticle
    @State private var isAnimating = false
    
    var body: some View {
        Rectangle()
            .fill(particle.color)
            .frame(width: particle.size, height: particle.size * 0.6)
            .rotationEffect(.degrees(isAnimating ? particle.rotation + 360 : particle.rotation))
            .offset(
                x: isAnimating ? particle.x * 2 : 0,
                y: isAnimating ? particle.y * 2 + 200 : 0
            )
            .opacity(isAnimating ? 0 : 1)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.5)
                    .delay(particle.delay)
                ) {
                    isAnimating = true
                }
            }
    }
}

private struct ConfettiParticle: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let color: Color
    let size: Double
    let rotation: Double
    let delay: Double
}

// MARK: - Preview
struct VoiceEnrollmentCompleteView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            VoiceEnrollmentCompleteView(
                contactName: "John Doe",
                onDone: {},
                onAddAnother: {}
            )
        }
    }
}