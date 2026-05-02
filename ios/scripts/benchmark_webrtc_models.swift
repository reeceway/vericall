#!/usr/bin/env swift

import Foundation
import CoreML
import AVFoundation
import Accelerate

struct AudioConfiguration {
    static let analysisWindowSamples = 48_000
    static let speakerThreshold: Float = 0.90
    static let spoofThreshold: Float = 0.665
}

struct CSVRow {
    let values: [String: String]
    subscript(_ key: String) -> String { values[key, default: ""] }
}

struct SpeakerExample {
    let speakerID: String
    let audioPath: String
}

struct SpeakerPairResult {
    let similarity: Float
    let predictedMatch: Bool
    let expectedMatch: Bool
}

struct SpoofExample {
    let label: String
    let audioPath: String
    let speakerID: String
}

struct SpoofResultRow {
    let cloneProbability: Float
    let predictedHuman: Bool
    let expectedHuman: Bool
}

enum BenchError: Error {
    case missingFeature(String)
    case invalidModelOutput(String)
}

final class LocalAudioLoader {
    func loadMono16kWindow(path: String, targetSamples: Int = AudioConfiguration.analysisWindowSamples) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "Bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create source buffer"])
        }
        try file.read(into: sourceBuffer)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        let mono16kBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            mono16kBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw NSError(domain: "Bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioConverter"])
            }
            let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 8
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw NSError(domain: "Bench", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
            }
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            var error: NSError?
            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            mono16kBuffer = outputBuffer
        }

        let frameLength = Int(mono16kBuffer.frameLength)
        let channelData = mono16kBuffer.floatChannelData![0]
        var samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        if samples.count > targetSamples {
            samples = Array(samples.suffix(targetSamples))
        } else if samples.count < targetSamples {
            samples += Array(repeating: 0, count: targetSamples - samples.count)
        }
        return samples
    }
}

final class LocalSpeakerBench {
    private let model: MLModel
    private let sampleRate: Float = 16_000
    private let frameLength: Int = 400
    private let frameStep: Int = 160
    private let numMelBands: Int = 80
    private let numFrames: Int = 300

    init(modelURL: URL) throws {
        let compiled = try MLModel.compileModel(at: modelURL)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: compiled, configuration: config)
    }

    func embed(samples: [Float]) throws -> [Float] {
        let fbank = try computeFbank(samples: samples)
        let normalized = sentenceMeanSubtract(fbank)
        let input = try MLMultiArray(shape: [1, NSNumber(value: numFrames), NSNumber(value: numMelBands)], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        normalized.withUnsafeBufferPointer { src in
            ptr.initialize(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["fbank_features": MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: provider)
        guard let arr = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw BenchError.missingFeature("embedding")
        }
        let embPtr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: embPtr, count: 192))
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        return max(0, min(1, dot / denom))
    }

    private func computeFbank(samples: [Float]) throws -> [Float] {
        var buf = samples
        if buf.count < AudioConfiguration.analysisWindowSamples {
            buf += Array(repeating: 0, count: AudioConfiguration.analysisWindowSamples - buf.count)
        } else if buf.count > AudioConfiguration.analysisWindowSamples {
            buf = Array(buf.prefix(AudioConfiguration.analysisWindowSamples))
        }

        var emphasized = [Float](repeating: 0, count: AudioConfiguration.analysisWindowSamples)
        emphasized[0] = buf[0]
        let alpha: Float = 0.97
        for i in 1..<AudioConfiguration.analysisWindowSamples {
            emphasized[i] = buf[i] - alpha * buf[i - 1]
        }

        let melFilters = Self.melFilterbank(numFilters: numMelBands, fftSize: frameLength, sampleRate: sampleRate)
        let fftSize = frameLength
        let halfFFT = fftSize / 2 + 1
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "Bench", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create FFT setup"])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var result = [Float](repeating: 0, count: numFrames * numMelBands)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hamm_window(&window, vDSP_Length(fftSize), 0)

        for frame in 0..<numFrames {
            let start = frame * frameStep
            let end = start + fftSize
            guard end <= emphasized.count else { break }
            var realPart = Array(emphasized[start..<end])
            vDSP_vmul(realPart, 1, window, 1, &realPart, 1, vDSP_Length(fftSize))
            var imagPart = [Float](repeating: 0, count: fftSize)
            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            var power = [Float](repeating: 0, count: halfFFT)
            for i in 0..<halfFFT {
                power[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i]
            }
            for m in 0..<numMelBands {
                var energy: Float = 0
                vDSP_dotpr(power, 1, melFilters[m], 1, &energy, vDSP_Length(halfFFT))
                result[frame * numMelBands + m] = log(max(energy, 1e-10))
            }
        }
        return result
    }

    private func sentenceMeanSubtract(_ fbank: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(fbank, 1, &mean, vDSP_Length(fbank.count))
        var out = fbank
        var neg = -mean
        vDSP_vsadd(out, 1, &neg, &out, 1, vDSP_Length(out.count))
        return out
    }

    private static var cachedMel: [[Float]] = []
    private static func melFilterbank(numFilters: Int, fftSize: Int, sampleRate: Float) -> [[Float]] {
        if !cachedMel.isEmpty { return cachedMel }
        let halfFFT = fftSize / 2 + 1
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let melMin = hzToMel(0)
        let melMax = hzToMel(sampleRate / 2)
        let melPoints = (0...(numFilters + 1)).map { i -> Float in
            melToHz(melMin + Float(i) * (melMax - melMin) / Float(numFilters + 1))
        }
        let binPoints = melPoints.map { Int(($0 / sampleRate) * Float(fftSize) + 0.5) }
        var filters = [[Float]](repeating: [Float](repeating: 0, count: halfFFT), count: numFilters)
        for m in 0..<numFilters {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]
            if center > left {
                for k in left..<center where k < halfFFT {
                    filters[m][k] = Float(k - left) / Float(center - left)
                }
            }
            if right > center {
                for k in center..<right where k < halfFFT {
                    filters[m][k] = Float(right - k) / Float(right - center)
                }
            }
        }
        cachedMel = filters
        return filters
    }
}

