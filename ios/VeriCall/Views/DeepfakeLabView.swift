import SwiftUI

/// Legacy lab view — replaced by the live AI chips in VoIPActiveCallView.
/// Kept as a placeholder so the project file reference still compiles.
struct DeepfakeLabView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("AI Analysis")
                .font(.largeTitle).bold()
            Text("Real-time analysis now runs during calls.\nOpen a call to see spoof detection and speaker verification.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding()
        }
        .padding()
    }
}
