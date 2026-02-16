import SwiftUI

struct DeepfakeLabView: View {
    @StateObject private var detectionService = DeepfakeDetectionService.shared
    @StateObject private var audioService = AudioStreamService.shared
    
    @State private var gain: Float = 1.0
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Deepfake Lab")
                .font(.largeTitle)
                .bold()
            
            // Status
            if let result = detectionService.detectionResult {
                VStack {
                    Text(result.isHuman ? "HUMAN" : "FAKE")
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundColor(result.isHuman ? .green : .red)
                    
                    Text("Confidence: \(Int(result.confidence * 100))%")
                        .font(.title2)
                    
                    Text("Time: \(Int(result.processingTimeMs))ms")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
            } else {
                Text("Waiting for audio...")
                    .padding()
            }
            
            Divider()
            
            // Controls
            VStack(alignment: .leading, spacing: 15) {
                Text(detectionService.lastAudioStats)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(5)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(5)
                
                Divider()
                
                Text("Input Gain: \(String(format: "%.1f", gain))x")
                Slider(value: $gain, in: 0.1...10.0, step: 0.1)
                    .onChange(of: gain) { newValue in
                        detectionService.inputGain = newValue
                    }
                
                Toggle("Enable Normalization", isOn: $detectionService.useNormalization)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                
                // RTP Toggle removed (Legacy)
            }
            .padding()
            
            Button(action: toggleLab) {
                Text(isRunning ? "Stop Lab" : "Start Lab")
                    .font(.title3)
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isRunning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding()
            
            Spacer()
        }
        .padding()
        .onAppear {
            // Set initial gain
            gain = detectionService.inputGain
        }
        .onDisappear {
            stopLab()
        }
    }
    
    private func toggleLab() {
        if isRunning {
            stopLab()
        } else {
            startLab()
        }
    }
    
    private func startLab() {
        // Set service to Local mode
        detectionService.inputSource = .local
        detectionService.inputGain = gain
        
        // Start Audio (Local Capture)
        audioService.startStreaming()
        
        // Start Detection
        detectionService.startDetection()
        
        isRunning = true
    }
    
    private func stopLab() {
        audioService.stopStreaming()
        detectionService.stopDetection()
        detectionService.inputSource = .remote // Reset
        isRunning = false
    }
}