final class LocalSpoofBench {
    private let model: MLModel

    init(modelURL: URL) throws {
        let compiled = try MLModel.compileModel(at: modelURL)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: compiled, configuration: config)
    }

    func predict(samples: [Float]) throws -> Float {
        let input = try MLMultiArray(shape: [1, NSNumber(value: AudioConfiguration.analysisWindowSamples)], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<AudioConfiguration.analysisWindowSamples {
            ptr[i] = i < samples.count ? samples[i] : 0
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: provider)
        if let arr = out.featureValue(for: "clone_probability")?.multiArrayValue {
            return max(0, min(1, arr[0].floatValue))
        }
        if let val = out.featureValue(for: "clone_probability")?.doubleValue {
            return max(0, min(1, Float(val)))
        }
        throw BenchError.invalidModelOutput("clone_probability")
    }
}

func readCSVRows(at path: String) throws -> [CSVRow] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard let headerLine = lines.first else { return [] }
    let headers = headerLine.split(separator: ",").map(String.init)
    var rows: [CSVRow] = []
    for line in lines.dropFirst() {
        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard cols.count == headers.count else { continue }
        rows.append(CSVRow(values: Dictionary(uniqueKeysWithValues: zip(headers, cols))))
    }
    return rows
}

func runSpeakerBenchmark(manifestPath: String, modelPath: String, maxSpeakers: Int) throws {
    let rows = try readCSVRows(at: manifestPath)
    let filtered = rows.filter { $0["label"] == "real" && ($0["split"] == "val" || $0["split"] == "test") }
    var bySpeaker: [String: [SpeakerExample]] = [:]
    for row in filtered {
        bySpeaker[row["speaker_id"], default: []].append(SpeakerExample(speakerID: row["speaker_id"], audioPath: row["audio_path"]))
    }
    let speakers = bySpeaker.keys.sorted().filter { (bySpeaker[$0]?.count ?? 0) >= 2 }
    let selected = Array(speakers.prefix(maxSpeakers))
    let loader = LocalAudioLoader()
    let bench = try LocalSpeakerBench(modelURL: URL(fileURLWithPath: modelPath))

    var embeddings: [String: [Float]] = [:]
    var positives: [SpeakerPairResult] = []
    var negatives: [SpeakerPairResult] = []

    for speaker in selected {
        guard let examples = bySpeaker[speaker], examples.count >= 2 else { continue }
        let enroll = try loader.loadMono16kWindow(path: examples[0].audioPath)
        let probe = try loader.loadMono16kWindow(path: examples[1].audioPath)
        let enrollEmb = try bench.embed(samples: enroll)
        embeddings[speaker] = enrollEmb
        let probeEmb = try bench.embed(samples: probe)
        let sim = bench.cosineSimilarity(enrollEmb, probeEmb)
        positives.append(SpeakerPairResult(similarity: sim, predictedMatch: sim >= AudioConfiguration.speakerThreshold, expectedMatch: true))
    }

    for i in 0..<selected.count {
        let s1 = selected[i]
        let s2 = selected[(i + 1) % selected.count]
        guard s1 != s2,
              let enrollEmb = embeddings[s1],
              let examples = bySpeaker[s2], let probePath = examples.first?.audioPath else { continue }
        let probe = try loader.loadMono16kWindow(path: probePath)
        let probeEmb = try bench.embed(samples: probe)
        let sim = bench.cosineSimilarity(enrollEmb, probeEmb)
        negatives.append(SpeakerPairResult(similarity: sim, predictedMatch: sim >= AudioConfiguration.speakerThreshold, expectedMatch: false))
    }

    let all = positives + negatives
    let correct = all.filter { $0.predictedMatch == $0.expectedMatch }.count
    let posMean = positives.map(\.similarity).reduce(0, +) / Float(max(1, positives.count))
    let negMean = negatives.map(\.similarity).reduce(0, +) / Float(max(1, negatives.count))
    print("SPEAKER_BENCH")
    print("selected_speakers=\(selected.count)")
    print("positive_pairs=\(positives.count)")
    print("negative_pairs=\(negatives.count)")
    print(String(format: "speaker_accuracy=%.4f", Double(correct) / Double(max(1, all.count))))
    print(String(format: "positive_mean_similarity=%.4f", posMean))
    print(String(format: "negative_mean_similarity=%.4f", negMean))
    if let firstBad = all.first(where: { $0.predictedMatch != $0.expectedMatch }) {
        print(String(format: "speaker_first_error_similarity=%.4f predicted=%@ expected=%@", firstBad.similarity, String(firstBad.predictedMatch), String(firstBad.expectedMatch)))
    }
}

