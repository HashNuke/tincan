#if os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class CallSessionViewModel: ObservableObject {
    @Published var backendURLString: String = Self.initialBackendURL()
    @Published var callStateDescription = "Idle"
    @Published var lastServerTranscript = ""
    @Published var logLines: [String] = []
    @Published var isCallActive = false
    @Published var isTransitioningCallState = false

    private let callKitController = CallKitController()
    private let audioPipeline = AudioTurnPipeline()
    private let inferenceClient = BackendInferenceClient()
    private let tonePlayer = CallTonePlayer.shared

    private static let backendURLKey = "backend_url"
    private static let defaultBackendURL = BackendConnectionConfig.inferenceURLString
    private static let legacyDefaultBackendURLs: Set<String> = [
        "http://127.0.0.1:52734/infer",
        "http://127.0.0.1:8004/infer",
    ]

    init() {
        callKitController.delegate = self
        audioPipeline.setDelegate(self)
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
                appendLog("Microphone permission was denied")
                callStateDescription = "Microphone permission required"
                isTransitioningCallState = false
                return
            }

            persistBackendURL()
            callKitController.startCall()
        }
    }

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        callKitController.endCall()
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func persistBackendURL() {
        UserDefaults.standard.set(backendURLString, forKey: Self.backendURLKey)
    }

    private static func initialBackendURL() -> String {
        let storedValue = UserDefaults.standard.string(forKey: backendURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storedValue, !storedValue.isEmpty else {
            return defaultBackendURL
        }

        if legacyDefaultBackendURLs.contains(storedValue) {
            return defaultBackendURL
        }

        return storedValue
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.insert("[\(timestamp)] \(message)", at: 0)
        if logLines.count > 40 {
            logLines.removeLast(logLines.count - 40)
        }
    }

    private func uploadSegment(_ data: Data, duration: TimeInterval) {
        guard let url = URL(string: backendURLString) else {
            appendLog("Backend URL is invalid")
            return
        }

        Task {
            do {
                let result = try await inferenceClient.infer(audioWAV: data, endpoint: url)
                lastServerTranscript = result.transcript
                appendLog("Backend transcript: \(result.transcript)")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}

extension CallSessionViewModel: CallKitControllerDelegate {
    func callKitController(_ controller: CallKitController, didUpdateState description: String, active: Bool) {
        callStateDescription = description
        isCallActive = active
        appendLog(description)
    }

    func callKitControllerDidActivateAudio(_ controller: CallKitController) {
        Task {
            do {
                try await audioPipeline.start()
                callStateDescription = "Listening"
                isCallActive = true
                tonePlayer.startCallBed()
                tonePlayer.playConnectTone()
            } catch {
                callStateDescription = "Audio start failed"
                appendLog("Failed to start audio pipeline: \(error.localizedDescription)")
            }

            isTransitioningCallState = false
        }
    }

    func callKitControllerDidDeactivateAudio(_ controller: CallKitController) {
        Task {
            await audioPipeline.stop()
            callStateDescription = "Idle"
            isCallActive = false
            tonePlayer.stopCallBed()
            tonePlayer.playDisconnectTone()
            isTransitioningCallState = false
        }
    }

    func callKitController(_ controller: CallKitController, didFail message: String) {
        callStateDescription = "Call failed"
        tonePlayer.stopCallBed()
        isCallActive = false
        isTransitioningCallState = false
        appendLog("CallKit error: \(message)")
    }
}

extension CallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidProduceSegment(_ data: Data, duration: TimeInterval) {
        uploadSegment(data, duration: duration)
    }

    func audioTurnPipelineDidDetectSpeechStart() {
        tonePlayer.duckCallBed()
    }

    func audioTurnPipelineDidDetectSpeechEnd() {
        tonePlayer.unduckCallBed()
    }
}
#endif
