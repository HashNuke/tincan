#if os(iOS)
import AVFoundation
import CallKit
import Foundation

@MainActor
protocol CallKitControllerDelegate: AnyObject {
    func callKitController(_ controller: CallKitController, didUpdateState description: String, active: Bool)
    func callKitControllerDidActivateAudio(_ controller: CallKitController)
    func callKitControllerDidDeactivateAudio(_ controller: CallKitController)
    func callKitController(_ controller: CallKitController, didFail message: String)
}

final class CallKitController: NSObject {
    weak var delegate: (any CallKitControllerDelegate)?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "tincan")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]

        provider = CXProvider(configuration: configuration)

        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func startCall() {
#if targetEnvironment(simulator)
        activeCallUUID = UUID()
        delegate?.callKitController(self, didUpdateState: "Running without CallKit on Simulator", active: true)
        delegate?.callKitControllerDidActivateAudio(self)
        return
#else
        let callUUID = UUID()
        activeCallUUID = callUUID

        let handle = CXHandle(type: .generic, value: "Coding Agent")
        let startAction = CXStartCallAction(call: callUUID, handle: handle)
        startAction.isVideo = false
        let transaction = CXTransaction(action: startAction)

        delegate?.callKitController(self, didUpdateState: "Requesting CallKit call…", active: false)

        callController.request(transaction) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.activeCallUUID = nil
                    self.delegate?.callKitController(self, didFail: error.localizedDescription)
                    return
                }
                self.delegate?.callKitController(self, didUpdateState: "Call requested", active: false)
            }
        }
#endif
    }

    func endCall() {
#if targetEnvironment(simulator)
        guard activeCallUUID != nil else { return }
        activeCallUUID = nil
        delegate?.callKitControllerDidDeactivateAudio(self)
        delegate?.callKitController(self, didUpdateState: "Call ended", active: false)
        return
#else
        guard let activeCallUUID else { return }
        let endAction = CXEndCallAction(call: activeCallUUID)
        let transaction = CXTransaction(action: endAction)

        callController.request(transaction) { [weak self] error in
            guard let self, let error else { return }
            Task { @MainActor in
                self.delegate?.callKitController(self, didFail: error.localizedDescription)
            }
        }
#endif
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
    }
}

extension CallKitController: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
        delegate?.callKitControllerDidDeactivateAudio(self)
        delegate?.callKitController(self, didUpdateState: "Call provider reset", active: false)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do {
            try configureAudioSession()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            activeCallUUID = action.callUUID
            delegate?.callKitController(self, didUpdateState: "Call connected", active: true)
            action.fulfill()
        } catch {
            activeCallUUID = nil
            delegate?.callKitController(self, didFail: error.localizedDescription)
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        activeCallUUID = nil
        delegate?.callKitControllerDidDeactivateAudio(self)
        delegate?.callKitController(self, didUpdateState: "Call ended", active: false)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        delegate?.callKitControllerDidActivateAudio(self)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        delegate?.callKitControllerDidDeactivateAudio(self)
        delegate?.callKitController(self, didUpdateState: "Audio session deactivated", active: false)
    }
}
#endif
