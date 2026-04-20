#if os(macOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class MacCallSessionViewModel: ObservableObject {
    @Published private(set) var callStateDescription = "Idle"
    @Published private(set) var lastServerTranscript = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isCallActive = false
    @Published private(set) var isTransitioningCallState = false

    private let linphoneClient = LiblinphoneCallClient()
    private let tonePlayer = CallTonePlayer.shared

    init() {
        linphoneClient.delegate = self
        appendLog("Ready")
    }

    func startCall() {
        guard !isCallActive, !isTransitioningCallState else {
            appendLog("Ignored duplicate call start request")
            return
        }

        isTransitioningCallState = true
        Task {
            let hasPermission = await requestMicrophonePermission()
            guard hasPermission else {
                callStateDescription = "Microphone permission required"
                appendLog("Microphone permission was denied")
                isTransitioningCallState = false
                return
            }

            do {
                try linphoneClient.start()
                callStateDescription = "Connected"
                isCallActive = true
                tonePlayer.playConnectTone()
            } catch {
                callStateDescription = "Call start failed"
                appendLog("Failed to start Liblinphone: \(error.localizedDescription)")
            }

            isTransitioningCallState = false
        }
    }

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        Task {
            linphoneClient.stop()
            callStateDescription = "Disconnected"
            isCallActive = false
            tonePlayer.playDisconnectTone()
            isTransitioningCallState = false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.insert("[\(timestamp)] \(message)", at: 0)
        if logLines.count > 40 {
            logLines.removeLast(logLines.count - 40)
        }
    }
}

extension MacCallSessionViewModel: LiblinphoneCallClientDelegate {
    func liblinphoneCallClient(_ client: LiblinphoneCallClient, didLog message: String) {
        appendLog(message)
    }
}
#endif
