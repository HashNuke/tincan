import Foundation
import WebRTC

@MainActor
final class BackendSessionClient: NSObject {
    let serverBaseURL: URL

    struct NotificationPlaybackChoice: Equatable {
        let text: String
        let audioURLPath: String?
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
        let feedbackAudioURL: String?

        enum CodingKeys: String, CodingKey {
            case text
            case feedbackAudioURL = "feedback_audio_url"
        }
    }

    enum ServerEvent {
        case playAudio(text: String, urlPath: String)
        case notify(text: String, audioURLPath: String?, summaryText: String?, summaryAudioURLPath: String?)
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

    private struct InboundUtteranceResult: Decodable {
        let type: String
        let requestId: String?
        let text: String
        let feedbackAudioURL: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case text
            case feedbackAudioURL = "feedback_audio_url"
            case error
        }
    }

    private let peerConnectionFactory = WebRTCProbe.makePeerConnectionFactory()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var sessionID: String?
    private var eventContinuation: AsyncStream<ServerEvent>.Continuation?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var pendingUtteranceContinuations: [String: CheckedContinuation<UtteranceResponse, Error>] = [:]
    private var isFinishingSession = false

    init(serverBaseURL: URL) {
        self.serverBaseURL = serverBaseURL
    }

    nonisolated static func notificationPlaybackChoice(
        text: String,
        audioURLPath: String?,
        summaryText: String?,
        summaryAudioURLPath: String?,
        isAudioPlaying: Bool
    ) -> NotificationPlaybackChoice {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummaryText = summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAudioURLPath = audioURLPath?.isEmpty == true ? nil : audioURLPath
        let normalizedSummaryAudioURLPath = summaryAudioURLPath?.isEmpty == true ? nil : summaryAudioURLPath

        if !isAudioPlaying, !trimmedSummaryText.isEmpty {
            return NotificationPlaybackChoice(
                text: trimmedSummaryText,
                audioURLPath: normalizedSummaryAudioURLPath ?? normalizedAudioURLPath
            )
        }

        return NotificationPlaybackChoice(
            text: trimmedText.isEmpty ? trimmedSummaryText : trimmedText,
            audioURLPath: normalizedAudioURLPath
        )
    }

    func registerSession() async throws -> String {
        if let sessionID {
            return sessionID
        }

        let configuration = RTCConfiguration()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = peerConnectionFactory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw URLError(.cannotCreateFile)
        }
        let dataChannelConfig = RTCDataChannelConfiguration()
        guard let dataChannel = peerConnection.dataChannel(forLabel: "tincan", configuration: dataChannelConfig) else {
            throw URLError(.cannotCreateFile)
        }
        dataChannel.delegate = self

        self.peerConnection = peerConnection
        self.dataChannel = dataChannel

        let offer = try await createOffer(on: peerConnection, constraints: constraints)
        try await setLocalDescription(offer, on: peerConnection)

        let response = try await exchangeOffer(offerSDP: offer.sdp)
        let answer = RTCSessionDescription(type: .answer, sdp: response.answerSDP)
        try await setRemoteDescription(answer, on: peerConnection)

        sessionID = response.sessionId

        if dataChannel.readyState != .open {
            try await waitForOpenDataChannel()
        }

        return response.sessionId
    }

    func deregisterSession(_ sessionID: String) async {
        if let url = URL(string: "webrtc/session/\(sessionID)", relativeTo: serverBaseURL) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }

        finishSession(error: nil)
    }

    func uploadUtterance(sessionID: String, audioWAV: Data) async throws -> UtteranceResponse {
        guard sessionID == self.sessionID, let dataChannel, dataChannel.readyState == .open else {
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

    func eventStream(sessionID: String) -> AsyncStream<ServerEvent> {
        AsyncStream { continuation in
            eventContinuation?.finish()
            eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [self] in
                    self.eventContinuation = nil
                }
            }
        }
    }

    private func exchangeOffer(offerSDP: String) async throws -> RegisterResponse {
        guard let url = URL(string: serverBaseURL.absoluteString + "/webrtc/session") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["offer_sdp": offerSDP])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RegisterResponse.self, from: data)
    }

    private func waitForOpenDataChannel() async throws {
        guard dataChannel?.readyState != .open else { return }

        try await withCheckedThrowingContinuation { continuation in
            if dataChannel?.readyState == .open {
                continuation.resume(returning: ())
            } else {
                openContinuation = continuation
            }
        }
    }

    private func createOffer(on peerConnection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: sdp)
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
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

    private func setRemoteDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
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

    private func resumeOpenContinuation(error: Error?) {
        let continuation = openContinuation
        openContinuation = nil

        guard let continuation else { return }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    private func finishSession(error: Error?) {
        guard !isFinishingSession else { return }
        isFinishingSession = true
        defer { isFinishingSession = false }

        let pendingUtteranceContinuations = self.pendingUtteranceContinuations
        self.pendingUtteranceContinuations.removeAll()

        let eventContinuation = self.eventContinuation
        self.eventContinuation = nil

        let dataChannel = self.dataChannel
        let peerConnection = self.peerConnection
        self.dataChannel = nil
        self.peerConnection = nil
        sessionID = nil

        resumeOpenContinuation(error: error)

        for continuation in pendingUtteranceContinuations.values {
            continuation.resume(throwing: error ?? URLError(.networkConnectionLost))
        }

        eventContinuation?.finish()
        dataChannel?.delegate = nil
        peerConnection?.delegate = nil
        dataChannel?.close()
        peerConnection?.close()
    }

    private func handleIncomingData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
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
            continuation.resume(throwing: URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: error]))
            return
        }

        continuation.resume(returning: UtteranceResponse(text: result.text, feedbackAudioURL: result.feedbackAudioURL))
    }

    private func parseServerEvent(_ json: [String: Any]) -> ServerEvent? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "play_audio":
            let text = json["text"] as? String ?? ""
            let urlPath = json["url"] as? String ?? ""
            return .playAudio(text: text, urlPath: urlPath)
        case "notify":
            let text = json["text"] as? String ?? ""
            let audioURLPath = json["audio_url"] as? String
            let summaryText = (json["summary_text"] as? String) ?? (json["detail_text"] as? String)
            let summaryAudioURLPath = (json["summary_audio_url"] as? String) ?? (json["detail_audio_url"] as? String)
            return .notify(
                text: text,
                audioURLPath: audioURLPath,
                summaryText: summaryText,
                summaryAudioURLPath: summaryAudioURLPath
            )
        default:
            return nil
        }
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
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }

            switch newState {
            case .closed, .failed, .disconnected:
                self.finishSession(error: URLError(.networkConnectionLost))
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason: String) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}

extension BackendSessionClient: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.dataChannel === dataChannel else { return }

            switch dataChannel.readyState {
            case .open:
                self.resumeOpenContinuation(error: nil)
            case .closed:
                self.finishSession(error: URLError(.networkConnectionLost))
            default:
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
