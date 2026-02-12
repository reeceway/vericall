import SwiftUI

struct UITestView: View {
    @State private var confidence: Float = 0.95
    @State private var isHuman: Bool = true

    private var detectionResult: DeepfakeDetectionResult {
        DeepfakeDetectionResult(
            isHuman: isHuman,
            confidence: confidence,
            label: isHuman ? "real" : "fake",
            processingTimeMs: 18.0
        )
    }

    var body: some View {
        VStack(spacing: 40) {
            Text("UI Isolation Test")
                .font(.largeTitle)
                .padding(.top, 60)

            Spacer()

            DeepfakeIndicatorView(
                result: detectionResult,
                isAnalyzing: false
            )
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            Spacer()

            VStack(spacing: 20) {
                Text("Confidence: \(Int(confidence * 100))%")
                    .font(.title2)
                    .fontWeight(.bold)

                Slider(value: $confidence, in: 0...1, step: 0.01)
                    .padding(.horizontal)

                Toggle("Is Human", isOn: $isHuman)
                    .padding(.horizontal)
            }
            .padding()

            Spacer()
        }
    }
}

struct UITestView_Previews: PreviewProvider {
    static var previews: some View {
        UITestView()
    }
}
