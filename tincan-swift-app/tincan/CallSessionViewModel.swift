#if os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class CallSessionViewModel: ObservableObject {
    @Published var backendURLString: String
    @Published var callStateDescription = "Idle"
    @Published var lastServerTranscript = ""
    @Published var logLines: [String] = []
    @Published var isCallActive = false
    @Published var isTransitioningCallState = false

    private let callKitController = CallKitController()
    private let audioPipeline = AudioTurnPipeline()
    private let tonePlayer = CallTonePlayer.shared

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?

    private static let backendURLKey = "backend_url"
    private static let defaultBackendURL = BackendConnectionConfig.serverBaseURLString
    private static let legacyDefaultBackendURLs: Set<String> = [
        "http://127.0.0.1:52734/infer",
        "http://127.0.0.1:8004/infer",
        BackendConnectionConfig.inferenceURLString,
        BackendConnectionConfig.loopbackInferenceURLString,
    ]

    init() {
        backendURLString = Self.initialBackendURL()
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

    private func makeSessionClient() -> BackendSessionClient? {
        guard let url = URL(string: backendURLString) else { return nil }
        return BackendSessionClient(serverBaseURL: url)
    }

    private func subscribeToServerEvents(client: BackendSessionClient, sessionID: String) {
        eventTask = Task {
            for await event in client.eventStream(sessionID: sessionID) {
                switch event {
                case .playAudio(let text, let urlPath):
                    appendLog("Server: \(text)")
                    await playServerAudioIfPresent(urlPath, client: client, fallbackLogPrefix: "Server audio")
                case .notify(let text, let audioURLPath, let summaryText, let summaryAudioURLPath):
                    let playbackChoice = BackendSessionClient.notificationPlaybackChoice(
                        text: text,
                        audioURLPath: audioURLPath,
                        summaryText: summaryText,
                        summaryAudioURLPath: summaryAudioURLPath,
                        isAudioPlaying: tonePlayer.isPlayingAudio
                    )
                    appendLog("Notify: \(playbackChoice.text)")
                    await playServerAudioIfPresent(
                        playbackChoice.audioURLPath,
                        client: client,
                        fallbackLogPrefix: "Notify audio"
                    )
                }
            }
        }
    }

    private func playServerAudioIfPresent(_ path: String?, client: BackendSessionClient, fallbackLogPrefix: String) async {
        guard let path, !path.isEmpty else { return }
        guard let audioURL = makeServerAudioURL(path: path, client: client) else {
            appendLog("\(fallbackLogPrefix) URL was invalid: \(path)")
            return
        }

        do {
            let (audioData, response) = try await URLSession.shared.data(from: audioURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                appendLog("\(fallbackLogPrefix) fetch failed")
                return
            }
            tonePlayer.playAudioData(audioData)
        } catch {
            appendLog("\(fallbackLogPrefix) fetch failed: \(error.localizedDescription)")
        }
    }

    private func makeServerAudioURL(path: String, client: BackendSessionClient) -> URL? {
        if let url = URL(string: path), url.scheme != nil {
            return url
        }
        return URL(string: path, relativeTo: client.serverBaseURL)?.absoluteURL
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
            guard let client = makeSessionClient() else {
                callStateDescription = "Invalid server URL"
                appendLog("Server URL is invalid: \(backendURLString)")
                isTransitioningCallState = false
                return
            }

            do {
                let sid = try await client.registerSession()
                sessionID = sid
                sessionClient = client
                appendLog("Session registered: \(sid)")

                try await audioPipeline.start()
                subscribeToServerEvents(client: client, sessionID: sid)
                callStateDescription = "Listening"
                isCallActive = true
                tonePlayer.playConnectTone()
            } catch {
                callStateDescription = "Audio start failed"
                appendLog("Failed to start: \(error.localizedDescription)")
                if let sid = sessionID {
                    await client.deregisterSession(sid)
                }
                sessionID = nil
                sessionClient = nil
            }

            isTransitioningCallState = false
        }
    }

    func callKitControllerDidDeactivateAudio(_ controller: CallKitController) {
        Task {
            eventTask?.cancel()
            eventTask = nil

            await audioPipeline.stop()

            if let client = sessionClient, let sid = sessionID {
                await client.deregisterSession(sid)
            }
            sessionID = nil
            sessionClient = nil

            callStateDescription = "Idle"
            isCallActive = false
            tonePlayer.playDisconnectTone()
            isTransitioningCallState = false
        }
    }

    func callKitController(_ controller: CallKitController, didFail message: String) {
        callStateDescription = "Call failed"
        isCallActive = false
        isTransitioningCallState = false
        appendLog("CallKit error: \(message)")
    }
}

extension CallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidCaptureSegment(_ segment: CapturedSpeechSegment) {
        guard let client = sessionClient, let sid = sessionID else { return }
        Task {
            do {
                let response = try await client.uploadUtterance(sessionID: sid, audioWAV: segment.wavData)
                lastServerTranscript = response.text
                appendLog("Transcript: \(response.text)")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
