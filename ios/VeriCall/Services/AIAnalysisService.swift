import Foundation
import Accelerate
import Combine
import AVFoundation
import UIKit

/// Runs on-device spoof analysis against the live call's Twilio media mirror.
///
/// Audio source: active call transport remote/local audio buffers (16kHz float32, rolling 10s)
/// Model:
///   1. VeriCallClassicSpoof (LFCC + XGBoost) — spoof/clone detection
///
/// Speaker-analysis support is left in place for bench/debug paths, but the
/// live product loop only drives the classic spoof model.
@MainActor
final class AIAnalysisService: ObservableObject {

    static let shared = AIAnalysisService()
    static let debugCaptureEnabledKey = "vericall.debugCaptureEnabled"

    // MARK: - Published State

    @Published private(set) var latestSpoof: SpoofResult?
    @Published private(set) var latestSpeaker: SpeakerResult?
    @Published private(set) var latestLocalSpoof: SpoofResult?
    @Published private(set) var latestLocalSpeaker: SpeakerResult?
    @Published private(set) var isRunning = false

    // MARK: - Configuration

    private nonisolated let performanceProfile = AppPerformanceProfile.shared
    private nonisolated let spoofWindowSamples = AudioConfiguration.analysisWindowSamples  // 48000 (3s)
    private nonisolated let speakerWindowSamples = AudioConfiguration.analysisWindowSamples  // 48000 (3s)
    private nonisolated let liveDecisionInterval = AudioConfiguration.liveSpoofDecisionIntervalSeconds
    private nonisolated let liveDecisionChunkSamples = AudioConfiguration.liveSpoofDecisionChunkSamples
    private nonisolated let liveDecisionStrideSamples = AudioConfiguration.liveSpoofDecisionStrideSamples
    private nonisolated let speechRMSFloor: Float = AudioConfiguration.spoofAudibleRMSCall
    private nonisolated let speechFrameSamples = 1_600  // 100ms at 16 kHz
    private nonisolated let minimumSpeechActivityRatio: Float = 0.06
    private nonisolated let minimumDecisionSpeechActivityRatio: Float = AudioConfiguration.spoofDecisionSpeechActivityCall
    private nonisolated let minSpeakerRMS: Float = 0.006

    // MARK: - Internals

    private var timer: Timer?
    private let analysisQueue = DispatchQueue(label: "com.vericall.ai", qos: .userInitiated)
    private(set) var diagnostics: String = "idle"
    private var isAnalyzing = false
    private var hasWarmedModels = false
    private var modelWarmupWorkItem: DispatchWorkItem?
    private var lastImmediateAnalysisAt: Date?
    private var liveDecisionStartedAt: Date?
    private var lastLiveDecisionAt: Date?

    private init() {}

    // MARK: - Public API

    static var captureRootPath: String {
        ModelCaptureExportService.shared.rootURL.path
    }

    struct DebugWindowAnalysis {
        let remoteSpoof: SpoofResult?
        let remoteSpeaker: SpeakerResult?
        let localSpoof: SpoofResult?
        let localSpeaker: SpeakerResult?
        let diagnostics: String
    }

