//
//  AudioRecorder.swift
//  VeriCall
//
//  Audio recording service for voice enrollment and verification
//

import Foundation
import AVFoundation
import Combine

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: Double = 0.0
    @Published var audioLevel: Float = 0.0
    @Published var showPermissionAlert = false
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var startTime: Date?
    
    private var currentRecordingURL: URL?
    
    // Audio settings for high quality voice recording
    private let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    
    override init() {
        super.init()
    }
    
    // MARK: - Permissions
    
    /// Requests microphone permission
    func requestPermission(completion: @escaping (Bool) -> Void) {
        let status = AVAudioSession.sharedInstance().recordPermission
        
        switch status {
        case .granted:
            completion(true)
        case .denied:
            showPermissionAlert = true
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.showPermissionAlert = true
                    }
                    completion(granted)
                }
            }
        @unknown default:
            showPermissionAlert = true
            completion(false)
        }
    }
    
    /// Checks if microphone permission is granted
    var hasPermission: Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }
    
    // MARK: - Recording
    
    /// Starts recording audio
    func startRecording() {
        guard hasPermission else {
            showPermissionAlert = true
            return
        }
        
        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
            return
        }
        
        // Create recording URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("voice_sample_\(UUID().uuidString).m4a")
        currentRecordingURL = audioFilename
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: audioSettings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            isRecording = true
            startTime = Date()
            recordingDuration = 0.0
            
            // Start timers
            startTimers()
            
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    /// Stops recording and returns the file URL
    func stopRecording(completion: ((URL?) -> Void)? = nil) {
        guard isRecording else {
            completion?(nil)
            return
        }
        
        audioRecorder?.stop()
        stopTimers()
        
        isRecording = false
        recordingDuration = 0.0
        audioLevel = 0.0
        
        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
        
        completion?(currentRecordingURL)
        currentRecordingURL = nil
    }
    
    /// Cancels the current recording without saving
    func cancelRecording() {
        guard isRecording else { return }
        
        audioRecorder?.stop()
        audioRecorder?.deleteRecording()
        stopTimers()
        
        isRecording = false
        recordingDuration = 0.0
        audioLevel = 0.0
        currentRecordingURL = nil
        
        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func startTimers() {
        // Duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let startTime = self.startTime {
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
        
        // Audio level timer
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.audioRecorder?.updateMeters()
            
            // Convert dB to linear scale (0.0 to 1.0)
            let db = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
            let linear = pow(10, db / 20)
            self.audioLevel = Float(min(max(linear, 0), 1))
        }
    }
    
    private func stopTimers() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        levelTimer?.invalidate()
        levelTimer = nil
    }
    
    // MARK: - Utility Methods
    
    /// Deletes all recorded voice samples
    func deleteAllRecordings() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
            let voiceFiles = files.filter { $0.lastPathComponent.hasPrefix("voice_sample_") }
            
            for file in voiceFiles {
                try FileManager.default.removeItem(at: file)
            }
            
            print("🗑️ Deleted \(voiceFiles.count) voice recordings")
        } catch {
            print("Failed to delete recordings: \(error.localizedDescription)")
        }
    }
    
    /// Returns the duration of an audio file
    func getAudioDuration(url: URL) -> Double {
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            return audioPlayer.duration
        } catch {
            return 0.0
        }
    }
    
    /// Returns the file size in bytes
    func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
            isRecording = false
            stopTimers()
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error.localizedDescription)")
        }
        isRecording = false
        stopTimers()
    }
}
