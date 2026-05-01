import Foundation
import CallKit
import AVFoundation
import UIKit

// MARK: - CallKit Manager
@MainActor
class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()
    
    private let provider: CXProvider
    private let callController: CXCallController
    private var callProviderDelegate: CallProviderDelegate?
    private var incomingReportDatesByUUID: [UUID: Date] = [:]
    fileprivate var isCallKitAudioSessionActive = false
    fileprivate var lastCallKitEvent = "initialized"
    
    private var incomingCallCompletion: ((Bool) -> Void)?
    var onAnswerCall: ((UUID) -> Void)?
    var onEndCall: ((UUID) -> Void)?
    var onMuteCall: ((UUID, Bool) -> Void)?
    
    private override init() {
        // Configure CallKit provider
        let providerConfiguration = CXProviderConfiguration(localizedName: Constants.callKitDisplayName)
        providerConfiguration.supportsVideo = false
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.supportedHandleTypes = [.generic, .phoneNumber]
        providerConfiguration.iconTemplateImageData = nil
        
        self.provider = CXProvider(configuration: providerConfiguration)
        self.callController = CXCallController()
        
        super.init()
        
        self.callProviderDelegate = CallProviderDelegate(manager: self)
        self.provider.setDelegate(self.callProviderDelegate, queue: nil)
    }
    
    // MARK: - Incoming Call
    //
    // NOTE: intentionally synchronous (not `async`). The iOS 13+ PushKit
    // contract requires CXProvider.reportNewIncomingCall to be invoked from
    // within the PKPushRegistry delegate's synchronous call stack — if we
    // marked this `async`, every caller would have to `await` it, which would
    // suspend and return control to the PushKit delegate before the call was
    // actually reported, violating the contract and causing iOS to terminate
    // the app and blackhole future VoIP pushes for this bundle id. The body
    // does not actually need to await anything; provider.reportNewIncomingCall
    // itself accepts a completion closure which can fire asynchronously.
    func reportIncomingCall(
        call: Call,
        reportCompletion: ((Bool) -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        incomingCallCompletion = completion

        let update = CXCallUpdate()
        update.localizedCallerName = call.callerName
        update.supportsHolding = true
        update.supportsDTMF = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false
        
        // Add custom context for verification status
        let handleType: CXHandle.HandleType = call.callerId.hasPrefix("+") ? .phoneNumber : .generic
        let handle = CXHandle(type: handleType, value: call.callerId)
        update.remoteHandle = handle
        
        let callUUID = UUID(uuidString: call.id) ?? UUID()
        incomingReportDatesByUUID[callUUID] = Date()

        provider.reportNewIncomingCall(with: callUUID, update: update) { error in
            if let error = error {
                print("Failed to report incoming call: \(error)")
                CallDebugReporter.post("callkit_report_failed", details: ["caller": call.callerName, "error": error.localizedDescription])
                Task { @MainActor in
                    self.incomingReportDatesByUUID.removeValue(forKey: callUUID)
                }
                reportCompletion?(false)
                completion(false)
            } else {
                print("CallKit: Incoming call reported for \(call.callerName)")
                Task { @MainActor in
                    self.lastCallKitEvent = "report_success"
                }
                CallDebugReporter.post("callkit_report_success", details: ["caller": call.callerName, "uuid": callUUID.uuidString])
                reportCompletion?(true)
            }
        }
    }
    
    // MARK: - Outgoing Call
    func reportOutgoingCall(call: Call) async {
        let handle = CXHandle(type: .generic, value: call.recipientId)
        let startCallAction = CXStartCallAction(call: UUID(uuidString: call.id) ?? UUID(), handle: handle)
        startCallAction.isVideo = false
        startCallAction.contactIdentifier = call.recipientName
        
        let transaction = CXTransaction(action: startCallAction)
        
        do {
            try await callController.request(transaction)
        } catch {
            print("Failed to start call via CallKit: \(error)")
        }
    }
    
    // MARK: - Call Connected
    func reportCallConnected(callId: String) async {
        provider.reportOutgoingCall(
            with: UUID(uuidString: callId) ?? UUID(),
            connectedAt: Date()
        )
    }

    func updateCallDisplay(callId: String, callerName: String, handleValue: String?) {
        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.supportsHolding = true
        update.supportsDTMF = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false

        if let handleValue, !handleValue.isEmpty {
            let handleType: CXHandle.HandleType = handleValue.hasPrefix("+") ? .phoneNumber : .generic
            update.remoteHandle = CXHandle(type: handleType, value: handleValue)
        }

        provider.reportCall(with: UUID(uuidString: callId) ?? UUID(), updated: update)
        lastCallKitEvent = "display_updated"
        CallDebugReporter.post(
            "callkit_display_updated",
            details: [
                "uuid": callId,
                "callerName": callerName,
                "handle": handleValue ?? "none"
            ]
        )
    }
    
    // MARK: - Call Ended
    func reportCallEnded(callId: String) async {
        provider.reportCall(
            with: UUID(uuidString: callId) ?? UUID(),
            endedAt: Date(),
            reason: .remoteEnded
        )
    }
    
    // MARK: - Call Actions
    func performAnswerCall(callId: String) {
        let answerAction = CXAnswerCallAction(call: UUID(uuidString: callId) ?? UUID())
        let transaction = CXTransaction(action: answerAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to answer call: \(error)")
            }
        }
    }
    
    func performEndCall(callId: String) {
        let endAction = CXEndCallAction(call: UUID(uuidString: callId) ?? UUID())
        let transaction = CXTransaction(action: endAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to end call: \(error)")
            }
        }
    }
    
    func performSetMuted(callId: String, muted: Bool) {
        let muteAction = CXSetMutedCallAction(call: UUID(uuidString: callId) ?? UUID(), muted: muted)
        let transaction = CXTransaction(action: muteAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to set mute: \(error)")
            }
        }
    }
    
    func performSetHeld(callId: String, onHold: Bool) {
        let holdAction = CXSetHeldCallAction(call: UUID(uuidString: callId) ?? UUID(), onHold: onHold)
        let transaction = CXTransaction(action: holdAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to set hold: \(error)")
            }
        }
    }
    
    // MARK: - Audio Session
    func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    func deactivateAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    // MARK: - Internal Callbacks
    fileprivate func handleCallAccepted(callUUID: UUID) {
        lastCallKitEvent = "answer_accepted"
        CallDebugReporter.post("callkit_handle_accepted", details: ["uuid": callUUID.uuidString])
        AIAnalysisService.shared.prepareForCallKitAnswer()
        incomingReportDatesByUUID.removeValue(forKey: callUUID)
        if let incomingCallCompletion {
            incomingCallCompletion(true)
            self.incomingCallCompletion = nil
        } else {
            onAnswerCall?(callUUID)
        }
    }
    
    fileprivate func handleCallEnded(callUUID: UUID) {
        lastCallKitEvent = "ended"
        CallDebugReporter.post("callkit_handle_ended", details: ["uuid": callUUID.uuidString])
        incomingReportDatesByUUID.removeValue(forKey: callUUID)
        if let incomingCallCompletion {
            incomingCallCompletion(false)
            self.incomingCallCompletion = nil
        } else {
            onEndCall?(callUUID)
        }
    }

    fileprivate func detailsForEndAction(callUUID: UUID) -> [String: String] {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }

        var details: [String: String] = [
            "uuid": callUUID.uuidString,
            "app_state": state
        ]
        if let reportedAt = incomingReportDatesByUUID[callUUID] {
            details["seconds_since_report"] = String(format: "%.2f", Date().timeIntervalSince(reportedAt))
        }
        return details
    }

    func debugStateDetails() -> [String: String] {
        [
            "callkit_audio_active": isCallKitAudioSessionActive ? "true" : "false",
            "callkit_last_event": lastCallKitEvent,
            "callkit_pending_reports": "\(incomingReportDatesByUUID.count)"
        ]
    }
}

