import Foundation
import WebRTC

@MainActor
final class BackendSessionClient: NSObject {
    let serverBaseURL: URL

    enum SessionError: LocalizedError {
        case invalidSessionEndpoint
        case missingLocalOfferDescription
        case offerCreationReturnedNoDescription
        case iceGatheringTimedOut(TimeInterval)
        case dataChannelOpenTimedOut(TimeInterval)
        case unexpectedHTTPResponse(context: String)
        case httpFailure(context: String, statusCode: Int, body: String?)
        case utteranceRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidSessionEndpoint:
                return "The WebRTC session endpoint URL is invalid."
            case .missingLocalOfferDescription:
                return "The WebRTC offer was created, but the finalized local description was unavailable."
            case .offerCreationReturnedNoDescription:
                return "WebRTC did not return an SDP offer."
            case .iceGatheringTimedOut(let timeout):
                return "Timed out waiting \(Int(timeout))s for ICE gathering to finish."
            case .dataChannelOpenTimedOut(let timeout):
                return "Timed out waiting \(Int(timeout))s for the WebRTC data channel to open."
            case .unexpectedHTTPResponse(let context):
                return "\(context) returned a non-HTTP response."
            case .httpFailure(let context, let statusCode, let body):
                if let body, !body.isEmpty {
                    return "\(context) failed with HTTP \(statusCode): \(body)"
                }
                return "\(context) failed with HTTP \(statusCode)."
            case .utteranceRejected(let message):
                return message
            }
        }
    }

    struct RegisterResponse: Decodable {
        let sessionId: String
        let answerSDP: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case answerSDP = "answer_sdp"
        }
    }

    struct UtteranceResponse: Decodable {
        let text: String
    }

    enum ServerEvent {
        case playAudio(text: String)
        case notify(text: String, summaryText: String?)
        case transportStatus(TransportStatus)
    }

    enum TransportStatus {
        case reconnecting(reason: String)
        case reconnected(reason: String)
        case disconnected(reason: String)
    }

    private struct OutboundUtteranceMessage: Encodable {
        let type = "utterance"
        let requestId: String
        let contentType: String
        let audioBase64: String

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case contentType = "content_type"
            case audioBase64 = "audio_base64"
        }
    }

    private struct OutboundPingMessage: Encodable {
        let type = "ping"
        let clientTime: String

        enum CodingKeys: String, CodingKey {
            case type
            case clientTime = "client_time"
        }
    }

    private struct InboundUtteranceResult: Decodable {
        let type: String
        let requestId: String?
        let text: String
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case text
            case error
        }
    }

    private struct InboundPongMessage: Decodable {
        let type: String
        let serverTime: String?

        enum CodingKeys: String, CodingKey {
            case type
            case serverTime = "server_time"
        }
    }

    private struct WebRTCConfigResponse: Decodable {
        let iceServers: [WebRTCIceServerResponse]

        enum CodingKeys: String, CodingKey {
            case iceServers = "ice_servers"
        }
    }

    private struct WebRTCIceServerResponse: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    private struct ConnectionBootstrap {
        let peerConnection: RTCPeerConnection
        let dataChannel: RTCDataChannel
        let sessionID: String
    }

    private static let disconnectGraceInterval: TimeInterval = 5
    private static let heartbeatInterval: TimeInterval = 5
    private static let heartbeatTimeout: TimeInterval = 20
    private static let recoveryAttemptBackoff: [TimeInterval] = [0, 2, 5, 8, 12]
    private static let recoveryDeadline: TimeInterval = 45

    private let peerConnectionFactory = WebRTCProbe.makePeerConnectionFactory()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var remoteAudioTrack: RTCAudioTrack?
    private var remoteAudioEnabled = true
    private var sessionID: String?
    private var eventContinuation: AsyncStream<ServerEvent>.Continuation?
    private var pendingUtteranceContinuations: [String: CheckedContinuation<UtteranceResponse, Error>] = [:]
    private var isFinishingSession = false
    private var manualShutdownRequested = false
    private var isTransportDegraded = false
    private var lastServerActivityAt = Date.distantPast
    private var heartbeatTask: Task<Void, Never>?
    private var disconnectGraceTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var transportGeneration: UInt64 = 0

    init(serverBaseURL: URL) {
        self.serverBaseURL = serverBaseURL
    }

    nonisolated static func notificationDisplayText(text: String, summaryText: String?) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummaryText = summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedSummaryText.isEmpty {
            return trimmedSummaryText
        }

        return trimmedText
    }

    nonisolated static func responseBodySummary(from data: Data) -> String? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        let collapsedWhitespace = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        if collapsedWhitespace.count <= 240 {
            return collapsedWhitespace
        }

        return "\(collapsedWhitespace.prefix(237))..."
    }

    nonisolated static func validatedSessionDescriptionSDP(_ sdp: String?) -> String? {
        guard let sdp, !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sdp
    }

    func registerSession() async throws -> String {
        if let sessionID {
            return sessionID
        }

        manualShutdownRequested = false

        do {
            let bootstrap = try await establishNewSession()
            installBootstrap(bootstrap)

            if bootstrap.dataChannel.readyState != .open {
                try await waitForOpenDataChannel(
                    timeout: 10,
                    expectedDataChannel: bootstrap.dataChannel
                )
            }

            return bootstrap.sessionID
        } catch {
            finishSession(error: error)
            throw error
        }
    }

    func deregisterSession(_ sessionID: String) async {
        manualShutdownRequested = true
        cancelDisconnectGrace()
        cancelRecovery()

        let activeSessionID = self.sessionID ?? sessionID
        if let url = URL(string: "webrtc/session/\(activeSessionID)", relativeTo: serverBaseURL) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }

        finishSession(error: nil)
    }

    func uploadUtterance(sessionID _: String, audioWAV: Data) async throws -> UtteranceResponse {
        guard self.sessionID != nil, let dataChannel, dataChannel.readyState == .open else {
            throw URLError(.networkConnectionLost)
        }

        let requestId = UUID().uuidString
        let payload = OutboundUtteranceMessage(
            requestId: requestId,
            contentType: "audio/wav",
            audioBase64: audioWAV.base64EncodedString()
        )
        let payloadData = try JSONEncoder().encode(payload)
        let buffer = RTCDataBuffer(data: payloadData, isBinary: false)

        return try await withCheckedThrowingContinuation { continuation in
            pendingUtteranceContinuations[requestId] = continuation
            guard dataChannel.sendData(buffer) else {
                pendingUtteranceContinuations.removeValue(forKey: requestId)
                continuation.resume(throwing: URLError(.cannotWriteToFile))
                return
            }
        }
    }

    func eventStream(sessionID _: String) -> AsyncStream<ServerEvent> {
        AsyncStream { continuation in
            eventContinuation?.finish()
            eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let strongSelf = self else { return }
                Task { @MainActor in
                    strongSelf.eventContinuation = nil
                }
            }
        }
    }

    private func establishNewSession() async throws -> ConnectionBootstrap {
        let configuration = await makePeerConnectionConfiguration()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = peerConnectionFactory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw URLError(.cannotCreateFile)
        }
        let audioTransceiverInit = RTCRtpTransceiverInit()
        audioTransceiverInit.direction = .recvOnly
        guard peerConnection.addTransceiver(of: .audio, init: audioTransceiverInit) != nil else {
            peerConnection.delegate = nil
            peerConnection.close()
            throw URLError(.cannotCreateFile)
        }
        let dataChannelConfig = RTCDataChannelConfiguration()
        guard let dataChannel = peerConnection.dataChannel(
            forLabel: "tincan",
            configuration: dataChannelConfig
        ) else {
            peerConnection.delegate = nil
            peerConnection.close()
            throw URLError(.cannotCreateFile)
        }
        dataChannel.delegate = self

        do {
            let offer = try await createOffer(on: peerConnection, constraints: constraints)
            try await setLocalDescription(offer, on: peerConnection)
            try await waitForIceGatheringComplete(on: peerConnection, timeout: 5)

            guard let finalizedOffer = Self.validatedSessionDescriptionSDP(peerConnection.localDescription?.sdp) else {
                throw SessionError.missingLocalOfferDescription
            }

            let response = try await exchangeOffer(offerSDP: finalizedOffer)
            let answer = RTCSessionDescription(type: .answer, sdp: response.answerSDP)
            try await setRemoteDescription(answer, on: peerConnection)

            return ConnectionBootstrap(
                peerConnection: peerConnection,
                dataChannel: dataChannel,
                sessionID: response.sessionId
            )
        } catch {
            dataChannel.delegate = nil
            peerConnection.delegate = nil
            dataChannel.close()
            peerConnection.close()
            throw error
        }
    }

    private func installBootstrap(_ bootstrap: ConnectionBootstrap) {
        closeTransport()

        transportGeneration &+= 1
        peerConnection = bootstrap.peerConnection
        dataChannel = bootstrap.dataChannel
        sessionID = bootstrap.sessionID
        remoteAudioTrack = nil
        isTransportDegraded = false
        touchServerActivity()
        startHeartbeatLoop(for: transportGeneration)
    }

    private func exchangeOffer(offerSDP: String) async throws -> RegisterResponse {
        guard let url = URL(string: "webrtc/session", relativeTo: serverBaseURL) else {
            throw SessionError.invalidSessionEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["offer_sdp": offerSDP])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SessionError.unexpectedHTTPResponse(context: "Session registration")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionError.httpFailure(
                context: "Session registration",
                statusCode: http.statusCode,
                body: Self.responseBodySummary(from: data)
            )
        }

        do {
            return try JSONDecoder().decode(RegisterResponse.self, from: data)
        } catch {
            throw SessionError.httpFailure(
                context: "Session registration returned invalid JSON",
                statusCode: http.statusCode,
                body: Self.responseBodySummary(from: data)
            )
        }
    }

    private func exchangeRestartOffer(offerSDP: String, sessionID: String) async throws -> RegisterResponse {
        guard let url = URL(string: "webrtc/session/\(sessionID)/restart", relativeTo: serverBaseURL) else {
            throw SessionError.invalidSessionEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["offer_sdp": offerSDP])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SessionError.unexpectedHTTPResponse(context: "Session restart")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionError.httpFailure(
                context: "Session restart",
                statusCode: http.statusCode,
                body: Self.responseBodySummary(from: data)
            )
        }

        do {
            return try JSONDecoder().decode(RegisterResponse.self, from: data)
        } catch {
            throw SessionError.httpFailure(
                context: "Session restart returned invalid JSON",
                statusCode: http.statusCode,
                body: Self.responseBodySummary(from: data)
            )
        }
    }

    private func fetchWebRTCConfiguration() async -> WebRTCConfigResponse? {
        guard let url = URL(string: "webrtc/config", relativeTo: serverBaseURL) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(WebRTCConfigResponse.self, from: data)
        } catch {
            return nil
        }
    }

    private func makePeerConnectionConfiguration() async -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan

        if let remoteConfig = await fetchWebRTCConfiguration() {
            configuration.iceServers = remoteConfig.iceServers.compactMap { server in
                guard !server.urls.isEmpty else { return nil }
                return RTCIceServer(
                    urlStrings: server.urls,
                    username: server.username ?? "",
                    credential: server.credential ?? ""
                )
            }
        }

        return configuration
    }

    private func waitForIceGatheringComplete(
        on peerConnection: RTCPeerConnection,
        timeout: TimeInterval
    ) async throws {
        if peerConnection.iceGatheringState == .complete {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if peerConnection.iceGatheringState == .complete {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw SessionError.iceGatheringTimedOut(timeout)
    }

    private func waitForOpenDataChannel(
        timeout: TimeInterval,
        expectedDataChannel: RTCDataChannel
    ) async throws {
        if expectedDataChannel.readyState == .open {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard dataChannel === expectedDataChannel else {
                throw URLError(.networkConnectionLost)
            }

            switch expectedDataChannel.readyState {
            case .open:
                return
            case .closing, .closed:
                throw URLError(.networkConnectionLost)
            case .connecting:
                break
            @unknown default:
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw SessionError.dataChannelOpenTimedOut(timeout)
    }

    private func createOffer(
        on peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: SessionError.offerCreationReturnedNoDescription)
                    return
                }
                continuation.resume(returning: sdp)
            }
        }
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemoteDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func startHeartbeatLoop(for generation: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000)
                )

                guard self.transportGeneration == generation else { return }
                guard !self.manualShutdownRequested, self.sessionID != nil else { return }
                guard let dataChannel = self.dataChannel else { return }

                if Date().timeIntervalSince(self.lastServerActivityAt) > Self.heartbeatTimeout {
                    self.beginTransportDegradation(reason: "WebRTC heartbeat timed out")
                    self.startRecovery(reason: "WebRTC heartbeat timed out", preferICERestart: true)
                    return
                }

                guard dataChannel.readyState == .open else {
                    continue
                }

                do {
                    let payload = try JSONEncoder().encode(
                        OutboundPingMessage(
                            clientTime: ISO8601DateFormatter().string(from: Date())
                        )
                    )
                    let buffer = RTCDataBuffer(data: payload, isBinary: false)
                    guard dataChannel.sendData(buffer) else {
                        self.beginTransportDegradation(reason: "WebRTC heartbeat send failed")
                        self.startRecovery(reason: "WebRTC heartbeat send failed", preferICERestart: true)
                        return
                    }
                } catch {
                    self.beginTransportDegradation(reason: "WebRTC heartbeat encode failed")
                    self.startRecovery(reason: error.localizedDescription, preferICERestart: true)
                    return
                }
            }
        }
    }

    private func beginTransportDegradation(reason: String) {
        guard sessionID != nil, !manualShutdownRequested else { return }
        if isTransportDegraded {
            return
        }

        isTransportDegraded = true
        eventContinuation?.yield(.transportStatus(.reconnecting(reason: reason)))
    }

    private func markTransportRecovered(reason: String) {
        guard isTransportDegraded else { return }
        isTransportDegraded = false
        cancelDisconnectGrace()
        touchServerActivity()
        eventContinuation?.yield(.transportStatus(.reconnected(reason: reason)))
    }

    private func startRecovery(reason: String, preferICERestart: Bool) {
        guard !manualShutdownRequested, !isFinishingSession else { return }
        guard recoveryTask == nil else { return }

        failPendingUtterances(error: URLError(.networkConnectionLost))
        cancelDisconnectGrace()

        let recoveryStartedAt = Date()
        let generation = transportGeneration
        let activeSessionID = sessionID
        let activePeerConnection = peerConnection

        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recoveryTask = nil
            }

            if preferICERestart,
               let activeSessionID,
               let activePeerConnection,
               self.transportGeneration == generation,
               !self.manualShutdownRequested
            {
                do {
                    try await self.performICERestart(
                        peerConnection: activePeerConnection,
                        sessionID: activeSessionID
                    )
                    if self.transportGeneration == generation {
                        self.markTransportRecovered(reason: "WebRTC connection restored")
                        return
                    }
                } catch {
                    if self.manualShutdownRequested || Task.isCancelled {
                        return
                    }
                }
            }

            var attemptIndex = 0
            while !self.manualShutdownRequested {
                if Date().timeIntervalSince(recoveryStartedAt) > Self.recoveryDeadline {
                    self.eventContinuation?.yield(
                        .transportStatus(
                            .disconnected(reason: "WebRTC connection could not be restored")
                        )
                    )
                    self.finishSession(error: URLError(.networkConnectionLost))
                    return
                }

                do {
                    let bootstrap = try await self.establishNewSession()
                    let staleSessionID = self.sessionID
                    self.installBootstrap(bootstrap)
                    try await self.waitForOpenDataChannel(
                        timeout: 10,
                        expectedDataChannel: bootstrap.dataChannel
                    )
                    self.markTransportRecovered(reason: "Reconnected to tincan-server")

                    if let staleSessionID, staleSessionID != bootstrap.sessionID {
                        Task {
                            await self.bestEffortDeleteSession(staleSessionID)
                        }
                    }
                    return
                } catch {
                    if self.manualShutdownRequested || Task.isCancelled {
                        return
                    }

                    let backoff = Self.recoveryAttemptBackoff[
                        min(attemptIndex, Self.recoveryAttemptBackoff.count - 1)
                    ]
                    attemptIndex += 1
                    if backoff > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    }
                }
            }
        }
    }

    private func performICERestart(
        peerConnection: RTCPeerConnection,
        sessionID: String
    ) async throws {
        let restartConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["IceRestart": "true"]
        )
        let offer = try await createOffer(on: peerConnection, constraints: restartConstraints)
        try await setLocalDescription(offer, on: peerConnection)
        try await waitForIceGatheringComplete(on: peerConnection, timeout: 5)

        guard let finalizedOffer = Self.validatedSessionDescriptionSDP(peerConnection.localDescription?.sdp) else {
            throw SessionError.missingLocalOfferDescription
        }

        let response = try await exchangeRestartOffer(offerSDP: finalizedOffer, sessionID: sessionID)
        let answer = RTCSessionDescription(type: .answer, sdp: response.answerSDP)
        try await setRemoteDescription(answer, on: peerConnection)
        touchServerActivity()
    }

    private func bestEffortDeleteSession(_ sessionID: String) async {
        guard let url = URL(string: "webrtc/session/\(sessionID)", relativeTo: serverBaseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    private func touchServerActivity() {
        lastServerActivityAt = Date()
    }

    private func scheduleDisconnectGrace(reason: String) {
        guard !manualShutdownRequested else { return }

        disconnectGraceTask?.cancel()
        disconnectGraceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(Self.disconnectGraceInterval * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            guard !self.manualShutdownRequested else { return }
            guard self.peerConnection?.connectionState == .disconnected else { return }

            self.beginTransportDegradation(reason: reason)
            self.startRecovery(reason: reason, preferICERestart: true)
        }
    }

    private func cancelDisconnectGrace() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func failPendingUtterances(error: Error) {
        let continuations = pendingUtteranceContinuations
        pendingUtteranceContinuations.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func closeTransport() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let oldDataChannel = dataChannel
        let oldPeerConnection = peerConnection
        dataChannel = nil
        peerConnection = nil
        remoteAudioTrack = nil

        oldDataChannel?.delegate = nil
        oldPeerConnection?.delegate = nil
        oldDataChannel?.close()
        oldPeerConnection?.close()
    }

    private func finishSession(error: Error?) {
        guard !isFinishingSession else { return }
        isFinishingSession = true
        defer {
            isFinishingSession = false
            manualShutdownRequested = false
        }

        cancelDisconnectGrace()
        cancelRecovery()
        failPendingUtterances(error: error ?? URLError(.networkConnectionLost))

        let eventContinuation = self.eventContinuation
        self.eventContinuation = nil

        isTransportDegraded = false
        sessionID = nil
        lastServerActivityAt = .distantPast
        closeTransport()

        eventContinuation?.finish()
    }

    private func handleIncomingData(_ data: Data) {
        touchServerActivity()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "pong" {
            _ = try? JSONDecoder().decode(InboundPongMessage.self, from: data)
            return
        }

        if type == "utterance_result" {
            resolveUtteranceResult(data)
            return
        }

        if let event = parseServerEvent(json) {
            eventContinuation?.yield(event)
        }
    }

    private func resolveUtteranceResult(_ data: Data) {
        guard let result = try? JSONDecoder().decode(InboundUtteranceResult.self, from: data),
              let requestId = result.requestId,
              let continuation = pendingUtteranceContinuations.removeValue(forKey: requestId) else {
            return
        }

        if let error = result.error, !error.isEmpty {
            continuation.resume(throwing: SessionError.utteranceRejected(error))
            return
        }

        continuation.resume(
            returning: UtteranceResponse(
                text: result.text
            )
        )
    }

    private func parseServerEvent(_ json: [String: Any]) -> ServerEvent? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "play_audio":
            let text = json["text"] as? String ?? ""
            return .playAudio(text: text)
        case "notify":
            let text = json["text"] as? String ?? ""
            let summaryText = (json["summary_text"] as? String) ?? (json["detail_text"] as? String)
            return .notify(
                text: text,
                summaryText: summaryText
            )
        default:
            return nil
        }
    }

    func setRemoteAudioEnabled(_ enabled: Bool) {
        remoteAudioEnabled = enabled
        remoteAudioTrack?.isEnabled = enabled
    }
}

