#if os(macOS)
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class MacCallSessionViewModel: ObservableObject {
    private static let inputLevelHistoryLength = 14

    @Published private(set) var callStateDescription = "Idle"
    @Published private(set) var identityStatusDescription = "Identity not ready"
    @Published private(set) var ownerProfileDescription = "No current-user voice enrolled"
    @Published private(set) var speakerIdentityPhase: SpeakerIdentityPhase = .unavailable
    @Published private(set) var lastChallengeTranscript = ""
    @Published private(set) var lastServerTranscript = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isCallActive = false
    @Published private(set) var isTransitioningCallState = false
    @Published private(set) var callStartedAt: Date?
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = true
    @Published private(set) var inputLevelHistory = Array(repeating: 0.0, count: inputLevelHistoryLength)

    private let audioPipeline = AudioTurnPipeline()
    private let identityManager = SpeakerIdentityManager()
    private let promptSpeaker = LocalPromptSpeaker()
    private let tonePlayer = CallTonePlayer.shared
    private let serverSettings: ServerConnectionStore

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var currentChallengePrompt: String?
    private var ignoreCapturedSegmentsUntil = Date.distantPast

    init(serverSettings: ServerConnectionStore) {
        self.serverSettings = serverSettings
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
        callStateDescription = "Starting"
        Task {
            callStateDescription = "Checking mic"
            appendLog("Requesting microphone access")
            let hasPermission = await requestMicrophonePermission()
            guard hasPermission else {
                callStateDescription = "Microphone permission required"
                appendLog("Microphone permission was denied")
                isTransitioningCallState = false
                return
            }

            callStateDescription = "Checking speech"
            appendLog("Checking speech recognition access")
            let hasSpeechPermission = await requestSpeechPermission()
            await identityManager.setSpeechRecognitionAuthorized(hasSpeechPermission)

            callStateDescription = "Checking profile"
            appendLog("Checking current-user voice profile")
            let hasOwnerProfile = await identityManager.hasOwnerProfile()
            if !hasSpeechPermission && !hasOwnerProfile {
                callStateDescription = "Speech recognition permission required"
                identityStatusDescription = "Speaker identification requires Speech Recognition permission."
                appendLog("Speech recognition permission is required when no current-user voice profile exists")
                isTransitioningCallState = false
                return
            }

            guard let serverURL = serverSettings.serverBaseURL else {
                callStateDescription = "Invalid server URL"
                appendLog("Server connection is incomplete")
                isTransitioningCallState = false
                return
            }

            let client = BackendSessionClient(serverBaseURL: serverURL)
            var startupPhase = "session registration"

            do {
                callStateDescription = "Connecting"
                appendLog("Registering call session with \(serverURL.absoluteString)")
                let sid = try await client.registerSession()
                sessionID = sid
                sessionClient = client
                appendLog("Session registered: \(sid)")

                startupPhase = "speaker identification setup"
                callStateDescription = "Preparing identity"
                appendLog("Preparing speaker identification")
                let identityStatus = try await identityManager.prepare()
                applyIdentityStatus(identityStatus)
                startupPhase = "microphone capture"
                callStateDescription = "Starting mic"
                appendLog("Starting microphone capture")
                try await audioPipeline.start()

                subscribeToServerEvents(client: client, sessionID: sid)

                callStateDescription = "Connected"
                isCallActive = true
                callStartedAt = Date()
                tonePlayer.playConnectTone()

                if !hasOwnerProfile {
                    let challengeStatus = await identityManager.beginIdentification()
                    applyIdentityStatus(challengeStatus)
                    appendLog("Speaker identification required before audio will be sent")
                }
            } catch {
                callStateDescription = "Call start failed"
                appendLog("Failed during \(startupPhase): \(error.localizedDescription)")
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
        callStateDescription = isCallActive ? "Ending" : "Canceling"
        appendLog(isCallActive ? "Ending call" : "Canceling call startup")
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
            callStartedAt = nil
            resetInputLevels()
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
        guard isSpeakerEnabled else {
            appendLog("Skipped playback while audio output is muted")
            return
        }
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

    private func uploadApprovedSegment(
        _ segment: CapturedSpeechSegment,
        with client: BackendSessionClient,
        sessionID: String
    ) async throws -> BackendSessionClient.UtteranceResponse {
        try await client.uploadUtterance(sessionID: sessionID, audioWAV: segment.wavData)
    }

    private func pushInputLevel(_ level: Float) {
        let clampedLevel = max(0, min(1, Double(level)))
        if inputLevelHistory.count == Self.inputLevelHistoryLength {
            inputLevelHistory.removeFirst()
        }
        inputLevelHistory.append(clampedLevel)
    }

    private func resetInputLevels() {
        inputLevelHistory = Array(repeating: 0.0, count: Self.inputLevelHistoryLength)
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.insert("[\(timestamp)] \(message)", at: 0)
        if logLines.count > 40 {
            logLines.removeLast(logLines.count - 40)
        }
    }

    private func applyIdentityStatus(_ status: SpeakerIdentityStatus) {
        speakerIdentityPhase = status.phase
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
        ignoreCapturedSegmentsUntil = .distantFuture
        appendLog("Speaking local speaker-identification prompt")
        promptTask = Task { @MainActor in
            await promptSpeaker.speak(
                "Speaker identification. Please say: \(challengePrompt)"
            )

            ignoreCapturedSegmentsUntil = Date().addingTimeInterval(0.8)
            if currentChallengePrompt == challengePrompt {
                identityStatusDescription = "Waiting for the current speaker to say the spoken identification phrase."
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        appendLog(isMuted ? "Muted outgoing audio" : "Resumed outgoing audio")
    }

    func toggleSpeakerEnabled() {
        isSpeakerEnabled.toggle()
        appendLog(isSpeakerEnabled ? "Enabled tincan audio playback" : "Disabled tincan audio playback")
    }
}

extension MacCallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidUpdateInputLevel(_ level: Float) {
        pushInputLevel(level)
    }

    func audioTurnPipelineDidCaptureSegment(_ segment: CapturedSpeechSegment) {
        guard let client = sessionClient, let sid = sessionID else { return }
        appendLog(
            "Captured \(segment.duration.formatted(.number.precision(.fractionLength(2))))s speech segment"
        )
        guard !isMuted else {
            appendLog("Ignored speech segment while muted")
            return
        }
        guard !promptSpeaker.isSpeaking, Date() >= ignoreCapturedSegmentsUntil else {
            appendLog("Ignored speech captured while tincan was speaking the identification prompt")
            return
        }
        let identityManager = self.identityManager
        Task(priority: .userInitiated) {
            let outcome = await identityManager.processSegment(segment)
            self.applyIdentityStatus(outcome.status)
            self.appendLog(outcome.logMessage)

            guard let approvedSegment = outcome.segmentApprovedForUpload else {
                return
            }

            do {
                self.appendLog(
                    "Uploading \(approvedSegment.duration.formatted(.number.precision(.fractionLength(2))))s approved speech segment"
                )
                let response = try await self.uploadApprovedSegment(approvedSegment, with: client, sessionID: sid)
                self.lastServerTranscript = response.text
                self.appendLog("Transcript: \(response.text)")
            } catch {
                self.appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
