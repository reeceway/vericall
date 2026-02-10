import SwiftUI

/// Real-time audio visualizer for recording feedback
public struct AudioVisualizerView: View {
    
    @Binding var audioLevels: [Float]
    @Binding var currentLevel: Float
    
    var barColor: Color = .blue
    var barCount: Int = 32
    var barWidth: CGFloat = 4
    var barSpacing: CGFloat = 2
    
    @State private var animatedLevels: [CGFloat] = Array(repeating: 0.1, count: 32)
    
    public init(audioLevels: Binding<[Float]>, currentLevel: Binding<Float>, 
                barColor: Color = .blue, barCount: Int = 32) {
        self._audioLevels = audioLevels
        self._currentLevel = currentLevel
        self.barColor = barColor
        self.barCount = barCount
    }
    
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barColorForIndex(index))
                        .frame(width: barWidth)
                        .frame(height: animatedLevels[index] * geometry.size.height)
                        .animation(.easeOut(duration: 0.05), value: animatedLevels[index])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: audioLevels) { newLevels in
                updateLevels(from: newLevels)
            }
            .onChange(of: currentLevel) { _ in
                updateLevels(from: audioLevels)
            }
        }
    }
    
    private func barColorForIndex(_ index: Int) -> Color {
        // Gradient from blue to purple based on intensity
        let intensity = animatedLevels[index]
        if intensity > 0.8 {
            return .red
        } else if intensity > 0.5 {
            return .orange
        } else {
            return barColor.opacity(0.5 + Double(intensity) * 0.5)
        }
    }
    
    private func updateLevels(from newLevels: [Float]) {
        guard !newLevels.isEmpty else {
            // Use current level to generate synthetic bars when no spectrum data
            var syntheticLevels: [CGFloat] = []
            for i in 0..<barCount {
                let phase = Double(i) / Double(barCount) * .pi * 2
                let wave = sin(phase + Date().timeIntervalSince1970 * 10) * 0.3 + 0.3
                let level = CGFloat(currentLevel) * wave + 0.1
                syntheticLevels.append(min(max(level, 0.1), 1.0))
            }
            animatedLevels = syntheticLevels
            return
        }
        
        // Map spectrum data to bar count
        var mappedLevels: [CGFloat] = []
        let binsPerBar = max(1, newLevels.count / barCount)
        
        for i in 0..<barCount {
            let startIdx = i * binsPerBar
            let endIdx = min(startIdx + binsPerBar, newLevels.count)
            
            var sum: Float = 0
            for j in startIdx..<endIdx {
                sum += newLevels[j]
            }
            
            let average = sum / Float(endIdx - startIdx)
            // Normalize and apply some visual scaling
            let normalized = CGFloat(min(max(average * 5, 0.05), 1.0))
            mappedLevels.append(normalized)
        }
        
        animatedLevels = mappedLevels
    }
}

// MARK: - Circular Audio Visualizer
public struct CircularAudioVisualizerView: View {
    
    @Binding var audioLevel: Float
    var activeColor: Color = .green
    var inactiveColor: Color = .gray.opacity(0.3)
    var ringCount: Int = 3
    
    @State private var scale: CGFloat = 1.0
    
    public init(audioLevel: Binding<Float>, activeColor: Color = .green, ringCount: Int = 3) {
        self._audioLevel = audioLevel
        self.activeColor = activeColor
        self.ringCount = ringCount
    }
    
    public var body: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                Circle()
                    .stroke(
                        colorForRing(index),
                        lineWidth: 3
                    )
                    .frame(
                        width: 60 + CGFloat(index) * 40,
                        height: 60 + CGFloat(index) * 40
                    )
                    .scaleEffect(scaleForRing(index))
                    .opacity(opacityForRing(index))
                    .animation(
                        .easeInOut(duration: 0.1 + Double(index) * 0.05)
                        .repeatForever(autoreverses: true),
                        value: scale
                    )
            }
        }
        .onChange(of: audioLevel) { newLevel in
            scale = 1.0 + CGFloat(newLevel) * 0.3
        }
        .onAppear {
            // Start pulsing animation
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                scale = 1.05
            }
        }
    }
    
    private func colorForRing(_ index: Int) -> Color {
        let threshold = Float(index + 1) / Float(ringCount + 1)
        return audioLevel > threshold ? activeColor : inactiveColor
    }
    
    private func scaleForRing(_ index: Int) -> CGFloat {
        1.0 + CGFloat(audioLevel) * 0.1 * CGFloat(index + 1)
    }
    
    private func opacityForRing(_ index: Int) -> Double {
        let threshold = Float(index) / Float(ringCount)
        return audioLevel > threshold ? 0.8 : 0.2
    }
}

// MARK: - Waveform Visualizer
public struct WaveformVisualizerView: View {
    
    @Binding var audioLevel: Float
    var color: Color = .blue
    var barCount: Int = 40
    
    @State private var bars: [CGFloat] = Array(repeating: 0.1, count: 40)
    
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    public init(audioLevel: Binding<Float>, color: Color = .blue, barCount: Int = 40) {
        self._audioLevel = audioLevel
        self.color = color
        self.barCount = barCount
    }
    
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: (geometry.size.width - CGFloat(barCount - 1) * 2) / CGFloat(barCount))
                        .frame(height: bars[index] * geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onReceive(timer) { _ in
            updateBars()
        }
    }
    
    private func updateBars() {
        var newBars: [CGFloat] = []
        let baseLevel = CGFloat(audioLevel)
        
        for i in 0..<barCount {
            // Create a wave pattern centered around middle
            let center = Double(barCount) / 2.0
            let distance = abs(Double(i) - center) / center
            let wave = exp(-distance * distance * 2) // Gaussian envelope
            
            // Add some randomness
            let noise = CGFloat.random(in: 0...0.2)
            let value = baseLevel * CGFloat(wave) + noise * 0.1
            
            newBars.append(min(max(value, 0.05), 1.0))
        }
        
        bars = newBars
    }
}

// MARK: - Preview
struct AudioVisualizerView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            AudioVisualizerView(
                audioLevels: .constant([0.5, 0.8, 0.3, 0.9, 0.4, 0.7, 0.2, 0.6]),
                currentLevel: .constant(0.7)
            )
            .frame(height: 100)
            .background(Color.black.opacity(0.1))
            .cornerRadius(12)
            
            CircularAudioVisualizerView(
                audioLevel: .constant(0.7),
                activeColor: .green
            )
            .frame(height: 200)
            
            WaveformVisualizerView(
                audioLevel: .constant(0.6),
                color: .purple
            )
            .frame(height: 100)
            .background(Color.black.opacity(0.1))
            .cornerRadius(12)
        }
        .padding()
    }
}