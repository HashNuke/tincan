#if os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class CallSessionViewModel: ObservableObject {
    @Published var backendURLString: String = UserDefaults.standard.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
    @Published var callStateDescription = "Idle"
    @Published var lastServerTranscript = ""
    @Published var logLines: [String] = []
    @Published var isCallActive = false

    private let callKitController = CallKitController()
    private let audioPipeline = AudioTurnPipeline()
    private let inferenceClient = BackendInferenceClient()

    private static let backendURLKey = "backend_url"
    private static let defaultBackendURL = "http://127.0.0.1:52734/infer"

    init() {
        callKitController.delegate = self
        audioPipeline.setDelegate(self)
        appendLog("Ready")
    }

    func startCall() {
        Task {
            let hasPermission = await requestMicrophonePermission()
            guard hasPermission else {
                appendLog("Microphone permission was denied")
                callStateDescription = "Microphone permission required"
                return
            }

            persistBackendURL()
            callKitController.startCall()
        }
    }

    func endCall() {
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
            } catch {
                callStateDescription = "Audio start failed"
                appendLog("Failed to start audio pipeline: \(error.localizedDescription)")
            }
        }
    }

    func callKitControllerDidDeactivateAudio(_ controller: CallKitController) {
        Task {
            await audioPipeline.stop()
            callStateDescription = "Idle"
            isCallActive = false
        }
    }

    func callKitController(_ controller: CallKitController, didFail message: String) {
        callStateDescription = "Call failed"
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
}

private struct BackendInferenceClient {
    struct Response: Decodable {
        let requestId: String
        let transcript: String
    }

    func infer(audioWAV: Data, endpoint: URL) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = audioWAV
        request.timeoutInterval = 180
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard let httpResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
#endif