// MARK: - Call Provider Delegate
private class CallProviderDelegate: NSObject, CXProviderDelegate {
    weak var manager: CallKitManager?
    
    init(manager: CallKitManager) {
        self.manager = manager
        super.init()
    }
    
    func providerDidReset(_ provider: CXProvider) {
        print("CallKit provider reset")
        CallDebugReporter.post("callkit_provider_reset")
        Task { @MainActor in
            manager?.isCallKitAudioSessionActive = false
            manager?.lastCallKitEvent = "provider_reset"
            manager?.deactivateAudioSession()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("CallKit: Answer call \(action.callUUID)")
        CallDebugReporter.post("callkit_answer_action", details: ["uuid": action.callUUID.uuidString])
        Task { @MainActor in
            manager?.lastCallKitEvent = "answer_action"
            manager?.configureAudioSession()
            manager?.handleCallAccepted(callUUID: action.callUUID)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("CallKit: End call \(action.callUUID)")
        Task { @MainActor in
            let details = manager?.detailsForEndAction(callUUID: action.callUUID) ?? ["uuid": action.callUUID.uuidString]
            CallDebugReporter.post("callkit_end_action", details: details)
            manager?.deactivateAudioSession()
            manager?.handleCallEnded(callUUID: action.callUUID)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("CallKit: Start call \(action.callUUID)")
        CallDebugReporter.post("callkit_start_action", details: ["uuid": action.callUUID.uuidString])
        Task { @MainActor in manager?.configureAudioSession() }
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print("CallKit: Set muted \(action.isMuted) for \(action.callUUID)")
        Task { @MainActor in
            manager?.onMuteCall?(action.callUUID, action.isMuted)
        }
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        print("CallKit: Set held \(action.isOnHold) for \(action.callUUID)")
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        print("CallKit: Play DTMF \(action.digits) for \(action.callUUID)")
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("CallKit: Audio session activated")
        CallDebugReporter.post("callkit_audio_activated")
        Task { @MainActor in
            manager?.isCallKitAudioSessionActive = true
            manager?.lastCallKitEvent = "audio_activated"
        }
#if canImport(TwilioVoice)
        Task { @MainActor in
            TwilioCallService.shared.handleCallKitAudioSessionActivated()
        }
#endif
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("CallKit: Audio session deactivated")
        CallDebugReporter.post("callkit_audio_deactivated")
        Task { @MainActor in
            manager?.isCallKitAudioSessionActive = false
            manager?.lastCallKitEvent = "audio_deactivated"
        }
#if canImport(TwilioVoice)
        Task { @MainActor in
            TwilioCallService.shared.handleCallKitAudioSessionDeactivated()
        }
#endif
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        let uuid = (action as? CXCallAction)?.callUUID.uuidString ?? "unknown"
        print("CallKit: Timed out action \(type(of: action)) \(uuid)")
        CallDebugReporter.post(
            "callkit_action_timed_out",
            details: ["uuid": uuid, "action": "\(type(of: action))"]
        )
    }
}
