import Foundation
import AVFoundation
import Accelerate

// MARK: - Audio File Loader

func loadAudioFile(_ path: String) -> [Float] {
    let url: URL
    if path.hasPrefix("/") || path.hasPrefix("~") {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
        print("  ERROR: File not found: \(url.path)")
        return []
    }

    do {
        let audioFile = try AVAudioFile(forReading: url)
        let srcRate = audioFile.fileFormat.sampleRate
        let srcChannels = audioFile.fileFormat.channelCount
        let frameCount = AVAudioFrameCount(audioFile.length)

        // print("  File: \(url.lastPathComponent) (\(srcRate)Hz, \(srcChannels)ch, \(frameCount) frames)")

        // Read in the file's native processing format (Float32, deinterleaved)
        let processingFormat = audioFile.processingFormat
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            print("  ERROR: Could not create read buffer")
            return []
        }
        try audioFile.read(into: readBuffer)

        // Extract channel 0 as mono
        guard let channelData = readBuffer.floatChannelData?[0] else {
            print("  ERROR: No float channel data")
            return []
        }
        var samples = Array(UnsafeBufferPointer(start: channelData, count: Int(readBuffer.frameLength)))

        // Resample to 16kHz if needed
        let targetRate: Double = 16_000
        if abs(srcRate - targetRate) > 1.0 {
            samples = resample(samples, from: srcRate, to: targetRate)
        }

        return samples
    } catch {
        print("  ERROR: Could not read audio file: \(error)")
        return []
    }
}

func resample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
    let ratio = dstRate / srcRate
    let outCount = Int(Double(input.count) * ratio)
    var output = [Float](repeating: 0, count: outCount)

    for i in 0..<outCount {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, input.count - 1)
        let frac = Float(srcIdx - Double(lo))
        output[i] = input[lo] * (1 - frac) + input[hi] * frac
    }
    // print("  Resampled \(input.count) @ \(Int(srcRate))Hz -> \(outCount) @ \(Int(dstRate))Hz")
    return output
}

// MARK: - Enrollment Storage

struct StoredEnrollment: Codable {
    let name: String
    let vector: [Float]
    let createdAt: Date
    let sampleRate: Double
}