    func setDebugCaptureEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.debugCaptureEnabledKey)
        print("[AIAnalysis] debug capture \(enabled ? "enabled" : "disabled")")
    }

    var isDebugCaptureEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugCaptureEnabledKey)
    }

    func warmUpModels() {
        scheduleModelWarmup(delay: performanceProfile.modelWarmupDelay, reason: "background", replaceExisting: false)
    }

    func prepareForFirstCall() {
        scheduleModelWarmup(delay: performanceProfile.firstCallModelWarmupDelay, reason: "first-call", replaceExisting: true)
    }

    func prepareForCallKitAnswer() {
        scheduleModelWarmup(delay: 0, reason: "callkit-answer", replaceExisting: true)
    }

    private func scheduleModelWarmup(delay: TimeInterval, reason: String, replaceExisting: Bool) {
        guard !hasWarmedModels else { return }
        if modelWarmupWorkItem != nil {
            guard replaceExisting else { return }
            modelWarmupWorkItem?.cancel()
        }

        var pendingWorkItem: DispatchWorkItem?
        let workItem = DispatchWorkItem { [weak self] in
            guard pendingWorkItem?.isCancelled == false else { return }
            let silence = [Float](repeating: 0, count: AudioConfiguration.analysisWindowSamples)
            _ = ClassicSpoofDetector.shared.isLoaded
            _ = ClassicSpoofDetector.shared.predict(samples: silence)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasWarmedModels = true
                self.modelWarmupWorkItem = nil
                if !self.isRunning {
                    self.diagnostics = "warm"
                }
            }
            AppPerformanceProfile.shared.logAI("[AIAnalysis] Warmed classic spoof model reason=\(reason)")
        }
        pendingWorkItem = workItem
        modelWarmupWorkItem = workItem
        analysisQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Start analysis for both remote and local streams.
    func start(remoteEnrolledEmbedding: [Float]?, localEnrolledEmbedding: [Float]?) {
        guard !isRunning else { return }
        isRunning = true
        diagnostics = "starting"
        latestSpoof = nil
        latestSpeaker = nil
        latestLocalSpoof = nil
        latestLocalSpeaker = nil
        lastImmediateAnalysisAt = nil
        liveDecisionStartedAt = Date()
        lastLiveDecisionAt = nil

        diagnostics = "collecting audio"

        // Product loop: emit one direct model decision every 10s from the
        // strongest available speech-bearing 3s slice.
        DispatchQueue.main.asyncAfter(deadline: .now() + liveDecisionInterval) { [weak self] in
            guard let self, self.isRunning else { return }
            self.runCycle()
            self.timer = Timer.scheduledTimer(
                withTimeInterval: self.liveDecisionInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.runCycle() }
            }
        }

        performanceProfile.logAI("[AIAnalysis] Started \(performanceProfile.summary) live-decision-interval=\(liveDecisionInterval)s remote-enrolled=\(remoteEnrolledEmbedding != nil ? "yes" : "no") local-enrolled=\(localEnrolledEmbedding != nil ? "yes" : "no")")
    }

    func requestImmediateAnalysis() {
        guard isRunning else { return }
        let now = Date()
        if let liveDecisionStartedAt,
           lastLiveDecisionAt == nil,
           now.timeIntervalSince(liveDecisionStartedAt) < liveDecisionInterval {
            return
        }
        if let lastLiveDecisionAt,
           now.timeIntervalSince(lastLiveDecisionAt) < liveDecisionInterval {
            return
        }
        if let lastImmediateAnalysisAt,
           now.timeIntervalSince(lastImmediateAnalysisAt) < performanceProfile.immediateAnalysisMinimumInterval {
            return
        }
        lastImmediateAnalysisAt = now
        runCycle()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isAnalyzing = false
        lastImmediateAnalysisAt = nil
        liveDecisionStartedAt = nil
        lastLiveDecisionAt = nil
        diagnostics = "stopped"
        performanceProfile.logAI("[AIAnalysis] Stopped")
    }

    /// Run the same per-window model logic used by live call analysis, but against
    /// pre-recorded local arrays so we can benchmark the call path without placing calls.
    func analyzeBenchmarkWindow(
        remoteSamples: [Float]?,
        localSamples: [Float]? = nil,
        remoteEnrolledEmbedding: [Float]? = nil,
        localEnrolledEmbedding: [Float]? = nil
    ) -> DebugWindowAnalysis {
        let remoteSpoofChunk = remoteSamples.flatMap { $0.count >= spoofWindowSamples ? Array($0.suffix(spoofWindowSamples)) : nil }
        let localSpoofChunk = localSamples.flatMap { $0.count >= spoofWindowSamples ? Array($0.suffix(spoofWindowSamples)) : nil }
        let remoteSpeakerChunk = remoteSamples.flatMap { $0.count >= speakerWindowSamples ? Array($0.suffix(speakerWindowSamples)) : nil }
        let localSpeakerChunk = localSamples.flatMap { $0.count >= speakerWindowSamples ? Array($0.suffix(speakerWindowSamples)) : nil }

        let remote = analyzeSingleWindow(
            spoofChunk: remoteSpoofChunk,
            speakerChunk: remoteSpeakerChunk,
            enrolledEmbedding: remoteEnrolledEmbedding,
            streamLabel: "remote"
        )
        let local = analyzeSingleWindow(
            spoofChunk: localSpoofChunk,
            speakerChunk: localSpeakerChunk,
            enrolledEmbedding: localEnrolledEmbedding,
            streamLabel: "local"
        )

        let remoteSpoofText = remote.spoof.map {
            String(
                format: "rSpoof=%.3f(v=%@,w=%d,c=%@)",
                $0.cloneProbability,
                $0.verdict.rawValue,
                $0.supportingWindows,
                $0.confidence == .high ? "H" : "L"
            )
        } ?? "rSpoof=nil"
        let remoteSpeakerText = remote.speaker.map { String(format: "rSpk=%.3f(th=%.2f,m=%@)", $0.similarity, $0.threshold, $0.isMatch ? "Y" : "N") } ?? "rSpk=nil"
        let localSpoofText = local.spoof.map {
            String(
                format: "lSpoof=%.3f(v=%@,w=%d,c=%@)",
                $0.cloneProbability,
                $0.verdict.rawValue,
                $0.supportingWindows,
                $0.confidence == .high ? "H" : "L"
            )
        } ?? "lSpoof=nil"
        let localSpeakerText = local.speaker.map { String(format: "lSpk=%.3f(m=%@)", $0.similarity, $0.isMatch ? "Y" : "N") } ?? "lSpk=nil"
        let summary = "bench \(remoteSpoofText) \(remoteSpeakerText) \(localSpoofText) \(localSpeakerText)"
        return DebugWindowAnalysis(
            remoteSpoof: remote.spoof,
            remoteSpeaker: remote.speaker,
            localSpoof: local.spoof,
            localSpeaker: local.speaker,
            diagnostics: summary
        )
    }

    // MARK: - Analysis Cycle

    private func runCycle() {
        guard !isAnalyzing else {
            diagnostics = "busy"
            return
        }
        isAnalyzing = true

        CallTransportService.shared.refreshBuffers()
        let transport = CallTransportService.shared
        let remoteBufferQueue = transport.remoteBufferQueue
        let localBufferQueue = transport.localBufferQueue
        let debugCaptureEnabled = isDebugCaptureEnabled

        analysisQueue.async { [weak self] in
            guard let self else { return }
            // Thread-safe snapshots of remote/local audio buffers off the main thread
            let remoteSamples: [Float] = remoteBufferQueue.sync {
                transport.remoteAudioBuffer
            }
            let localSamples: [Float] = localBufferQueue.sync {
                transport.localAudioBuffer
            }

            guard remoteSamples.count >= self.spoofWindowSamples || localSamples.count >= self.spoofWindowSamples else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.diagnostics = "waiting-audio remote=\(remoteSamples.count) local=\(localSamples.count)"
                    self.isAnalyzing = false
                }
                self.performanceProfile.logAI("[AIAnalysis] Waiting for trained 3s audio window (remote \(remoteSamples.count)/\(self.spoofWindowSamples), local \(localSamples.count)/\(self.spoofWindowSamples)); cadence remains \(self.liveDecisionInterval)s")
                return
            }

            // Keep the spoof model on the same 3s context it was calibrated on,
            // but choose that context once per cadence from up to the last 10s
            // instead of averaging many overlapping model outputs.
            let remoteDecisionWindow = remoteSamples.count >= self.spoofWindowSamples
                ? self.bestSpeechSpoofWindow(from: remoteSamples)
                : nil
            let localDecisionWindow = localSamples.count >= self.spoofWindowSamples
                ? self.bestSpeechSpoofWindow(from: localSamples)
                : nil
            let remoteSpoofChunk = remoteDecisionWindow?.samples
            let localSpoofChunk = localDecisionWindow?.samples
            let remoteSpeakerChunk: [Float]? = nil
            let localSpeakerChunk: [Float]? = nil

            var remoteSpoof: SpoofResult?
            let remoteSpeaker: SpeakerResult? = nil
            var localSpoof: SpoofResult?
            let localSpeaker: SpeakerResult? = nil
            var remoteSpoofRms: Float?
            var localSpoofRms: Float?
            var remoteClassicProb: Float?
            var localClassicProb: Float?

            if let chunk = remoteSpoofChunk {
                let remoteSpeech = remoteDecisionWindow.map {
                    (rms: $0.rms, activityRatio: $0.activityRatio, hasSpeech: $0.hasSpeech)
                } ?? speechMetrics(chunk)
                let remoteRms = remoteSpeech.rms
                remoteSpoofRms = remoteRms
                if !remoteSpeech.hasSpeech {
                    self.performanceProfile.logAI(
                        String(
                            format: "[AIAnalysis] remote rms=%.5f speech=no activity=%.2f",
                            remoteRms,
                            remoteSpeech.activityRatio
                        )
                    )
                } else {
                    remoteClassicProb = ClassicSpoofDetector.shared.predict(samples: chunk)
                }
                if let classicProb = remoteClassicProb {
                    let remoteSpoofMs = 0.0
                    let enoughSpeechForDecision = remoteSpeech.activityRatio >= self.minimumDecisionSpeechActivityRatio
                    let confidence: AnalysisConfidence = enoughSpeechForDecision ? .high : .low
                    let supportingWindows = enoughSpeechForDecision
                        ? AudioConfiguration.spoofWarmupWindowsCall
                        : 1
                    remoteSpoof = SpoofResult(
                        cloneProbability: classicProb,
                        confidence: confidence,
                        threshold: AudioConfiguration.spoofHumanThresholdCall,
                        supportingWindows: supportingWindows,
                        processingTimeMs: remoteSpoofMs,
                        rms: remoteRms,
                        speechActivityRatio: remoteSpeech.activityRatio
                    )
                    self.performanceProfile.logAI(
                        String(
                            format: "[AIAnalysis] remote 10s-decision rms=%.5f speech=yes activity=%.2f decision=%@ classic=%.3f conf=%@ th=%.2f",
                            remoteRms,
                            remoteSpeech.activityRatio,
                            enoughSpeechForDecision ? "yes" : "no",
                            classicProb,
                            confidence.rawValue,
                            AudioConfiguration.spoofHumanThresholdCall
                        )
                    )
                } else {
                    self.performanceProfile.logAI(String(format: "[AIAnalysis] remote rms=%.5f classic=nil", remoteRms))
                }
            }

            if let chunk = localSpoofChunk {
                let localSpeech = localDecisionWindow.map {
                    (rms: $0.rms, activityRatio: $0.activityRatio, hasSpeech: $0.hasSpeech)
                } ?? speechMetrics(chunk)
                let localRms = localSpeech.rms
                localSpoofRms = localRms
                if !localSpeech.hasSpeech {
                    self.performanceProfile.logAI(
                        String(
                            format: "[AIAnalysis] local  rms=%.5f speech=no activity=%.2f",
                            localRms,
                            localSpeech.activityRatio
                        )
                    )
                } else {
                    localClassicProb = ClassicSpoofDetector.shared.predict(samples: chunk)
                }
                if let classicProb = localClassicProb {
                    let localSpoofMs = 0.0
                    let enoughSpeechForDecision = localSpeech.activityRatio >= self.minimumDecisionSpeechActivityRatio
                    let confidence: AnalysisConfidence = enoughSpeechForDecision ? .high : .low
                    let supportingWindows = enoughSpeechForDecision
                        ? AudioConfiguration.spoofWarmupWindowsCall
                        : 1
                    localSpoof = SpoofResult(
                        cloneProbability: classicProb,
                        confidence: confidence,
                        threshold: AudioConfiguration.spoofHumanThresholdCall,
                        supportingWindows: supportingWindows,
                        processingTimeMs: localSpoofMs,
                        rms: localRms,
                        speechActivityRatio: localSpeech.activityRatio
                    )
                    self.performanceProfile.logAI(
                        String(
                            format: "[AIAnalysis] local 10s-decision rms=%.5f speech=yes activity=%.2f decision=%@ classic=%.3f conf=%@ th=%.2f",
                            localRms,
                            localSpeech.activityRatio,
                            enoughSpeechForDecision ? "yes" : "no",
                            classicProb,
                            confidence.rawValue,
                            AudioConfiguration.spoofHumanThresholdCall
                        )
                    )
                } else {
                    self.performanceProfile.logAI(String(format: "[AIAnalysis] local  rms=%.5f classic=nil", localRms))
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestSpoof = remoteSpoof
                self.latestSpeaker = nil
                self.latestLocalSpoof = localSpoof
                self.latestLocalSpeaker = nil

                let remoteSpoofText = remoteSpoof.map {
                    String(
                        format: "rSpoof=%.3f(v=%@,w=%d,c=%@)",
                        $0.cloneProbability,
                        $0.verdict.rawValue,
                        $0.supportingWindows,
                        $0.confidence == .high ? "H" : "L"
                    )
                } ?? "rSpoof=nil"
                let localSpoofText = localSpoof.map {
                    String(
                        format: "lSpoof=%.3f(v=%@,w=%d,c=%@)",
                        $0.cloneProbability,
                        $0.verdict.rawValue,
                        $0.supportingWindows,
                        $0.confidence == .high ? "H" : "L"
                    )
                } ?? "lSpoof=nil"

                let remoteComponents = String(format: "rC=%.3f", remoteClassicProb ?? -1)
                let localComponents = String(format: "lC=%.3f", localClassicProb ?? -1)
                self.diagnostics = "10s \(remoteSpoofText) \(localSpoofText) \(remoteComponents) \(localComponents)"
                self.performanceProfile.logAI("[AIAnalysis] \(self.diagnostics)")
                self.lastLiveDecisionAt = Date()
                self.isAnalyzing = false
            }

            if debugCaptureEnabled {
                if let raw = remoteSpoofChunk ?? remoteSpeakerChunk {
                    ModelCaptureExportService.shared.capture(
                        streamSource: "remote",
                        rawSamples: raw,
                        speakerSamples: remoteSpeakerChunk ?? raw,
                        spoofSamples: raw,
                        spoofGainApplied: 1.0,
                        spoofConfidence: remoteSpoof?.confidence ?? .low,
                        rmsPreGain: remoteSpoofRms ?? rms(raw),
                        speakerResult: remoteSpeaker,
                        spoofResult: remoteSpoof,
                        contactId: UserDefaults.standard.string(forKey: "contactId") ?? UserDefaults.standard.string(forKey: "userId"),
                        route: "remote",
                        callStack: "CallTransport.remote->AIAnalysisService"
                    )
                }
                if let raw = localSpoofChunk ?? localSpeakerChunk {
                    ModelCaptureExportService.shared.capture(
                        streamSource: "local",
                        rawSamples: raw,
                        speakerSamples: localSpeakerChunk ?? raw,
                        spoofSamples: raw,
                        spoofGainApplied: 1.0,
                        spoofConfidence: localSpoof?.confidence ?? .low,
                        rmsPreGain: localSpoofRms ?? rms(raw),
                        speakerResult: localSpeaker,
                        spoofResult: localSpoof,
                        contactId: UserDefaults.standard.string(forKey: "contactId") ?? UserDefaults.standard.string(forKey: "userId"),
                        route: "local",
                        callStack: "CallTransport.local->AIAnalysisService"
                    )
                }
            }
        }
    }

    private nonisolated func bestSpeechSpoofWindow(
        from samples: [Float]
    ) -> (samples: [Float], rms: Float, activityRatio: Float, hasSpeech: Bool)? {
        guard samples.count >= spoofWindowSamples else { return nil }

        let chunk = samples.count > liveDecisionChunkSamples
            ? Array(samples.suffix(liveDecisionChunkSamples))
            : samples
        let maxStart = chunk.count - spoofWindowSamples
        let strideSamples = max(1, liveDecisionStrideSamples)
        var starts = Array(stride(from: 0, through: maxStart, by: strideSamples))
        if starts.last != maxStart {
            starts.append(maxStart)
        }

        var bestSamples: [Float]?
        var bestRMS: Float = 0
        var bestActivity: Float = -1
        var bestHasSpeech = false

        for start in starts {
            let end = start + spoofWindowSamples
            guard end <= chunk.count else { continue }
            let window = Array(chunk[start..<end])
            let metrics = speechMetrics(window)
            let isBetter = metrics.activityRatio > bestActivity
                || (metrics.activityRatio == bestActivity && metrics.rms > bestRMS)
            if isBetter {
                bestSamples = window
                bestRMS = metrics.rms
                bestActivity = metrics.activityRatio
                bestHasSpeech = metrics.hasSpeech
            }
        }

        guard let bestSamples else { return nil }
        return (
            samples: bestSamples,
            rms: bestRMS,
            activityRatio: max(0, bestActivity),
            hasSpeech: bestHasSpeech
        )
    }

    private nonisolated func appendRolling(_ arr: inout [Float], value: Float, max: Int) {
        arr.append(value)
        if arr.count > max { arr.removeFirst(arr.count - max) }
    }

    private nonisolated func stableSpoofScore(history: [Float], latest: Float) -> Float {
        guard !history.isEmpty else { return latest }

        if latest >= AudioConfiguration.spoofImmediateFakeThresholdCall {
            return latest
        }

        let recent = Array(history.suffix(min(AudioConfiguration.spoofHistoryWindowsCall, history.count)))
        guard recent.count > 1 else { return latest }

        let humanEdge = max(0, AudioConfiguration.spoofHumanThresholdCall - AudioConfiguration.spoofUncertaintyMarginCall)
        let syntheticCandidateEdge = AudioConfiguration.spoofSyntheticCandidateThresholdCall
        let recentAverage = average(recent)

        if latest >= syntheticCandidateEdge {
            return latest
        }

        let recentSyntheticCandidateCount = recent.filter { $0 >= syntheticCandidateEdge }.count
        if recentSyntheticCandidateCount >= 2 {
            return max(recentAverage, recent.max() ?? latest)
        }

        if recentAverage <= humanEdge {
            return recentAverage
        }

        let fakeEdge = max(
            AudioConfiguration.spoofExtremeFakeThresholdCall,
            syntheticCandidateEdge
        )
        let recentFakeCount = recent.filter { $0 >= fakeEdge }.count
        if recentFakeCount >= 2 {
            return max(recentAverage, latest)
        }

        return recentAverage
    }

    private nonisolated func average(_ arr: [Float]) -> Float {
        guard !arr.isEmpty else { return 0 }
        return arr.reduce(0, +) / Float(arr.count)
    }

    private nonisolated func speechMetrics(_ samples: [Float]) -> (rms: Float, activityRatio: Float, hasSpeech: Bool) {
        let fullRMS = rms(samples)
        guard samples.count >= speechFrameSamples else {
            let hasSpeech = fullRMS >= speechRMSFloor
            return (fullRMS, hasSpeech ? 1 : 0, hasSpeech)
        }

        var speechFrames = 0
        var totalFrames = 0
        var maxFrameRMS: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + speechFrameSamples, samples.count)
            if end > start {
                totalFrames += 1
                let frameRMS = rms(Array(samples[start..<end]))
                maxFrameRMS = max(maxFrameRMS, frameRMS)
                if frameRMS >= speechRMSFloor {
                    speechFrames += 1
                }
            }
            start += speechFrameSamples
        }

        let activityRatio = totalFrames > 0 ? Float(speechFrames) / Float(totalFrames) : 0
        let hasSpeech = activityRatio >= minimumSpeechActivityRatio
            && maxFrameRMS >= speechRMSFloor
            && fullRMS >= speechRMSFloor * 0.4
        return (fullRMS, activityRatio, hasSpeech)
    }

    private func temporalSpoofConfidence(
        base: AnalysisConfidence,
        supportingWindows: Int
    ) -> AnalysisConfidence {
        guard base == .high else { return .low }
        return supportingWindows >= AudioConfiguration.spoofWarmupWindowsCall ? .high : .low
    }

    private func analyzeSingleWindow(
        spoofChunk: [Float]?,
        speakerChunk: [Float]?,
        enrolledEmbedding: [Float]?,
        streamLabel: String
    ) -> (spoof: SpoofResult?, speaker: SpeakerResult?) {
        var spoofResult: SpoofResult?
        var speakerResult: SpeakerResult?

        if let chunk = spoofChunk {
            let speech = speechMetrics(chunk)
            let currentRms = speech.rms
            guard speech.hasSpeech else {
                print(
                    String(
                        format: "[AIAnalysis] %@ bench rms=%.5f speech=no activity=%.2f",
                        streamLabel,
                        currentRms,
                        speech.activityRatio
                    )
                )
                return (nil, nil)
            }
            let classicProb = ClassicSpoofDetector.shared.predict(samples: chunk)
            if let classicProb {
                let enoughSpeechForDecision = speech.activityRatio >= minimumDecisionSpeechActivityRatio
                let confidence: AnalysisConfidence = enoughSpeechForDecision ? .high : .low
                spoofResult = SpoofResult(
                    cloneProbability: classicProb,
                    confidence: confidence,
                    threshold: AudioConfiguration.spoofHumanThresholdCall,
                    supportingWindows: 1,
                    processingTimeMs: 0,
                    rms: currentRms,
                    speechActivityRatio: speech.activityRatio
                )
                print(
                    String(
                        format: "[AIAnalysis] %@ bench rms=%.5f speech=yes activity=%.2f decision=%@ classic=%.3f conf=%@ th=%.2f",
                        streamLabel,
                        currentRms,
                        speech.activityRatio,
                        enoughSpeechForDecision ? "yes" : "no",
                        classicProb,
                        confidence.rawValue,
                        AudioConfiguration.spoofHumanThresholdCall
                    )
                )
            }
        }

        if let chunk = speakerChunk, let enrolledEmbedding {
            let currentRms = rms(chunk)
            if currentRms >= minSpeakerRMS {
                let t1 = CFAbsoluteTimeGetCurrent()
                if let liveEmbedding = EmbedderWrapper.shared.embed(samples: chunk) {
                    let sim = EmbedderWrapper.shared.cosineSimilarity(liveEmbedding, enrolledEmbedding)
                    let embMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
                    speakerResult = SpeakerResult(
                        similarity: sim,
                        threshold: AudioConfiguration.speakerMatchThresholdCall,
                        processingTimeMs: embMs
                    )
                }
            }
        }

        return (spoofResult, speakerResult)
    }

    private nonisolated func rms(_ arr: [Float]) -> Float {
        guard !arr.isEmpty else { return 0 }
        return sqrt(arr.reduce(0) { $0 + ($1 * $1) } / Float(arr.count))
    }


}

