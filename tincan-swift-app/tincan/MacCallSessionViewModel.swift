#if os(macOS)
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class MacCallSessionViewModel: ObservableObject {
    @Published private(set) var callStateDescription = "Idle"
    @Published private(set) var identityStatusDescription = "Identity not ready"
    @Published private(set) var ownerProfileDescription = "No current-user voice enrolled"
    @Published private(set) var lastChallengeTranscript = ""
    @Published private(set) var lastServerTranscript = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isCallActive = false
    @Published private(set) var isTransitioningCallState = false

    private let audioPipeline = AudioTurnPipeline()
    private let identityManager = SpeakerIdentityManager()
    private let promptSpeaker = LocalPromptSpeaker()
    private let tonePlayer = CallTonePlayer.shared

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var currentChallengePrompt: String?
    private var ignoreCapturedSegmentsUntil = Date.distantPast

    init() {
        audioPipeline.setDelegate(self)
        appendLog("Ready")
        Task {
            let status = await identityManager.currentStatus()
            applyIdentityStatus(status)
        }
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

            let hasSpeechPermission = await requestSpeechPermission()
            await identityManager.setSpeechRecognitionAuthorized(hasSpeechPermission)

            let hasOwnerProfile = await identityManager.hasOwnerProfile()
            if !hasSpeechPermission && !hasOwnerProfile {
                callStateDescription = "Speech recognition permission required"
                identityStatusDescription = "Speaker identification requires Speech Recognition permission."
                appendLog("Speech recognition permission is required when no current-user voice profile exists")
                isTransitioningCallState = false
                return
            }

            guard let serverURL = URL(string: BackendConnectionConfig.loopbackServerBaseURLString) else {
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

                let identityStatus = try await identityManager.prepare()
                applyIdentityStatus(identityStatus)
                try await audioPipeline.start()

                subscribeToServerEvents(client: client, sessionID: sid)

                callStateDescription = "Connected"
                isCallActive = true
                tonePlayer.playConnectTone()

                if !hasOwnerProfile {
                    let challengeStatus = await identityManager.beginIdentification()
                    applyIdentityStatus(challengeStatus)
                    appendLog("Speaker identification required before audio will be sent")
                }
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

    func beginSpeakerIdentification() {
        guard isCallActive else {
            appendLog("Start a call before running speaker identification")
            return
        }

        Task {
            let status = await identityManager.beginIdentification()
            applyIdentityStatus(status)
            appendLog("Speaker identification prompt is active")
        }
    }

    func resetSpeakerProfile() {
        Task {
            do {
                let status = try await identityManager.resetOwnerProfile()
                applyIdentityStatus(status)
                appendLog("Current-user voice profile was reset")
            } catch {
                appendLog("Failed to reset current-user voice profile: \(error.localizedDescription)")
            }
        }
    }

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        Task {
            eventTask?.cancel()
            eventTask = nil
            promptTask?.cancel()
            promptTask = nil

            await audioPipeline.stop()
            if let client = sessionClient, let sid = sessionID {
                await client.deregisterSession(sid)
            }
            sessionID = nil
            sessionClient = nil
            currentChallengePrompt = nil
            ignoreCapturedSegmentsUntil = Date.distantPast

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

    private func requestSpeechPermission() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await LocalSpeechRecognizer().requestAuthorization()
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

    private func applyIdentityStatus(_ status: SpeakerIdentityStatus) {
        identityStatusDescription = status.description
        ownerProfileDescription = status.ownerProfileName.map { "Current user: \($0)" }
            ?? "No current-user voice enrolled"
        lastChallengeTranscript = status.lastChallengeTranscript ?? ""

        let previousChallengePrompt = currentChallengePrompt
        currentChallengePrompt = status.challengePrompt

        guard let challengePrompt = status.challengePrompt, challengePrompt != previousChallengePrompt else {
            return
        }

        speakIdentificationPrompt(challengePrompt)
    }

    private func speakIdentificationPrompt(_ challengePrompt: String) {
        promptTask?.cancel()
        promptTask = Task { @MainActor in
            ignoreCapturedSegmentsUntil = .distantFuture
            appendLog("Speaking local speaker-identification prompt")

            await promptSpeaker.speak(
                "Speaker identification. Please say: \(challengePrompt)"
            )

            ignoreCapturedSegmentsUntil = Date().addingTimeInterval(0.8)
            if currentChallengePrompt == challengePrompt {
                identityStatusDescription = "Waiting for the current speaker to say the spoken identification phrase."
            }
        }
    }
}

extension MacCallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidCaptureSegment(_ segment: CapturedSpeechSegment) {
        guard let client = sessionClient, let sid = sessionID else { return }
        guard Date() >= ignoreCapturedSegmentsUntil else {
            appendLog("Ignored speech captured while tincan was speaking the identification prompt")
            return
        }
        Task {
            let outcome = await identityManager.processSegment(segment)
            applyIdentityStatus(outcome.status)
            appendLog(outcome.logMessage)

            guard let approvedSegment = outcome.segmentApprovedForUpload else {
                return
            }

            do {
                let response = try await client.uploadUtterance(sessionID: sid, audioWAV: approvedSegment.wavData)
                lastServerTranscript = response.text
                appendLog("Transcript: \(response.text)")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
