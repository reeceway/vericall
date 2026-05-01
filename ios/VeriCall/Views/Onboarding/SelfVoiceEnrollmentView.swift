import SwiftUI
import AVFoundation

// MARK: - View Model

@MainActor
final class EnrollmentViewModel: ObservableObject {

    enum Phase { case idle, recording, processing, done, failed }

    @Published var phase: Phase = .idle
    @Published var secondsRecorded: Double = 0
    @Published var errorMessage: String?

    let totalDuration: Double = 6.0

    private let engine = AVAudioEngine()
    private var countdownTimer: Timer?

    // Audio buffer — written from tap (remoteBufferQueue), read in stopAndEnroll
    private let sampleQueue = DispatchQueue(label: "com.vericall.enroll.buf")
    nonisolated(unsafe) private var capturedSamples: [Float] = []

    // MARK: - Public

    func startRecording() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.beginCapture() }
                else {
                    self.errorMessage = "Microphone access denied — enable it in Settings"
                    self.phase = .failed
                }
            }
        }
    }

    // MARK: - Private

    private func beginCapture() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
            phase = .failed
            return
        }

        capturedSamples = []
        secondsRecorded = 0
        phase = .recording

        let inputNode = engine.inputNode
        let hwFormat  = inputNode.outputFormat(forBus: 0)

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        else {
            errorMessage = "Unsupported audio format"
            phase = .failed
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let ratio  = 16_000.0 / hwFormat.sampleRate
            let outLen = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outLen > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outLen)
            else { return }

            var convErr: NSError?
            converter.convert(to: out, error: &convErr) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard convErr == nil, let ptr = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))

            self.sampleQueue.async { self.capturedSamples.append(contentsOf: chunk) }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            errorMessage = "Engine failed: \(error.localizedDescription)"
            phase = .failed
            return
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.secondsRecorded = min(self.secondsRecorded + 0.05, self.totalDuration)
            if self.secondsRecorded >= self.totalDuration {
                t.invalidate()
                self.stopAndEnroll()
            }
        }
    }

    private func stopAndEnroll() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        phase = .processing

        let samples = sampleQueue.sync { capturedSamples }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let userId = UserDefaults.standard.string(forKey: "userId") ?? "self"
                try VoiceEnrollmentService.shared.enroll(samples: samples, forContact: userId)
                await MainActor.run { self.phase = .done }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.phase = .failed
                }
            }
        }
    }
}

// MARK: - View

struct SelfVoiceEnrollmentView: View {

    var onComplete: (() -> Void)? = nil

    @StateObject private var vm = EnrollmentViewModel()

    var body: some View {
        VStack(spacing: 36) {

            // Header
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 52))
                    .foregroundColor(.veriBlue)
                Text("Voice Enrollment")
                    .font(.title2).bold()
                Text("Speak naturally for 6 seconds.\nSay your name, count to ten, or read anything aloud.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                    .frame(width: 150, height: 150)

                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: vm.secondsRecorded)

                ringCenter
            }

            // Status label
            statusLabel
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Buttons
            VStack(spacing: 14) {
                if vm.phase == .idle || vm.phase == .failed {
                    Button(action: vm.startRecording) {
                        Label(
                            vm.phase == .failed ? "Try Again" : "Start Recording",
                            systemImage: "mic.fill"
                        )
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Capsule().fill(Color.veriBlue))
                    }
                    .padding(.horizontal, 40)
                }

                if vm.phase == .done {
                    Button(action: { onComplete?() }) {
                        Label("Continue", systemImage: "arrow.right")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Capsule().fill(Color.green))
                    }
                    .padding(.horizontal, 40)
                }
            }

            Spacer()
        }
        .padding(.top, 40)
        .padding()
    }

    // MARK: - Helpers

    private var progressFraction: CGFloat {
        switch vm.phase {
        case .done:      return 1.0
        case .recording: return CGFloat(vm.secondsRecorded / vm.totalDuration)
        default:         return 0
        }
    }

    private var ringColor: Color {
        switch vm.phase {
        case .done:    return .green
        case .failed:  return .red
        default:       return .veriBlue
        }
    }

    @ViewBuilder
    private var ringCenter: some View {
        switch vm.phase {
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: 38))
                .foregroundColor(.veriBlue)
        case .recording:
            VStack(spacing: 2) {
                Text(String(Int(ceil(vm.totalDuration - vm.secondsRecorded))))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundColor(.veriBlue)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        case .processing:
            ProgressView()
                .scaleEffect(1.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch vm.phase {
        case .idle:
            Text("Tap the button and speak until the timer finishes.")
                .foregroundColor(.secondary)
        case .recording:
            Text("Keep speaking…")
                .foregroundColor(.veriBlue)
        case .processing:
            Text("Computing voiceprint…")
                .foregroundColor(.secondary)
        case .done:
            Text("Voiceprint saved! Calls will now verify your voice.")
                .foregroundColor(.green)
        case .failed:
            Text(vm.errorMessage ?? "Enrollment failed — please try again.")
                .foregroundColor(.red)
        }
    }
}
