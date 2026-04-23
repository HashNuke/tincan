#if os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class CallSessionViewModel: ObservableObject {
    private static let inputLevelHistoryLength = 14

    @Published var callStateDescription = "Idle"
    @Published var lastServerTranscript = ""
    @Published var logLines: [String] = []
    @Published var isCallActive = false
    @Published var isTransitioningCallState = false
    @Published private(set) var transitionPhase: TincanCallTransitionPhase = .none
    @Published private(set) var callStartedAt: Date?
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = true
    @Published private(set) var inputLevelHistory = Array(repeating: 0.0, count: inputLevelHistoryLength)

    private let callKitController = CallKitController()
    private let audioPipeline = AudioTurnPipeline()
    private let tonePlayer = CallTonePlayer.shared
    private let serverSettings: ServerConnectionStore

    private var sessionClient: BackendSessionClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var muteGeneration: UInt64 = 0
    private var isTransportRecovering = false
    private var shouldPlayDisconnectToneOnDeactivate = true

    init(serverSettings: ServerConnectionStore) {
        self.serverSettings = serverSettings
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
        transitionPhase = .starting
        callStartedAt = nil
        tonePlayer.startOutgoingRing()
        callStateDescription = "Checking mic"
        Task {
            appendLog("Requesting microphone access")
            let hasPermission = await requestMicrophonePermission()
            guard hasPermission else {
                tonePlayer.stopOutgoingRing()
                appendLog("Microphone permission was denied")
                callStateDescription = "Microphone permission required"
                isTransitioningCallState = false
                transitionPhase = .none
                return
            }

            callStateDescription = "Starting"
            appendLog("Requesting system call start")
            callKitController.startCall()
        }
    }

    func endCall() {
        guard isCallActive || isTransitioningCallState else { return }
        isTransitioningCallState = true
        transitionPhase = isCallActive ? .ending : .starting
        tonePlayer.stopOutgoingRing()
        muteGeneration &+= 1
        callStateDescription = isCallActive ? "Ending" : "Canceling"
        appendLog(isCallActive ? "Ending call" : "Canceling call startup")
        callKitController.endCall()
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
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

    private func makeSessionClient() -> BackendSessionClient? {
        guard let url = serverSettings.serverBaseURL else { return nil }
        return BackendSessionClient(serverBaseURL: url)
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
            callStateDescription = "Listening"
            appendLog(reason)
        case .disconnected(let reason):
            appendLog("Call disconnected: \(reason)")
            guard isCallActive || isTransitioningCallState || sessionClient != nil else { return }
            isTransportRecovering = false
            shouldPlayDisconnectToneOnDeactivate = false
            tonePlayer.stopOutgoingRing()
            tonePlayer.playDisconnectTone()
            callStateDescription = "Call lost"
            isTransitioningCallState = true
            transitionPhase = .ending
            callKitController.endCall()
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

        do {
            try applyPreferredSpeakerRoute()
            appendLog(isSpeakerEnabled ? "Routed call audio to speaker" : "Routed call audio to receiver")
        } catch {
            isSpeakerEnabled.toggle()
            appendLog("Failed to switch audio output: \(error.localizedDescription)")
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
            guard let client = makeSessionClient() else {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Invalid server URL"
                appendLog("Server connection is incomplete")
                isTransitioningCallState = false
                transitionPhase = .none
                return
            }

            var startupPhase = "session registration"
            do {
                callStateDescription = "Connecting"
                appendLog("Registering call session with \(client.serverBaseURL.absoluteString)")
                let sid = try await client.registerSession()
                sessionID = sid
                sessionClient = client
                client.setRemoteAudioEnabled(true)
                try applyPreferredSpeakerRoute()
                isTransportRecovering = false
                shouldPlayDisconnectToneOnDeactivate = true
                appendLog("Session registered: \(sid)")

                startupPhase = "microphone capture"
                callStateDescription = "Starting mic"
                appendLog("Starting microphone capture")
                try await audioPipeline.start()
                await audioPipeline.setCaptureEnabled(!isMuted)
                subscribeToServerEvents(client: client, sessionID: sid)
                callStateDescription = "Listening"
                await tonePlayer.playConnectToneWhenOutgoingRingMinimumElapsed()
                guard sessionID == sid, sessionClient === client else { return }
                isCallActive = true
                callStartedAt = Date()
            } catch {
                tonePlayer.stopOutgoingRing()
                callStateDescription = "Audio start failed"
                appendLog("Failed during \(startupPhase): \(error.localizedDescription)")
                if let sid = sessionID {
                    await client.deregisterSession(sid)
                }
                sessionID = nil
                sessionClient = nil
                isTransportRecovering = false
            }

            transitionPhase = .none
            isTransitioningCallState = false
        }
    }

    func callKitControllerDidDeactivateAudio(_ controller: CallKitController) {
        Task {
            muteGeneration &+= 1
            eventTask?.cancel()
            eventTask = nil

            await audioPipeline.stop()

            if let client = sessionClient, let sid = sessionID {
                await client.deregisterSession(sid)
            }
            sessionID = nil
            sessionClient = nil
            isTransportRecovering = false

            callStateDescription = "Idle"
            isCallActive = false
            callStartedAt = nil
            resetInputLevels()
            if shouldPlayDisconnectToneOnDeactivate {
                tonePlayer.playDisconnectTone()
            }
            shouldPlayDisconnectToneOnDeactivate = true
            transitionPhase = .none
            isTransitioningCallState = false
        }
    }

    func callKitController(_ controller: CallKitController, didFail message: String) {
        tonePlayer.stopOutgoingRing()
        callStateDescription = "Call failed"
        isCallActive = false
        callStartedAt = nil
        resetInputLevels()
        transitionPhase = .none
        isTransitioningCallState = false
        isTransportRecovering = false
        shouldPlayDisconnectToneOnDeactivate = true
        muteGeneration &+= 1
        appendLog("CallKit error: \(message)")
    }
}