func enrollmentsDir() -> URL {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("enrollments")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func saveEnrollment(_ enrollment: StoredEnrollment) {
    let url = enrollmentsDir().appendingPathComponent("\(enrollment.name).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(enrollment) {
        try? data.write(to: url)
        print("  Saved enrollment to: \(url.path)")
    }
}

func loadEnrollment(_ name: String) -> StoredEnrollment? {
    let url = enrollmentsDir().appendingPathComponent("\(name).json")
    guard let data = try? Data(contentsOf: url) else {
        print("  ERROR: No enrollment found for '\(name)' at \(url.path)")
        return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(StoredEnrollment.self, from: data)
}

func listEnrollments() -> [String] {
    let dir = enrollmentsDir()
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
}

// MARK: - Audio Analysis

func analyzeAudio(_ samples: [Float], label: String) {
    guard !samples.isEmpty else {
        print("  [\(label)] Empty audio!")
        return
    }
    var rms: Float = 0
    vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
    rms = sqrt(rms)

    var maxAmp: Float = 0
    vDSP_maxmgv(samples, 1, &maxAmp, vDSP_Length(samples.count))

    let duration = Double(samples.count) / 16000.0
    // print("  [\(label)] \(samples.count) samples (\(String(format: "%.1f", duration))s), RMS: \(String(format: "%.4f", rms)), peak: \(String(format: "%.4f", maxAmp))")
}

// MARK: - Commands

func cmdEnroll(name: String, filePath: String) {
    print("\n=== ENROLL: \(name) from file ===")

    let audio = loadAudioFile(filePath)
    analyzeAudio(audio, label: "loaded")

    guard !audio.isEmpty else {
        print("  ERROR: No audio loaded!")
        return
    }

    let verifier = LocalVoiceVerifier()
    let vector = verifier.extractSignature(from: audio)

    let nonZero = vector.filter { abs($0) > 1e-10 }.count
    print("  Signature: \(vector.count) dims, \(nonZero) non-zero")

    let enrollment = StoredEnrollment(
        name: name,
        vector: vector,
        createdAt: Date(),
        sampleRate: 16000.0
    )
    saveEnrollment(enrollment)
    print("  Enrollment complete for '\(name)'\n")
}

func cmdVerify(name: String, filePath: String) {
    print("\n=== VERIFY against: \(name) ===")

    guard let enrollment = loadEnrollment(name) else { return }

    let audio = loadAudioFile(filePath)
    analyzeAudio(audio, label: "loaded")

    guard !audio.isEmpty else {
        print("  ERROR: No audio loaded!")
        return
    }

    let verifier = LocalVoiceVerifier()
    let sig = VoiceSignature(vector: enrollment.vector, contactId: name, phraseCount: 5)
    let result = verifier.verify(audioData: audio, against: sig)

    printResult(result, againstName: name)
}

func cmdCompare(name1: String, name2: String) {
    print("\n=== COMPARE: \(name1) vs \(name2) ===")

    guard let e1 = loadEnrollment(name1) else { return }
    guard let e2 = loadEnrollment(name2) else { return }

    let verifier = LocalVoiceVerifier()
    let similarity = verifier.calculateSimilarity(between: e1.vector, and: e2.vector)

    print("\n  ┌─────────────────────────────────────────┐")
    print("  │  \(name1) vs \(name2)")
    print("  │  Similarity: \(String(format: "%.1f", similarity * 100))%")
    print("  │  Threshold:  \(String(format: "%.1f", VoiceVerificationThresholds.matchThreshold * 100))%")
    print("  │  Result:     \(similarity > VoiceVerificationThresholds.matchThreshold ? "MATCH" : "NO MATCH")")
    print("  └─────────────────────────────────────────┘")

    // Diagnostic breakdown per feature group
    printFeatureBreakdown(e1.vector, e2.vector)
}

/// Print per-feature-group cosine similarity to diagnose what's matching/mismatching
func printFeatureBreakdown(_ a: [Float], _ b: [Float]) {
    guard a.count == 24, b.count == 24 else { return }

    let groups: [(String, Range<Int>)] = [
        ("Mean CMS (1-24)  [0-23]", 0..<24)
    ]

    print("\n  Feature Group Breakdown (unweighted cosine per group):")
    print("  ─────────────────────────────────────────────────────")

    for (name, range) in groups {
        let sliceA = Array(a[range])
        let sliceB = Array(b[range])

        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        vDSP_dotpr(sliceA, 1, sliceB, 1, &dot, vDSP_Length(sliceA.count))
        vDSP_svesq(sliceA, 1, &magA, vDSP_Length(sliceA.count))
        vDSP_svesq(sliceB, 1, &magB, vDSP_Length(sliceB.count))
        magA = sqrt(magA)
        magB = sqrt(magB)
        let cos = (magA > 1e-10 && magB > 1e-10) ? dot / (magA * magB) : 0

        var diff = [Float](repeating: 0, count: sliceA.count)
        vDSP_vsub(sliceB, 1, sliceA, 1, &diff, 1, vDSP_Length(sliceA.count))
        var l2: Float = 0
        vDSP_svesq(diff, 1, &l2, vDSP_Length(diff.count))
        l2 = sqrt(l2)

        let bar = String(repeating: "█", count: max(0, Int(cos * 20)))
        print("  \(name): \(String(format: "%6.1f", cos * 100))%  L2=\(String(format: "%.4f", l2))  \(bar)")
    }
    print()
}

/// Compare a file directly against an enrollment (without enrolling the file first)
func cmdTestFile(filePath: String, againstName: String) {
    print("\n=== TEST FILE against: \(againstName) ===")

    guard let enrollment = loadEnrollment(againstName) else { return }

    let audio = loadAudioFile(filePath)
    analyzeAudio(audio, label: "test")

    guard !audio.isEmpty else {
        print("  ERROR: No audio loaded!")
        return
    }

    let verifier = LocalVoiceVerifier()
    let sig = VoiceSignature(vector: enrollment.vector, contactId: againstName, phraseCount: 5)
    let result = verifier.verify(audioData: audio, against: sig)

    printResult(result, againstName: againstName)
}

/// Compare two audio files directly without enrolling either
func cmdFileVsFile(file1: String, file2: String) {
    print("\n=== FILE vs FILE ===")

    let audio1 = loadAudioFile(file1)
    let audio2 = loadAudioFile(file2)
    analyzeAudio(audio1, label: "file1")
    analyzeAudio(audio2, label: "file2")

    guard !audio1.isEmpty, !audio2.isEmpty else {
        print("  ERROR: Could not load audio files!")
        return
    }

    let verifier = LocalVoiceVerifier()
    let sig1 = verifier.extractSignature(from: audio1)
    let sig2 = verifier.extractSignature(from: audio2)
    let similarity = verifier.calculateSimilarity(between: sig1, and: sig2)

    print("\n  ┌─────────────────────────────────────────┐")
    print("  │  \(URL(fileURLWithPath: file1).lastPathComponent) vs \(URL(fileURLWithPath: file2).lastPathComponent)")
    print("  │  Similarity: \(String(format: "%.1f", similarity * 100))%")
    print("  │  Threshold:  \(String(format: "%.1f", VoiceVerificationThresholds.matchThreshold * 100))%")
    print("  │  Result:     \(similarity > VoiceVerificationThresholds.matchThreshold ? "MATCH" : "NO MATCH")")
    print("  └─────────────────────────────────────────┘\n")
}

func cmdList() {
    let names = listEnrollments()
    if names.isEmpty {
        print("\n  No enrollments found. Use 'enroll <name> <file>' first.\n")
    } else {
        print("\n  Saved enrollments:")
        for name in names {
            if let e = loadEnrollment(name) {
                let ago = Date().timeIntervalSince(e.createdAt)
                let minsAgo = Int(ago / 60)
                print("    - \(name) (enrolled \(minsAgo)m ago)")
            }
        }
        print()
    }
}

func printResult(_ result: VoiceVerificationResult, againstName: String) {
    let pct = String(format: "%.1f", result.similarity * 100)
    let threshold = String(format: "%.1f", VoiceVerificationThresholds.matchThreshold * 100)
    let ms = String(format: "%.0f", result.processingTimeMs)

    print("\n  ┌─────────────────────────────────────────┐")
    print("  │  Verification against: \(againstName)")
    print("  │  Similarity:  \(pct)%")
    print("  │  Threshold:   \(threshold)%")
    print("  │  Confidence:  \(result.confidence.rawValue)")
    print("  │  Match:       \(result.isMatch ? "YES" : "NO")")
    print("  │  Time:        \(ms)ms")
    print("  └─────────────────────────────────────────┘\n")
}

// MARK: - Batch FSDD Test

/// Concatenate audio from multiple short WAV files into one long sample
func concatenateAudioFiles(_ paths: [String]) -> [Float] {
    var combined: [Float] = []
    for path in paths {
        let samples = loadAudioFile(path)
        if !samples.isEmpty {
            combined.append(contentsOf: samples)
        }
    }
    return combined
}

/// Run batch test on FSDD dataset
func cmdBatch(datasetDir: String) {
    print("\n╔═══════════════════════════════════════════════════════════╗")
    print("║  BATCH SPEAKER VERIFICATION TEST (FSDD Dataset)        ║")
    print("╚═══════════════════════════════════════════════════════════╝\n")

    let speakers = ["george", "jackson", "lucas", "nicolas", "theo", "yweweler"]
    let verifier = LocalVoiceVerifier()
    let fm = FileManager.default
    let dir = (datasetDir as NSString).expandingTildeInPath

    guard fm.fileExists(atPath: dir) else {
        print("  ERROR: Dataset directory not found: \(dir)")
        return
    }

    // Build two groups per speaker: A (digits 0-4) and B (digits 5-9)
    var signaturesA: [String: [Float]] = [:]
    var signaturesB: [String: [Float]] = [:]

    for speaker in speakers {
        // Group A: digits 0-4, instances 0-9
        var filesA: [String] = []
        for digit in 0...4 {
            for inst in 0...9 {
                let path = "\(dir)/\(digit)_\(speaker)_\(inst).wav"
                if fm.fileExists(atPath: path) { filesA.append(path) }
            }
        }

        // Group B: digits 5-9, instances 0-9
        var filesB: [String] = []
        for digit in 5...9 {
            for inst in 0...9 {
                let path = "\(dir)/\(digit)_\(speaker)_\(inst).wav"
                if fm.fileExists(atPath: path) { filesB.append(path) }
            }
        }

        print("  Loading \(speaker): \(filesA.count) files (A) + \(filesB.count) files (B)")

        let audioA = concatenateAudioFiles(filesA)
        let audioB = concatenateAudioFiles(filesB)

        let durA = Double(audioA.count) / 16000.0
        let durB = Double(audioB.count) / 16000.0
        print("    Group A: \(String(format: "%.1f", durA))s, Group B: \(String(format: "%.1f", durB))s")

        if !audioA.isEmpty { signaturesA[speaker] = verifier.extractSignature(from: audioA) }
        if !audioB.isEmpty { signaturesB[speaker] = verifier.extractSignature(from: audioB) }
    }

    // SAME-SPEAKER TEST: compare A vs B for each speaker
    print("\n┌─────────────────────────────────────────────────────────────┐")
    print("│  SAME-SPEAKER (A vs B) — Should be MATCH (>72%)           │")
    print("├───────────────┬──────────┬──────────────────────────────────┤")
    print("│ Speaker       │ Score    │ Result                           │")
    print("├───────────────┼──────────┼──────────────────────────────────┤")

    var sameScores: [Float] = []
    for speaker in speakers {
        guard let a = signaturesA[speaker], let b = signaturesB[speaker] else { continue }
        let sim = verifier.calculateSimilarity(between: a, and: b)
        sameScores.append(sim)
        let isMatch = sim > VoiceVerificationThresholds.matchThreshold
        let result = isMatch ? "✅ MATCH" : "❌ REJECT"
        print("│ \(speaker.padding(toLength: 13, withPad: " ", startingAt: 0)) │ \(String(format: "%5.1f", sim * 100))%   │ \(result.padding(toLength: 32, withPad: " ", startingAt: 0)) │")
        
        if !isMatch {
             print("└─────────────────────────────────────────────────────────────┘")
             print("  >>> DIAGNOSTIC: False Reject (\(speaker)) <<<")
             printFeatureBreakdown(a, b)
             print("┌─────────────────────────────────────────────────────────────┐")
        }
    }
    let avgSame = sameScores.reduce(0, +) / Float(sameScores.count)
    let correctAccepts = sameScores.filter { $0 > VoiceVerificationThresholds.matchThreshold }.count
    print("├───────────────┼──────────┼──────────────────────────────────┤")
    print("│ AVERAGE       │ \(String(format: "%5.1f", avgSame * 100))%   │ \(correctAccepts)/\(sameScores.count) correct accepts                │")
    print("└───────────────┴──────────┴──────────────────────────────────┘")

    // CROSS-SPEAKER TEST: compare A of each speaker vs A of every other
    print("\n┌─────────────────────────────────────────────────────────────┐")
    print("│  CROSS-SPEAKER (A vs A) — Should be NO MATCH (<72%)       │")
    print("├──────────────────────────┬──────────┬───────────────────────┤")
    print("│ Pair                     │ Score    │ Result                │")
    print("├──────────────────────────┼──────────┼───────────────────────┤")

    var crossScores: [Float] = []
    for i in 0..<speakers.count {
        for j in (i+1)..<speakers.count {
            guard let a = signaturesA[speakers[i]], let b = signaturesA[speakers[j]] else { continue }
            let sim = verifier.calculateSimilarity(between: a, and: b)
            crossScores.append(sim)
            let isFalseAccept = sim > VoiceVerificationThresholds.matchThreshold
            let result = isFalseAccept ? "❌ FALSE ACCEPT" : "✅ REJECT"
            let pair = "\(speakers[i]) vs \(speakers[j])"
            print("│ \(pair.padding(toLength: 24, withPad: " ", startingAt: 0)) │ \(String(format: "%5.1f", sim * 100))%   │ \(result.padding(toLength: 21, withPad: " ", startingAt: 0)) │")
            
            if isFalseAccept {
                 print("└─────────────────────────────────────────────────────────────┘")
                 print("  >>> DIAGNOSTIC: False Accept (\(pair)) <<<")
                 printFeatureBreakdown(a, b)
                 print("┌─────────────────────────────────────────────────────────────┐")
            }
        }
    }
    let avgCross = crossScores.reduce(0, +) / Float(crossScores.count)
    let correctRejects = crossScores.filter { $0 <= VoiceVerificationThresholds.matchThreshold }.count
    print("├──────────────────────────┼──────────┼───────────────────────┤")
    print("│ AVERAGE                  │ \(String(format: "%5.1f", avgCross * 100))%   │ \(correctRejects)/\(crossScores.count) correct rejects    │")
    print("└──────────────────────────┴──────────┴───────────────────────┘")

    // SUMMARY
    let gap = avgSame - avgCross
    print("\n  ═══════════════════════════════════════")
    print("  SUMMARY")
    print("  ═══════════════════════════════════════")
    print("  Same-speaker avg:  \(String(format: "%.1f", avgSame * 100))%")
    print("  Cross-speaker avg: \(String(format: "%.1f", avgCross * 100))%")
    print("  Gap:               \(String(format: "%.1f", gap * 100)) percentage points")
    print("  Threshold:         \(String(format: "%.1f", VoiceVerificationThresholds.matchThreshold * 100))%")
    print("  Correct accepts:   \(correctAccepts)/\(sameScores.count)")
    print("  Correct rejects:   \(correctRejects)/\(crossScores.count)")
    let totalTests = sameScores.count + crossScores.count
    let totalCorrect = correctAccepts + correctRejects
    print("  Overall accuracy:  \(totalCorrect)/\(totalTests) (\(String(format: "%.1f", Float(totalCorrect) / Float(totalTests) * 100))%)")
    print("")
}

func printUsage() {
    print("""

    VoiceTest - Voice Verification Test Harness

    Usage:
      VoiceTest enroll <name> <audio_file>    Extract signature from file and save
      VoiceTest verify <name> <audio_file>    Verify audio file against enrollment
      VoiceTest compare <name1> <name2>       Compare two saved enrollments
      VoiceTest test <audio_file> <name>      Test a file against an enrollment
      VoiceTest filevs <file1> <file2>        Compare two audio files directly
      VoiceTest batch <dataset_dir>           Run batch test on FSDD dataset
      VoiceTest list                          List saved enrollments

    Audio files: WAV, M4A, CAF, MP3, AIFF (any format macOS can read)
    Files are auto-converted to 16kHz mono for processing.

    Examples:
      VoiceTest enroll reece ~/Desktop/reece_voice.m4a
      VoiceTest enroll other ~/Desktop/other_voice.m4a
      VoiceTest verify reece ~/Desktop/reece_test.m4a
      VoiceTest compare reece other
      VoiceTest filevs ~/Desktop/reece1.m4a ~/Desktop/reece2.m4a
      VoiceTest batch dataset/recordings

    Workflow:
      1. Record voice memos on your iPhone (5-10 seconds of speech)
      2. AirDrop them to your Mac
      3. Use 'enroll' to create voice profiles
      4. Use 'verify', 'compare', or 'filevs' to test matching

    """)
}

// MARK: - Main

// Change to package directory so enrollments are saved there
let packageDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // VoiceTest/
    .deletingLastPathComponent()  // Sources/
    .deletingLastPathComponent()  // voice-test/
FileManager.default.changeCurrentDirectoryPath(packageDir.path)

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(0)
}

let command = args[1].lowercased()

switch command {
case "enroll":
    guard args.count >= 4 else {
        print("  Usage: VoiceTest enroll <name> <audio_file>")
        exit(1)
    }
    cmdEnroll(name: args[2], filePath: args[3])

case "verify":
    guard args.count >= 4 else {
        print("  Usage: VoiceTest verify <name> <audio_file>")
        exit(1)
    }
    cmdVerify(name: args[2], filePath: args[3])

case "compare":
    guard args.count >= 4 else {
        print("  Usage: VoiceTest compare <name1> <name2>")
        exit(1)
    }
    cmdCompare(name1: args[2], name2: args[3])

case "test":
    guard args.count >= 4 else {
        print("  Usage: VoiceTest test <audio_file> <name>")
        exit(1)
    }
    cmdTestFile(filePath: args[2], againstName: args[3])

case "filevs":
    guard args.count >= 4 else {
        print("  Usage: VoiceTest filevs <file1> <file2>")
        exit(1)
    }
    cmdFileVsFile(file1: args[2], file2: args[3])

case "batch":
    let dir = args.count >= 3 ? args[2] : "dataset/recordings"
    cmdBatch(datasetDir: dir)

case "list":
    cmdList()

default:
    printUsage()
}