func runSpoofBenchmark(manifestPath: String, modelPath: String, maxPerClass: Int) throws {
    let rows = try readCSVRows(at: manifestPath)
    let filtered = rows.filter { $0["split"] == "val" || $0["split"] == "test" }
    let realRows = Array(filtered.filter { $0["label"] == "real" }.prefix(maxPerClass))
    let fakeRows = Array(filtered.filter { $0["label"] == "fake" }.prefix(maxPerClass))
    let loader = LocalAudioLoader()
    let bench = try LocalSpoofBench(modelURL: URL(fileURLWithPath: modelPath))
    var results: [SpoofResultRow] = []
    var realScores: [Float] = []
    var fakeScores: [Float] = []

    for row in realRows + fakeRows {
        let samples = try loader.loadMono16kWindow(path: row["audio_path"])
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        let gain = min(10.0 as Float, 0.03 / max(rms, 1e-6))
        let prepared = samples.map { max(-1, min(1, $0 * gain)) }
        let p = try bench.predict(samples: prepared)
        let expectedHuman = row["label"] == "real"
        let predictedHuman = p < AudioConfiguration.spoofThreshold
        results.append(SpoofResultRow(cloneProbability: p, predictedHuman: predictedHuman, expectedHuman: expectedHuman))
        if expectedHuman { realScores.append(p) } else { fakeScores.append(p) }
    }

    let correct = results.filter { $0.predictedHuman == $0.expectedHuman }.count
    let realMean = realScores.reduce(0, +) / Float(max(1, realScores.count))
    let fakeMean = fakeScores.reduce(0, +) / Float(max(1, fakeScores.count))
    print("SPOOF_BENCH")
    print("real_rows=\(realRows.count)")
    print("fake_rows=\(fakeRows.count)")
    print(String(format: "spoof_accuracy=%.4f", Double(correct) / Double(max(1, results.count))))
    print(String(format: "real_mean_clone_probability=%.4f", realMean))
    print(String(format: "fake_mean_clone_probability=%.4f", fakeMean))
    if let firstBad = results.first(where: { $0.predictedHuman != $0.expectedHuman }) {
        print(String(format: "spoof_first_error_clone_probability=%.4f predictedHuman=%@ expectedHuman=%@", firstBad.cloneProbability, String(firstBad.predictedHuman), String(firstBad.expectedHuman)))
    }
}

let speakerManifest = "/Users/reeceway/Desktop/vericall voiceprints/commercial_safe_cleanroom/data/manifests/institutional_release_20260309_spoof/layer3_sv_manifest.csv"
let spoofManifest = "/Users/reeceway/Desktop/vericall voiceprints/commercial_safe_cleanroom/data/manifests/institutional_release_20260309_spoof/layer2_spoof_manifest.csv"
let speakerModel = "/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/VoiceEmbedder.mlpackage"
let spoofModel = "/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/VeriCallSpoofDetector.mlpackage"

let speakerCount = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 20) : 20
let spoofPerClass = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 50) : 50

do {
    print("starting speaker benchmark speakers=\(speakerCount)")
    fflush(stdout)
    try runSpeakerBenchmark(manifestPath: speakerManifest, modelPath: speakerModel, maxSpeakers: speakerCount)
    print("starting spoof benchmark per_class=\(spoofPerClass)")
    fflush(stdout)
    try runSpoofBenchmark(manifestPath: spoofManifest, modelPath: spoofModel, maxPerClass: spoofPerClass)
} catch {
    fputs("benchmark failed: \(error)\n", stderr)
    exit(1)
}
