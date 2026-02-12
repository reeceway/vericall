import Foundation
import AVFoundation

/// Decodes compressed Opus audio packets into PCM buffers using AVAudioConverter.
class OpusDecoder {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    
    init?(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        
        // Opus is 48kHz by design in most low-latency RTP profiles.
        // We define the input format as Opus mono.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960, // Standard 20ms frame at 48kHz
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            print("[OpusDecoder] Failed to create native Opus format")
            return nil
        }
        self.inputFormat = format
        
        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("[OpusDecoder] Failed to initialize AVAudioConverter for Opus -> PCM")
            return nil
        }
        self.converter = conv
    }
    
    /// Decodes a compressed Opus packet into a PCM buffer.
    func decode(packet: Data) -> AVAudioPCMBuffer? {
        let inputBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        
        packet.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(inputBuffer.data, src, packet.count)
        }
        
        inputBuffer.packetCount = 1
        inputBuffer.packetDescriptions![0].mDataByteSize = UInt32(packet.count)
        inputBuffer.packetDescriptions![0].mStartOffset = 0
        inputBuffer.packetDescriptions![0].mVariableFramesInPacket = 0 // Let the decoder handle it
        
        // Output capacity: typically 20-60ms. 
        // At 16kHz, 960 frames (60ms) is a safe capacity for most Opus frames.
        let outputFrameCapacity = UInt32(outputFormat.sampleRate * 0.1) // 100ms capacity
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { packetCount, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if status == .error || error != nil {
            // Some packets might be signaling or headers, ignore errors for now
            return nil
        }
        
        return outputBuffer
    }
}
