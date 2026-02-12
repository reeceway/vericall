import SwiftUI

/// Displays AI deepfake detection result with color-coded indicator
public struct DeepfakeIndicatorView: View {

    let result: DeepfakeDetectionResult?
    let isAnalyzing: Bool

    @State private var pulseAnimation = false

    public init(result: DeepfakeDetectionResult? = nil, isAnalyzing: Bool = false) {
        self.result = result
        self.isAnalyzing = isAnalyzing
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Main indicator
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)

                Circle()
                    .trim(from: 0, to: result != nil ? CGFloat(result!.confidence) : 0)
                    .stroke(
                        indicatorColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: result?.confidence)

                if isAnalyzing {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )
                }

                VStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(indicatorColor)

                    Text(statusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 180, height: 180)

            if let result = result {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: result.isHuman ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(indicatorColor)
                        Text(result.isHuman ? "Human Voice" : "AI/Deepfake Detected")
                            .font(.headline)
                            .foregroundColor(indicatorColor)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text("\(String(format: "%.0f", result.processingTimeMs))ms")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(indicatorColor.opacity(0.1))
                )
            } else if isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing audio...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.blue.opacity(0.1))
                )
            }
        }
        .padding()
        .onAppear {
            pulseAnimation = true
        }
    }

    private var statusText: String {
        guard let result = result else {
            return isAnalyzing ? "Analyzing" : "No Data"
        }
        return result.isHuman ? "Human" : "AI"
    }

    private var indicatorColor: Color {
        guard let result = result else {
            return isAnalyzing ? .blue : .gray
        }
        return result.isHuman ? .green : .red
    }

    private var iconName: String {
        guard let result = result else {
            return isAnalyzing ? "waveform" : "questionmark.circle"
        }
        return result.isHuman ? "person.fill.checkmark" : "exclamationmark.triangle.fill"
    }
}

// MARK: - Compact Indicator (for call screen overlay)
public struct CompactDeepfakeIndicatorView: View {

    let result: DeepfakeDetectionResult?
    let isAnalyzing: Bool

    public init(result: DeepfakeDetectionResult?, isAnalyzing: Bool) {
        self.result = result
        self.isAnalyzing = isAnalyzing
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.2))
                    .frame(width: 40, height: 40)

                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(indicatorColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 4) {
                    if isAnalyzing && result == nil {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let result = result {
                Text("\(Int(result.confidence * 100))%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(indicatorColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        )
    }

    private var indicatorColor: Color {
        guard let result = result else {
            return isAnalyzing ? .blue : .gray
        }
        return result.isHuman ? .green : .red
    }

    private var iconName: String {
        guard let result = result else {
            return isAnalyzing ? "waveform" : "person.crop.circle.badge.questionmark"
        }
        return result.isHuman ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }

    private var titleText: String {
        guard let result = result else {
            return isAnalyzing ? "Analyzing Audio" : "Not Analyzed"
        }
        return result.isHuman ? "Human Voice" : "AI Detected"
    }

    private var subtitleText: String {
        guard let result = result else {
            return isAnalyzing ? "Running AI detection..." : "No audio data"
        }
        return result.isHuman ? "Real person speaking" : "Possible deepfake detected"
    }
}
