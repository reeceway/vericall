import Foundation
import Combine

/// Legacy call manager — superseded by VoIPCallService + AgoraCallService.
/// Kept as a stub so existing references compile.
@MainActor
class CallManager: ObservableObject {
    static let shared = CallManager()

    @Published var currentCall: Call?
    @Published var isInCall: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    private init() {}

    func initiateCall(to contact: Contact) async throws {}
    func answerCall(_ call: Call) async throws {}
    func endCall() async throws {}
    func setMute(_ muted: Bool) async throws {}
    func setSpeaker(_ on: Bool) async throws {}
    func holdCall() async throws {}
    func resumeCall() async throws {}
    func sendDTMF(_ digit: String) async throws {}
    func acceptCall(_ call: Call) async throws {}
    func declineCall(_ call: Call) async throws {}
}
