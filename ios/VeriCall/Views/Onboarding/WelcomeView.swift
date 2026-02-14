import SwiftUI

struct WelcomeView: View {
    let onGetStarted: () -> Void
    
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // Logo/Icon
            ZStack {
                Circle()
                    .fill(Color.veriBlue.opacity(0.15))
                    .frame(width: 140, height: 140)
                
                Circle()
                    .fill(Color.veriBlue.opacity(0.25))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "phone.badge.waveform.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.veriBlue)
                    .symbolEffect(.bounce, value: isAnimating)
            }
            .scaleEffect(isAnimating ? 1.0 : 0.8)
            .opacity(isAnimating ? 1.0 : 0.0)
            
            // Title and subtitle
            VStack(spacing: 16) {
                Text("VeriCall")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.veriDark)
                
                Text("Secure, verified calls")
                    .font(.title3)
                    .foregroundColor(.veriGray)
            }
            .opacity(isAnimating ? 1.0 : 0.0)
            .offset(y: isAnimating ? 0 : 20)
            
            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(icon: "checkmark.shield.fill", text: "Verified caller identity")
                FeatureRow(icon: "lock.shield.fill", text: "End-to-end encryption")
                FeatureRow(icon: "person.2.fill", text: "Know who's calling")
            }
            .padding(.horizontal, 40)
            .opacity(isAnimating ? 1.0 : 0.0)
            .offset(y: isAnimating ? 0 : 30)
            
            Spacer()
            
            // Get Started Button
            Button(action: onGetStarted) {
                HStack {
                    Text("Get Started")
                        .font(.headline)
                    Image(systemName: "arrow.right")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.veriBlue)
                .cornerRadius(16)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(isAnimating ? 1.0 : 0.0)
            .offset(y: isAnimating ? 0 : 40)
        }
        .background(Color.veriBackground.ignoresSafeArea())
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                isAnimating = true
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(.veriBlue)
                .frame(width: 30)
            
            Text(text)
                .font(.body)
                .foregroundColor(.veriDark)
        }
    }
}


#Preview {
    WelcomeView(onGetStarted: {})
}