extension CallSessionViewModel: AudioTurnPipelineOutput {
    func audioTurnPipelineDidLog(_ message: String) {
        appendLog(message)
    }

    func audioTurnPipelineDidUpdateInputLevel(_ level: Float) {
        pushInputLevel(level)
    }

    func audioTurnPipelineDidCaptureSegment(_ segment: CapturedSpeechSegment) {
        guard let client = sessionClient, let sid = sessionID else { return }
        guard !isMuted else {
            appendLog("Ignored speech segment while muted")
            return
        }
        let muteSnapshot = muteGeneration
        Task {
            guard self.shouldUploadCapturedAudio(sessionID: sid, muteSnapshot: muteSnapshot) else {
                self.appendLog("Dropped a pending speech segment because mute changed")
                return
            }
            do {
                let response = try await client.uploadUtterance(sessionID: sid, audioWAV: segment.wavData)
                guard self.shouldAcceptCapturedAudioResponse(sessionID: sid, muteSnapshot: muteSnapshot) else {
                    return
                }
                lastServerTranscript = response.text
                appendLog("Transcript: \(response.text)")
            } catch {
                appendLog("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}

private extension CallSessionViewModel {
    func applyPreferredSpeakerRoute() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        if isSpeakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.overrideOutputAudioPort(isSpeakerEnabled ? .speaker : .none)
    }

    func shouldUploadCapturedAudio(sessionID: String, muteSnapshot: UInt64) -> Bool {
        !isMuted && sessionID == self.sessionID && muteSnapshot == muteGeneration
    }

    func shouldAcceptCapturedAudioResponse(sessionID: String, muteSnapshot: UInt64) -> Bool {
        sessionID == self.sessionID && muteSnapshot == muteGeneration
    }
}
#endif
