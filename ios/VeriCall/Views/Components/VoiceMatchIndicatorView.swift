import SwiftUI

/// Displays voice match percentage with color-coded indicator
public struct VoiceMatchIndicatorView: View {
    
    let result: VoiceVerificationResult?
    let isVerifying: Bool
    
    @State private var animatedPercentage: CGFloat = 0
    @State private var pulseAnimation = false
    
    public init(result: VoiceVerificationResult? = nil, isVerifying: Bool = false) {
        self.result = result
        self.isVerifying = isVerifying
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // Main percentage display
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                
                // Progress ring
                Circle()
                    .trim(from: 0, to: animatedPercentage)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: indicatorColors),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: animatedPercentage)
                
                // Inner glow for active state
                if isVerifying {
                    Circle()
                        .fill(indicatorColor.opacity(0.1))
                        .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )
                }
                
                // Percentage text
                VStack(spacing: 4) {
                    Text(percentageText)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(indicatorColor)
                    
                    Text(statusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            
            // Status details
            if let result = result {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: iconName)
                            .foregroundColor(indicatorColor)
                        Text(confidenceText)
                            .font(.headline)
                            .foregroundColor(indicatorColor)
                    }
                    
                    // Processing time indicator
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
            } else if isVerifying {
                // Analyzing state
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing voice...")
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
            
            // Legend
            HStack(spacing: 16) {
                LegendItem(color: .green, label: ">75%")
                LegendItem(color: .orange, label: "55-75%")
                LegendItem(color: .red, label: "<55%")
            }
            .padding(.top, 8)
        }
        .padding()
        .onChange(of: result?.similarity) { newValue in
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPercentage = CGFloat(newValue ?? 0)
            }
        }
        .onAppear {
            animatedPercentage = CGFloat(result?.similarity ?? 0)
            pulseAnimation = true
        }
    }
    
    // MARK: - Computed Properties
    
    private var percentageText: String {
        guard let similarity = result?.similarity else {
            return isVerifying ? "..." : "--"
        }
        return "\(Int(similarity * 100))%"
    }
    
    private var statusText: String {
        guard let result = result else {
            return isVerifying ? "Verifying" : "No Data"
        }
        return result.isMatch ? "Verified" : "Unknown"
    }
    
    private var indicatorColor: Color {
        guard let similarity = result?.similarity else {
            return isVerifying ? .blue : .gray
        }
        
        if similarity >= VoiceVerificationThresholds.highConfidence {
            return .green
        } else if similarity >= VoiceVerificationThresholds.mediumConfidence {
            return .orange
        } else {
            return .red
        }
    }
    
    private var indicatorColors: [Color] {
        guard result != nil else {
            return [.gray, .gray.opacity(0.3)]
        }
        
        switch indicatorColor {
        case .green:
            return [.green, .mint]
        case .orange:
            return [.orange, .yellow]
        case .red:
            return [.red, .pink]
        default:
            return [.gray, .gray.opacity(0.3)]
        }
    }
    
    private var iconName: String {
        guard let result = result else { return "questionmark.circle" }
        
        if result.confidence == .high {
            return "checkmark.shield.fill"
        } else if result.confidence == .medium {
            return "exclamationmark.shield"
        } else {
            return "xmark.shield"
        }
    }
    
    private var confidenceText: String {
        guard let result = result else { return "Unknown" }
        
        switch result.confidence {
        case .high:
            return "High Confidence Match"
        case .medium:
            return "Medium Confidence"
        case .low:
            return "Low Confidence"
        }
    }
}

// MARK: - Legend Item
private struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Compact Indicator (for call screen overlay)
public struct CompactVoiceMatchIndicatorView: View {
    
    let result: VoiceVerificationResult?
    let isVerifying: Bool
    
    public init(result: VoiceVerificationResult?, isVerifying: Bool) {
        self.result = result
        self.isVerifying = isVerifying
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Status icon
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
                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Percentage badge
            if let similarity = result?.similarity {
                Text("\(Int(similarity * 100))%")
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
        guard let similarity = result?.similarity else {
            return isVerifying ? .blue : .gray
        }
        
        if similarity >= VoiceVerificationThresholds.highConfidence {
            return .green
        } else if similarity >= VoiceVerificationThresholds.mediumConfidence {
            return .orange
        } else {
            return .red
        }
    }
    
    private var iconName: String {
        guard let result = result else {
            return isVerifying ? "waveform" : "person.crop.circle.badge.questionmark"
        }
        
        if result.confidence == .high {
            return "checkmark.seal.fill"
        } else if result.confidence == .medium {
            return "exclamationmark.triangle"
        } else {
            return "xmark.octagon"
        }
    }
    
    private var titleText: String {
        guard let result = result else {
            return isVerifying ? "Verifying Voice" : "Voice Not Verified"
        }
        
        if result.isMatch {
            return "Voice Verified"
        } else {
            return "Voice Mismatch"
        }
    }
    
    private var subtitleText: String {
        guard let result = result else {
            return isVerifying ? "Analyzing audio..." : "No enrollment data"
        }
        
        switch result.confidence {
        case .high:
            return "High confidence match"
        case .medium:
            return "Uncertain - verify identity"
        case .low:
            return "Possible fraud detected"
        }
    }
}

// MARK: - Preview
struct VoiceMatchIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 30) {
            // High confidence
            VoiceMatchIndicatorView(
                result: VoiceVerificationResult(
                    similarity: 0.89,
                    analysisDuration: 3.0,
                    processingTimeMs: 45
                ),
                isVerifying: false
            )
            
            // Medium confidence
            VoiceMatchIndicatorView(
                result: VoiceVerificationResult(
                    similarity: 0.62,
                    analysisDuration: 3.0,
                    processingTimeMs: 42
                ),
                isVerifying: false
            )
            
            // Low confidence
            VoiceMatchIndicatorView(
                result: VoiceVerificationResult(
                    similarity: 0.34,
                    analysisDuration: 3.0,
                    processingTimeMs: 38
                ),
                isVerifying: false
            )
            
            // Verifying state
            VoiceMatchIndicatorView(
                result: nil,
                isVerifying: true
            )
        }
        .padding()
    }
}