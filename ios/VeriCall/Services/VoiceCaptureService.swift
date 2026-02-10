import Foundation
import AVFoundation
import Combine

class VoiceCaptureService: NSObject, ObservableObject {
    static let shared = VoiceCaptureService()
    
    @Published var isRecording = false
    @Published var currentAudioLevel: Float = 0.0
    
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var timer: Timer?
    
    var audioBufferHandler: ((Data) -> Void)?
    
    private let sampleRate: Double = 16000
    private let chunkDuration: TimeInterval = 3.0 // Send audio every 3 seconds
    
    // MARK: - Setup
    
    func requestPermissions() async -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            print("Audio session setup error: \(error)")
            return false
        }
        
        let status = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        
        return status
    }
    
    // MARK: - Recording
    
    func startRecording() {
        guard !isRecording else { return }
        
        // Use AVAudioEngine for real-time audio capture
        let engine = AVAudioEngine()
        audioEngine = engine
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Configure format for voice analysis (16kHz, mono)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("Failed to create audio format")
            return
        }
        
        var audioBuffer = Data()
        let bytesPerChunk = Int(sampleRate * chunkDuration * 4) // 4 bytes per float32
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // Convert buffer to Data
            let channelData = buffer.floatChannelData![0]
            let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: 1).map { channelData[$0] }
            
            // Calculate audio level for UI
            let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
            let db = 20 * log10(rms)
            
            DispatchQueue.main.async {
                self.currentAudioLevel = self.normalizeAudioLevel(db)
            }
            
            // Append to buffer
            let data = Data(bytes: channelData, count: Int(buffer.frameLength) * 4)
            audioBuffer.append(data)
            
            // Send chunk when ready
            if audioBuffer.count >= bytesPerChunk {
                let chunk = audioBuffer.prefix(bytesPerChunk)
                self.audioBufferHandler?(Data(chunk))
                audioBuffer.removeFirst(bytesPerChunk)
            }
        }
        
        do {
            try engine.start()
            isRecording = true
            
            // Start timer for periodic processing
            timer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { _ in
                // Ensure any remaining buffer is sent
                if !audioBuffer.isEmpty {
                    self.audioBufferHandler?(audioBuffer)
                    audioBuffer.removeAll()
                }
            }
            
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    func stopRecording() {
        timer?.invalidate()
        timer = nil
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        
        isRecording = false
        currentAudioLevel = 0.0
    }
    
    // MARK: - Simple Recording (Alternative)
    
    func startSimpleRecording() {
        guard !isRecording else { return }
        
        let audioFilename = getDocumentsDirectory().appendingPathComponent("voice_sample.m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            isRecording = true
            
            // Start metering timer
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.audioRecorder?.updateMeters()
                let db = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160
                DispatchQueue.main.async {
                    self?.currentAudioLevel = self?.normalizeAudioLevel(db) ?? 0
                }
            }
            
        } catch {
            print("Recording error: \(error)")
        }
    }
    
    func stopSimpleRecording() -> Data? {
        timer?.invalidate()
        timer = nil
        
        audioRecorder?.stop()
        isRecording = false
        
        guard let url = audioRecorder?.url else { return nil }
        
        do {
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            return data
        } catch {
            print("Error reading recorded audio: \(error)")
            return nil
        }
    }
    
    // MARK: - Private Helpers
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private func normalizeAudioLevel(_ db: Float) -> Float {
        // Convert dB to 0-1 scale
        let minDb: Float = -60
        let maxDb: Float = 0
        let clampedDb = max(minDb, min(maxDb, db))
        return (clampedDb - minDb) / (maxDb - minDb)
    }
}

// MARK: - AVAudioRecorderDelegate
extension VoiceCaptureService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
        }
    }
}
