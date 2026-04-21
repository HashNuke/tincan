import Foundation

struct BackendSessionClient {
    let serverBaseURL: URL

    struct NotificationPlaybackChoice: Equatable {
        let text: String
        let audioURLPath: String?
    }

    struct RegisterResponse: Decodable {
        let sessionId: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
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
        case notify(text: String, audioURLPath: String?, detailText: String?, detailAudioURLPath: String?)
    }

    static func notificationPlaybackChoice(
        text: String,
        audioURLPath: String?,
        detailText: String?,
        detailAudioURLPath: String?,
        isAudioPlaying: Bool
    ) -> NotificationPlaybackChoice {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetailText = detailText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAudioURLPath = audioURLPath?.isEmpty == true ? nil : audioURLPath
        let normalizedDetailAudioURLPath = detailAudioURLPath?.isEmpty == true ? nil : detailAudioURLPath

        if !isAudioPlaying, !trimmedDetailText.isEmpty {
            return NotificationPlaybackChoice(
                text: trimmedDetailText,
                audioURLPath: normalizedDetailAudioURLPath ?? normalizedAudioURLPath
            )
        }

        return NotificationPlaybackChoice(
            text: trimmedText.isEmpty ? trimmedDetailText : trimmedText,
            audioURLPath: normalizedAudioURLPath
        )
    }

    // MARK: - Session lifecycle

    func registerSession() async throws -> String {
        guard let url = URL(string: serverBaseURL.absoluteString + "/linphone/session") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RegisterResponse.self, from: data).sessionId
    }

    func deregisterSession(_ sessionID: String) async {
        guard let url = URL(string: "linphone/session/\(sessionID)", relativeTo: serverBaseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Audio

    func uploadUtterance(sessionID: String, audioWAV: Data) async throws -> UtteranceResponse {
        guard let url = URL(string: serverBaseURL.absoluteString + "/session/\(sessionID)/utterance") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audioWAV
        request.timeoutInterval = 180
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(body)"])
        }
        return try JSONDecoder().decode(UtteranceResponse.self, from: data)
    }

    // MARK: - Events

    func eventStream(sessionID: String) -> AsyncStream<ServerEvent> {
        AsyncStream { continuation in
            Task {
                guard let url = URL(string: "linphone/session/\(sessionID)/events", relativeTo: serverBaseURL) else {
                    continuation.finish()
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = .infinity
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        continuation.finish()
                        return
                    }
                    var lineBuffer = ""
                    for try await byte in bytes {
                        let char = String(bytes: [byte], encoding: .utf8) ?? ""
                        if char == "\n" {
                            let line = lineBuffer
                            lineBuffer = ""
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonStr = String(line.dropFirst(6))
                            if let event = parseSSEEvent(jsonStr) {
                                continuation.yield(event)
                            }
                        } else if char != "\r" {
                            lineBuffer += char
                        }
                    }
                } catch {
                    // Stream ended or connection lost — finish silently.
                }
                continuation.finish()
            }
        }
    }

    private func parseSSEEvent(_ jsonStr: String) -> ServerEvent? {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "play_audio":
            let text = json["text"] as? String ?? ""
            let urlPath = json["url"] as? String ?? ""
            return .playAudio(text: text, urlPath: urlPath)
        case "notify":
            let text = json["text"] as? String ?? ""
            let audioURLPath = json["audio_url"] as? String
            let detailText = json["detail_text"] as? String
            let detailAudioURLPath = json["detail_audio_url"] as? String
            return .notify(
                text: text,
                audioURLPath: audioURLPath,
                detailText: detailText,
                detailAudioURLPath: detailAudioURLPath
            )
        default:
            return nil
        }
    }
}
