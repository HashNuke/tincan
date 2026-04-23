#if os(macOS)
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class MacCallSessionViewModel: ObservableObject {
    private static let inputLevelHistoryLength = 14
    fileprivate static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    @Published private(set) var callStateDescription = "Idle"
    @Published private(set) var identityStatusDescription = "Identity not ready"
    @Published private(set) var ownerProfileDescription = "Wake word unavailable"
    @Published private(set) var speakerIdentityPhase: SpeakerIdentityPhase = .unavailable
    @Published private(set) var lastLocalTranscript = ""
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
    private let tonePlayer = CallTonePlayer.shared
    private let serverSettings: ServerConnectionStore
    private let fileLogger = MacCallFileLogger()

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var muteGeneration: UInt64 = 0
    private var isTransportRecovering = false

    init(serverSettings: ServerConnectionStore) {
        self.serverSettings = serverSettings
        audioPipeline.setDelegate(self)
        Task {
            await fileLogger.markSessionBoundary()
        }
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
        tonePlayer.startOutgoingRing()
        callStateDescription = "Starting"
        Task {
            callStateDescription = "Checking mic"
            appendLog("Requesting microphone access")
            let hasPermission = await requestMicrophonePermission()
            guard hasPermission else {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Microphone permission required"
                appendLog("Microphone permission was denied")
                isTransitioningCallState = false
                return
            }

            callStateDescription = "Checking speech"
            appendLog("Checking speech recognition access")
            let hasSpeechPermission = await requestSpeechPermission()
            await identityManager.setSpeechRecognitionAuthorized(hasSpeechPermission)

            if !hasSpeechPermission {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Speech recognition permission required"
                identityStatusDescription = "Wake-word speaker gating requires Speech Recognition permission."
                appendLog("Speech recognition permission is required for wake-word speaker gating")
                isTransitioningCallState = false
                return
            }

            guard let serverURL = serverSettings.serverBaseURL else {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Invalid server URL"
                appendLog("Server connection is incomplete")
                isTransitioningCallState = false
                return
            }

            let client = BackendSessionClient(serverBaseURL: serverURL)
            var startupPhase = "wake-word setup"

            do {
                callStateDescription = "Preparing wake word"
                appendLog("Preparing wake-word speaker gating")
                let identityStatus = try await identityManager.prepare()
                applyIdentityStatus(identityStatus)

                startupPhase = "microphone capture"
                callStateDescription = "Starting mic"
                appendLog("Starting microphone capture")
                try await audioPipeline.start()
                await audioPipeline.setCaptureEnabled(!isMuted)

                startupPhase = "session registration"
                callStateDescription = "Connecting"
                appendLog("Registering call session with \(serverURL.absoluteString)")
                let sid = try await client.registerSession()
                sessionID = sid
                sessionClient = client
                client.setRemoteAudioEnabled(isSpeakerEnabled)
                isTransportRecovering = false
                appendLog("Session registered: \(sid)")

                subscribeToServerEvents(client: client, sessionID: sid)

                callStateDescription = "Connected"
                isCallActive = true
                callStartedAt = Date()
                await tonePlayer.playConnectToneWhenOutgoingRingMinimumElapsed()
                appendLog("Connected")
            } catch {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Call start failed"
                appendLog("Failed during \(startupPhase): \(error.localizedDescription)")
                await audioPipeline.stop()
                if let sid = sessionID {
                    await client.deregisterSession(sid)
                }
                sessionID = nil
                sessionClient = nil
                isTransportRecovering = false
            }

            isTransitioningCallState = false
        }
    }

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        tonePlayer.stopOutgoingRing()
        muteGeneration &+= 1
        callStateDescription = isCallActive ? "Ending" : "Canceling"
        appendLog(isCallActive ? "Ending call" : "Canceling call startup")
        Task {
            eventTask?.cancel()
            eventTask = nil

            await audioPipeline.stop()
            if let client = sessionClient, let sid = sessionID {
                await client.deregisterSession(sid)
            }
            sessionID = nil
            sessionClient = nil
            isTransportRecovering = false

            callStateDescription = "Disconnected"
            isCallActive = false
            callStartedAt = nil
            resetInputLevels()
            tonePlayer.playDisconnectTone()
            isTransitioningCallState = false
        }
    }

    private func subscribeToServerEvents(client: BackendSessionClient, sessionID: String) {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.eventStream(sessionID: sessionID) {
                guard !Task.isCancelled else { break }
                await self.handleServerEvent(event)
            }
        }
    }

    private func handleServerEvent(_ event: BackendSessionClient.ServerEvent) async {
        switch event {
        case .playAudio(let text):
            appendLog("Server: \(text)")
        case .notify(let text, let summaryText):
            appendLog("Notify: \(BackendSessionClient.notificationDisplayText(text: text, summaryText: summaryText))")
        case .transportStatus(let status):
            await handleTransportStatus(status)
        }
    }

    private func handleTransportStatus(_ status: BackendSessionClient.TransportStatus) async {
        switch status {
        case .reconnecting(let reason):
            guard sessionClient != nil else { return }
            if !isTransportRecovering {
                tonePlayer.playProcessingTone()
            }
            isTransportRecovering = true
            callStateDescription = "Reconnecting"
            appendLog(reason)
        case .reconnected(let reason):
            guard sessionClient != nil else { return }
            isTransportRecovering = false
            callStateDescription = "Connected"
            appendLog(reason)
        case .disconnected(let reason):
            await handleUnexpectedTransportDisconnection(reason: reason)
        }
    }

    private func handleUnexpectedTransportDisconnection(reason: String) async {
        guard isCallActive || isTransitioningCallState || sessionClient != nil else { return }

        appendLog("Call disconnected: \(reason)")
        tonePlayer.stopOutgoingRing()
        tonePlayer.playDisconnectTone()
        muteGeneration &+= 1
        isTransportRecovering = false

        eventTask = nil

        await audioPipeline.stop()
        sessionClient = nil
        sessionID = nil

        callStateDescription = "Idle"
        isCallActive = false
        isTransitioningCallState = false
        callStartedAt = nil
        resetInputLevels()
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
        let line = "[\(timestamp)] \(message)"
        logLines.insert(line, at: 0)
        if logLines.count > 40 {
            logLines.removeLast(logLines.count - 40)
        }
        NSLog("mac call: %@", message)
        Task {
            await fileLogger.append(line)
        }
    }

    private func applyIdentityStatus(_ status: SpeakerIdentityStatus) {
        speakerIdentityPhase = status.phase
        identityStatusDescription = status.description
        lastLocalTranscript = status.lastChallengeTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let wakeWord = status.ownerProfileName, !wakeWord.isEmpty {
            if let transcript = status.lastChallengeTranscript, !transcript.isEmpty {
                ownerProfileDescription = "Wake word: \(wakeWord) · Last heard: \(transcript)"
            } else {
                ownerProfileDescription = "Wake word: \(wakeWord)"
            }
        } else {
            ownerProfileDescription = "Wake word unavailable"
        }
    }

    func toggleMute() {
        isMuted.toggle()
        muteGeneration &+= 1
        appendLog(isMuted ? "Muted outgoing audio" : "Resumed outgoing audio")
        let shouldCaptureAudio = !isMuted
        Task {
            await audioPipeline.setCaptureEnabled(shouldCaptureAudio)
        }
    }

    func toggleSpeakerEnabled() {
        isSpeakerEnabled.toggle()
        appendLog(isSpeakerEnabled ? "Enabled tincan audio playback" : "Disabled tincan audio playback")
        sessionClient?.setRemoteAudioEnabled(isSpeakerEnabled)
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
        let muteSnapshot = muteGeneration
        let identityManager = self.identityManager
        Task(priority: .userInitiated) {
            let outcome = await identityManager.processSegment(segment)
            self.applyIdentityStatus(outcome.status)
            self.appendLog(outcome.logMessage)

            guard let approvedSegment = outcome.segmentApprovedForUpload else {
                return
            }
            guard self.shouldUploadCapturedAudio(sessionID: sid, muteSnapshot: muteSnapshot) else {
                self.appendLog("Dropped a pending speech segment because mute changed")
                return
            }

            do {
                self.appendLog(
                    "Uploading \(approvedSegment.duration.formatted(.number.precision(.fractionLength(2))))s approved speech segment"
                )
                let response = try await self.uploadApprovedSegment(approvedSegment, with: client, sessionID: sid)
                guard self.shouldAcceptCapturedAudioResponse(sessionID: sid, muteSnapshot: muteSnapshot) else {
                    return
                }
                self.lastServerTranscript = response.text
                self.appendLog("Transcript: \(response.text)")
            } catch {
                self.appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}

private extension MacCallSessionViewModel {
    func shouldUploadCapturedAudio(sessionID: String, muteSnapshot: UInt64) -> Bool {
        !isMuted && sessionID == self.sessionID && muteSnapshot == muteGeneration
    }

    func shouldAcceptCapturedAudioResponse(sessionID: String, muteSnapshot: UInt64) -> Bool {
        sessionID == self.sessionID && muteSnapshot == muteGeneration
    }
}

private actor MacCallFileLogger {
    func markSessionBoundary() {
        appendRawLine(
            "\n[\(MacCallSessionViewModel.logTimestampFormatter.string(from: Date()))] ----- mac call session -----"
        )
    }

    func append(_ line: String) {
        appendRawLine("[\(MacCallSessionViewModel.logTimestampFormatter.string(from: Date()))] \(line)")
    }

    private func appendRawLine(_ line: String) {
        let url = AppPaths.macCallLogURL
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let data = "\(line)\n".data(using: .utf8) else {
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Failed writing mac call log entry: %@", error.localizedDescription)
        }
    }
}
#endif
