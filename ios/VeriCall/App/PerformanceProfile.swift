import Darwin
import Foundation
import UIKit

enum DevicePerformanceTier: String {
    case legacy
    case balanced
    case modern
}

struct AppPerformanceProfile {
    static let shared = AppPerformanceProfile.make()

    let tier: DevicePerformanceTier
    let hardwareIdentifier: String
    let isLowPowerModeEnabled: Bool
    let thermalStateDescription: String
    let analysisFirstRunDelay: TimeInterval
    let analysisInterval: TimeInterval
    let immediateAnalysisMinimumInterval: TimeInterval
    let modelWarmupDelay: TimeInterval
    let firstCallModelWarmupDelay: TimeInterval
    let audioMirrorPollNanoseconds: UInt64
    let verboseCallLogging: Bool
    let verboseAILogging: Bool

    var summary: String {
        "tier=\(tier.rawValue) device=\(hardwareIdentifier) lowPower=\(isLowPowerModeEnabled) thermal=\(thermalStateDescription)"
    }

    func logAI(_ message: @autoclosure () -> String) {
        guard verboseAILogging else { return }
        print(message())
    }

    func logCall(_ message: @autoclosure () -> String) {
        guard verboseCallLogging else { return }
        print(message())
    }

    private static func make() -> AppPerformanceProfile {
        let processInfo = ProcessInfo.processInfo
        let identifier = hardwareIdentifier()
        let thermalState = processInfo.thermalState
        let lowPower = processInfo.isLowPowerModeEnabled
        var tier = baseTier(for: identifier)

        if lowPower || thermalState == .serious || thermalState == .critical {
            tier = .legacy
        }

        let tuning: (
            firstRun: TimeInterval,
            interval: TimeInterval,
            immediate: TimeInterval,
            warmup: TimeInterval,
            firstCallWarmup: TimeInterval,
            mirrorPoll: UInt64
        )

        // Keep the live verification cadence identical across supported phones.
        // Device tiers still get reported for diagnostics, but the AI should
        // feed the same 3s windows into the same model on iPhone 13 and newer.
        switch tier {
        case .modern, .balanced, .legacy:
            tuning = (0.12, 0.25, 0.25, 0.25, 0.05, 150_000_000)
        }

        let explicitVerboseLogs = UserDefaults.standard.bool(forKey: "vericall.verbosePerformanceLogs")
#if DEBUG
        let verboseLogs = explicitVerboseLogs && tier == .modern
#else
        let verboseLogs = false
#endif

        return AppPerformanceProfile(
            tier: tier,
            hardwareIdentifier: identifier,
            isLowPowerModeEnabled: lowPower,
            thermalStateDescription: thermalState.description,
            analysisFirstRunDelay: tuning.firstRun,
            analysisInterval: tuning.interval,
            immediateAnalysisMinimumInterval: tuning.immediate,
            modelWarmupDelay: tuning.warmup,
            firstCallModelWarmupDelay: tuning.firstCallWarmup,
            audioMirrorPollNanoseconds: tuning.mirrorPoll,
            verboseCallLogging: verboseLogs,
            verboseAILogging: verboseLogs
        )
    }

    private static func baseTier(for identifier: String) -> DevicePerformanceTier {
#if targetEnvironment(simulator)
        return .modern
#else
        if let iPhoneMajor = familyMajorVersion(identifier, prefix: "iPhone") {
            if iPhoneMajor <= 14 { return .legacy }
            if iPhoneMajor <= 16 { return .balanced }
            return .modern
        }

        if let iPadMajor = familyMajorVersion(identifier, prefix: "iPad") {
            if iPadMajor <= 13 { return .legacy }
            if iPadMajor <= 15 { return .balanced }
            return .modern
        }

        return .balanced
#endif
    }

    private static func familyMajorVersion(_ identifier: String, prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = identifier.dropFirst(prefix.count)
        guard let majorText = suffix.split(separator: ",").first else { return nil }
        return Int(majorText)
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}

private extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}