extension BackendSessionClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.touchServerActivity()
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            guard !self.manualShutdownRequested else { return }

            switch newState {
            case .connected:
                self.cancelDisconnectGrace()
                self.touchServerActivity()
                self.markTransportRecovered(reason: "WebRTC connection restored")
            case .disconnected:
                self.beginTransportDegradation(reason: "WebRTC connection interrupted")
                self.scheduleDisconnectGrace(reason: "WebRTC connection interrupted")
            case .failed:
                self.beginTransportDegradation(reason: "WebRTC connection failed")
                self.startRecovery(reason: "WebRTC connection failed", preferICERestart: true)
            case .closed:
                self.beginTransportDegradation(reason: "WebRTC connection closed")
                self.startRecovery(reason: "WebRTC connection closed", preferICERestart: false)
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChangeLocalCandidate local: RTCIceCandidate,
        remoteCandidate remote: RTCIceCandidate,
        lastReceivedMs: Int32,
        changeReason: String
    ) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
            self.remoteAudioTrack = track
            track.isEnabled = self.remoteAudioEnabled
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
            guard self.remoteAudioTrack?.trackId == track.trackId else { return }
            self.remoteAudioTrack = nil
        }
    }
}

extension BackendSessionClient: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.dataChannel === dataChannel else { return }
            guard !self.manualShutdownRequested else { return }

            switch dataChannel.readyState {
            case .open:
                self.touchServerActivity()
                self.markTransportRecovered(reason: "WebRTC control channel restored")
            case .closing, .closed:
                self.beginTransportDegradation(reason: "WebRTC control channel closed")
                self.startRecovery(reason: "WebRTC control channel closed", preferICERestart: true)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor [weak self] in
            guard let self, self.dataChannel === dataChannel else { return }
            self.handleIncomingData(buffer.data)
        }
    }
}
