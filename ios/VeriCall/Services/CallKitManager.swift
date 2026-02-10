import Foundation
import CallKit
import AVFoundation

// MARK: - CallKit Manager
@MainActor
class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()
    
    private let provider: CXProvider
    private let callController: CXCallController
    private var callProviderDelegate: CallProviderDelegate?
    
    private var incomingCallCompletion: ((Bool) -> Void)?
    
    private override init() {
        // Configure CallKit provider
        let providerConfiguration = CXProviderConfiguration(localizedName: "VeriCall")
        providerConfiguration.supportsVideo = false
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.supportedHandleTypes = [.generic, .phoneNumber]
        providerConfiguration.iconTemplateImageData = nil // TODO: Add app icon
        providerConfiguration.ringtoneSound = "call_ringtone.caf" // TODO: Add ringtone
        
        self.provider = CXProvider(configuration: providerConfiguration)
        self.callController = CXCallController()
        
        super.init()
        
        self.callProviderDelegate = CallProviderDelegate(manager: self)
        self.provider.setDelegate(self.callProviderDelegate, queue: nil)
    }
    
    // MARK: - Incoming Call
    func reportIncomingCall(call: Call, completion: @escaping (Bool) -> Void) async {
        incomingCallCompletion = completion
        
        let update = CXCallUpdate()
        update.localizedCallerName = call.callerName
        update.supportsHolding = true
        update.supportsDTMF = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false
        
        // Add custom context for verification status
        let handle = CXHandle(type: .generic, value: call.callerId)
        update.remoteHandle = handle
        
        provider.reportNewIncomingCall(with: UUID(uuidString: call.id) ?? UUID(), update: update) { error in
            if let error = error {
                print("Failed to report incoming call: \(error)")
                completion(false)
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
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
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
    fileprivate func handleCallAccepted() {
        incomingCallCompletion?(true)
        incomingCallCompletion = nil
    }
    
    fileprivate func handleCallRejected() {
        incomingCallCompletion?(false)
        incomingCallCompletion = nil
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
        Task { @MainActor in manager?.deactivateAudioSession() }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("CallKit: Answer call \(action.callUUID)")
        Task { @MainActor in
            manager?.configureAudioSession()
            manager?.handleCallAccepted()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("CallKit: End call \(action.callUUID)")
        Task { @MainActor in
            manager?.deactivateAudioSession()
            manager?.handleCallRejected()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("CallKit: Start call \(action.callUUID)")
        Task { @MainActor in manager?.configureAudioSession() }
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print("CallKit: Set muted \(action.isMuted) for \(action.callUUID)")
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
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("CallKit: Audio session deactivated")
    }
}
