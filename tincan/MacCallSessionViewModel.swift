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

    private let audioPipeline = AudioTurnPipeline()
    private let inferenceClient = BackendInferenceClient()
    private let tonePlayer = CallTonePlayer.shared
    private let backendURL = URL(string: BackendConnectionConfig.loopbackInferenceURLString)

    init() {
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
                callStateDescription = "Microphone permission required"
                appendLog("Microphone permission was denied")
                isTransitioningCallState = false
                return
            }

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

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        Task {
            await audioPipeline.stop()
            callStateDescription = "Disconnected"
            isCallActive = false
            tonePlayer.stopCallBed()
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

    private func uploadSegment(_ data: Data, duration: TimeInterval) {
        guard let backendURL else {
            appendLog("Backend URL is invalid")
            return
        }

        Task {
            do {
                let result = try await inferenceClient.infer(audioWAV: data, endpoint: backendURL)
                lastServerTranscript = result.transcript
                appendLog("Backend transcript: \(result.transcript)")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
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

extension MacCallSessionViewModel: AudioTurnPipelineOutput {
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
