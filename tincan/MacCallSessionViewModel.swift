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
    private let audioPipeline = AudioTurnPipeline()
    private let tonePlayer = CallTonePlayer.shared

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?

    init() {
        linphoneClient.delegate = self
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

            guard let serverURL = URL(string: BackendConnectionConfig.serverBaseURLString) else {
                callStateDescription = "Invalid server URL"
                isTransitioningCallState = false
                return
            }

            let client = BackendSessionClient(serverBaseURL: serverURL)

            do {
                let sid = try await client.registerSession()
                sessionID = sid
                sessionClient = client
                appendLog("Session registered: \(sid)")

                try linphoneClient.start()
                try await audioPipeline.start()

                subscribeToServerEvents(client: client, sessionID: sid)

                callStateDescription = "Connected"
                isCallActive = true
                tonePlayer.playConnectTone()
            } catch {
                callStateDescription = "Call start failed"
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

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        Task {
            eventTask?.cancel()
            eventTask = nil

            await audioPipeline.stop()
            linphoneClient.stop()

            if let client = sessionClient, let sid = sessionID {
                await client.deregisterSession(sid)
            }
            sessionID = nil
            sessionClient = nil

            callStateDescription = "Disconnected"
            isCallActive = false
            tonePlayer.playDisconnectTone()
            isTransitioningCallState = false
        }
    }

    private func subscribeToServerEvents(client: BackendSessionClient, sessionID: String) {
        eventTask = Task {
            for await event in client.eventStream(sessionID: sessionID) {
                switch event {
                case .playAudio(let text, let urlPath):
                    appendLog("Server: \(text)")
                    await playServerAudioIfPresent(urlPath, client: client, fallbackLogPrefix: "Server audio")
                case .notify(let text, let audioURLPath):
                    appendLog("Notify: \(text)")
                    await playServerAudioIfPresent(audioURLPath, client: client, fallbackLogPrefix: "Notify audio")
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

extension MacCallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidProduceSegment(_ data: Data, duration: TimeInterval) {
        guard let client = sessionClient, let sid = sessionID else { return }
        Task {
            do {
                let response = try await client.uploadUtterance(sessionID: sid, audioWAV: data)
                lastServerTranscript = response.text
                appendLog("Transcript: \(response.text)")
                await playServerAudioIfPresent(response.feedbackAudioURL, client: client, fallbackLogPrefix: "Immediate feedback audio")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