private struct ModelCaptureManifestRow: Codable {
    let capture_id: String
    let timestamp_utc: String
    let stream_source: String
    let contact_id: String
    let input_sample_rate_hz: Int
    let post_resample_rate_hz: Int
    let window_seconds: Double
    let window_samples: Int
    let rms_pre_gain: Float
    let rms_post_gain: Float
    let peak_pre_gain: Float
    let peak_post_gain: Float
    let gain_applied: Float
    let speaker_model_version: String
    let spoof_model_version: String
    let speaker_similarity: Float?
    let speaker_threshold: Float
    let speaker_is_match: Bool?
    let clone_probability: Float?
    let spoof_threshold: Float
    let spoof_is_human: Bool?
    let spoof_confidence: String
    let route: String
    let device_model: String
    let call_stack: String
    let raw_capture_path: String
    let speaker_input_path: String
    let spoof_input_path: String
    let metadata_path: String
}

private final class ModelCaptureExportService {
    static let shared = ModelCaptureExportService()

    let rootURL: URL

    private let queue = DispatchQueue(label: "com.vericall.model-capture-export", qos: .utility)
    private let fm = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()
    private let captureInterval: TimeInterval = 3.0
    private var lastCaptureAtBySource: [String: Date] = [:]
    private let manifestHeader = [
        "capture_id",
        "timestamp_utc",
        "stream_source",
        "contact_id",
        "input_sample_rate_hz",
        "post_resample_rate_hz",
        "window_seconds",
        "window_samples",
        "rms_pre_gain",
        "rms_post_gain",
        "peak_pre_gain",
        "peak_post_gain",
        "gain_applied",
        "speaker_model_version",
        "spoof_model_version",
        "speaker_similarity",
        "speaker_threshold",
        "speaker_is_match",
        "clone_probability",
        "spoof_threshold",
        "spoof_is_human",
        "spoof_confidence",
        "route",
        "device_model",
        "call_stack",
        "raw_capture_path",
        "speaker_input_path",
        "spoof_input_path",
        "metadata_path",
    ]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        rootURL = docs.appendingPathComponent("ModelCaptures", isDirectory: true)
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func capture(
        streamSource: String,
        rawSamples: [Float],
        speakerSamples: [Float],
        spoofSamples: [Float],
        spoofGainApplied: Float,
        spoofConfidence: AnalysisConfidence,
        rmsPreGain: Float,
        speakerResult: SpeakerResult?,
        spoofResult: SpoofResult?,
        contactId: String?,
        route: String,
        callStack: String
    ) {
        let now = Date()
        queue.async {
            if let last = self.lastCaptureAtBySource[streamSource], now.timeIntervalSince(last) < self.captureInterval {
                return
            }
            self.lastCaptureAtBySource[streamSource] = now

            let captureId = "\(streamSource)_\(Int(now.timeIntervalSince1970))_\(UUID().uuidString.prefix(8))"
            let captureDir = self.rootURL.appendingPathComponent(captureId, isDirectory: true)
            do {
                try self.fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
                let rawURL = captureDir.appendingPathComponent("raw.wav")
                let speakerURL = captureDir.appendingPathComponent("speaker_input.wav")
                let spoofURL = captureDir.appendingPathComponent("spoof_input.wav")
                let metadataURL = captureDir.appendingPathComponent("metadata.json")

                try self.writeMonoFloatWav(samples: rawSamples, to: rawURL)
                try self.writeMonoFloatWav(samples: speakerSamples, to: speakerURL)
                try self.writeMonoFloatWav(samples: spoofSamples, to: spoofURL)

                let row = ModelCaptureManifestRow(
                    capture_id: captureId,
                    timestamp_utc: self.isoFormatter.string(from: now),
                    stream_source: streamSource,
                    contact_id: contactId ?? "",
                    input_sample_rate_hz: 16_000,
                    post_resample_rate_hz: 16_000,
                    window_seconds: AudioConfiguration.analysisWindowSeconds,
                    window_samples: AudioConfiguration.analysisWindowSamples,
                    rms_pre_gain: rmsPreGain,
                    rms_post_gain: self.rms(spoofSamples),
                    peak_pre_gain: self.peak(rawSamples),
                    peak_post_gain: self.peak(spoofSamples),
                    gain_applied: spoofGainApplied,
                    speaker_model_version: AudioConfiguration.voiceEmbedderVersion,
                    spoof_model_version: AudioConfiguration.spoofDetectorVersion,
                    speaker_similarity: speakerResult?.similarity,
                    speaker_threshold: AudioConfiguration.speakerMatchThresholdCall,
                    speaker_is_match: speakerResult?.isMatch,
                    clone_probability: spoofResult?.cloneProbability,
                    spoof_threshold: AudioConfiguration.spoofHumanThresholdCall,
                    spoof_is_human: spoofResult?.isHuman,
                    spoof_confidence: spoofConfidence.rawValue,
                    route: route,
                    device_model: UIDevice.current.model,
                    call_stack: callStack,
                    raw_capture_path: rawURL.path,
                    speaker_input_path: speakerURL.path,
                    spoof_input_path: spoofURL.path,
                    metadata_path: metadataURL.path
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(row).write(to: metadataURL)
                try self.appendToManifest(row)
            } catch {
                print("[ModelCaptureExport] failed for \(captureId): \(error)")
            }
        }
    }

    private func appendToManifest(_ row: ModelCaptureManifestRow) throws {
        let manifestURL = rootURL.appendingPathComponent("capture_manifest.csv")
        if !fm.fileExists(atPath: manifestURL.path) {
            let headerLine = manifestHeader.joined(separator: ",") + "\n"
            try headerLine.write(to: manifestURL, atomically: true, encoding: .utf8)
        }

        let line = [
            row.capture_id,
            row.timestamp_utc,
            row.stream_source,
            row.contact_id,
            String(row.input_sample_rate_hz),
            String(row.post_resample_rate_hz),
            String(format: "%.2f", row.window_seconds),
            String(row.window_samples),
            String(format: "%.6f", row.rms_pre_gain),
            String(format: "%.6f", row.rms_post_gain),
            String(format: "%.6f", row.peak_pre_gain),
            String(format: "%.6f", row.peak_post_gain),
            String(format: "%.6f", row.gain_applied),
            row.speaker_model_version,
            row.spoof_model_version,
            row.speaker_similarity.map { String(format: "%.6f", $0) } ?? "",
            String(format: "%.6f", row.speaker_threshold),
            row.speaker_is_match.map(String.init(describing:)) ?? "",
            row.clone_probability.map { String(format: "%.6f", $0) } ?? "",
            String(format: "%.6f", row.spoof_threshold),
            row.spoof_is_human.map(String.init(describing:)) ?? "",
            row.spoof_confidence,
            row.route,
            row.device_model,
            row.call_stack,
            row.raw_capture_path,
            row.speaker_input_path,
            row.spoof_input_path,
            row.metadata_path,
        ].map(Self.escapeCSV)
        let rowLine = line.joined(separator: ",") + "\n"
        if let handle = try? FileHandle(forWritingTo: manifestURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data(rowLine.utf8))
        }
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func writeMonoFloatWav(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "ModelCaptureExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer"])
        }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "ModelCaptureExport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing channel data"])
        }
        for (idx, sample) in samples.enumerated() {
            channel[idx] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + ($1 * $1) } / Float(samples.count))
    }

    private func peak(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }
}
