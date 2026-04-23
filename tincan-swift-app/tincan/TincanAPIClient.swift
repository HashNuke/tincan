import Foundation

struct TincanConversationSummary: Identifiable, Equatable {
    let id: String
    let handle: String
    let agentProfileName: String
    let agentBackend: String
    let workingDirectory: String
    let status: String
    let updatedAt: Date
    let previewText: String
    var hasPendingUpdate: Bool
    var hasUnreadTextUpdate: Bool
    var isCurrentCallConversation: Bool
}

struct TincanConversationMessage: Identifiable, Equatable {
    let id: String
    let kind: String
    let summaryText: String
    let detailText: String
    let notificationText: String
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let consumedAt: Date?
}

struct TincanConversationDetail: Equatable {
    let conversation: TincanConversationSummary
    let messages: [TincanConversationMessage]
}

struct TincanAgentBackend: Identifiable, Equatable {
    struct Options: Equatable {
        let connectionType: String
        let command: String
        let model: String
        let modelVariant: String
        let agent: String
        let extraArgs: [String]
    }

    let id: String
    let type: String
    let options: Options
}

struct TincanAgentProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let workingDirectory: String
    let agentBackend: String
}

struct TincanAPIClient {
    struct HealthResponse: Decodable {
        let status: String
        let agentProfileCount: Int

        enum CodingKeys: String, CodingKey {
            case status
            case agentProfileCount = "agent_profile_count"
        }
    }

    let baseURL: URL

    func listConversations() async throws -> [TincanConversationSummary] {
        var allConversations: [TincanConversationSummary] = []
        var cursor: String?

        repeat {
            let page: ConversationListResponse = try await requestJSON(
                path: "/api/v1/conversations",
                queryItems: [
                    URLQueryItem(name: "page_size", value: "100"),
                    cursor.map { URLQueryItem(name: "cursor", value: $0) },
                ].compactMap { $0 }
            )
            allConversations.append(contentsOf: page.conversations.map(\.uiModel))
            cursor = page.nextCursor
        } while cursor != nil

        return allConversations
    }

    func listConversationMessages(conversationID: String) async throws -> TincanConversationDetail {
        var allMessages: [TincanConversationMessage] = []
        var cursor: String?
        var conversation: TincanConversationSummary?

        repeat {
            let response: ConversationMessagesResponse = try await requestJSON(
                path: "/api/v1/conversations/\(conversationID)/messages",
                queryItems: [
                    URLQueryItem(name: "page_size", value: "100"),
                    cursor.map { URLQueryItem(name: "cursor", value: $0) },
                ].compactMap { $0 }
            )

            conversation = response.conversation.uiModel
            allMessages.append(contentsOf: response.messages.map(\.uiModel))
            cursor = response.nextCursor
        } while cursor != nil

        guard let conversation else {
            throw URLError(.badServerResponse)
        }

        return TincanConversationDetail(conversation: conversation, messages: allMessages)
    }

    func listAgentBackends() async throws -> [TincanAgentBackend] {
        let response: AgentBackendsResponse = try await requestJSON(path: "/api/v1/agent-backends")
        return response.backends.map(\.uiModel)
    }

    func listAgentProfiles() async throws -> [TincanAgentProfile] {
        let response: AgentProfilesResponse = try await requestJSON(path: "/api/v1/agent-profiles")
        return response.profiles.map(\.uiModel)
    }

    static func decodeHealthResponse(from data: Data) throws -> HealthResponse {
        try Self.decoder.decode(HealthResponse.self, from: data)
    }

    private func requestJSON<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        let data = try await requestData(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body
        )
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func requestData(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIRequestError(statusCode: http.statusCode, responseBody: data)
        }

        return data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalDateFormatter.date(from: value) ?? basicDateFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date value: \(value)"
            )
        }
        return decoder
    }()

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct APIRequestError: LocalizedError {
    let statusCode: Int
    let responseBody: Data

    var errorDescription: String? {
        let message = String(data: responseBody, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if message.isEmpty {
            return "Server request failed (\(statusCode))."
        }
        return message
    }
}

private struct ConversationListResponse: Decodable {
    let nextCursor: String?
    let conversations: [ConversationDTO]

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case conversations
    }
}

private struct ConversationMessagesResponse: Decodable {
    let conversation: ConversationDTO
    let nextCursor: String?
    let messages: [ConversationMessageDTO]

    enum CodingKeys: String, CodingKey {
        case conversation
        case nextCursor = "next_cursor"
        case messages
    }
}

private struct ConversationDTO: Decodable {
    let id: String
    let handle: String
    let agentProfileName: String
    let agentBackend: String
    let workingDirectory: String
    let status: String
    let updatedAt: Date
    let previewText: String
    let hasPendingUpdate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case handle
        case agentProfileName = "agent_profile_name"
        case agentBackend = "agent_backend"
        case workingDirectory = "working_directory"
        case status
        case updatedAt = "updated_at"
        case previewText = "preview_text"
        case hasPendingUpdate = "has_pending_update"
    }

    var uiModel: TincanConversationSummary {
        TincanConversationSummary(
            id: id,
            handle: handle,
            agentProfileName: agentProfileName,
            agentBackend: agentBackend,
            workingDirectory: workingDirectory,
            status: status,
            updatedAt: updatedAt,
            previewText: previewText,
            hasPendingUpdate: hasPendingUpdate,
            hasUnreadTextUpdate: false,
            isCurrentCallConversation: false
        )
    }
}

private struct ConversationMessageDTO: Decodable {
    let id: String
    let kind: String
    let summaryText: String
    let detailText: String
    let notificationText: String
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let consumedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case summaryText = "summary_text"
        case detailText = "detail_text"
        case notificationText = "notification_text"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case consumedAt = "consumed_at"
    }

    var uiModel: TincanConversationMessage {
        TincanConversationMessage(
            id: id,
            kind: kind,
            summaryText: summaryText,
            detailText: detailText,
            notificationText: notificationText,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            consumedAt: consumedAt
        )
    }
}

private struct AgentBackendsResponse: Decodable {
    let backends: [AgentBackendDTO]
}

private struct AgentBackendDTO: Decodable {
    struct OptionsDTO: Decodable {
        let connectionType: String?
        let command: String?
        let model: String?
        let modelVariant: String?
        let agent: String?
        let extraArgs: [String]?

        enum CodingKeys: String, CodingKey {
            case connectionType = "connection_type"
            case command
            case model
            case modelVariant = "model_variant"
            case agent
            case extraArgs = "extra_args"
        }
    }

    let name: String
    let type: String
    let options: OptionsDTO

    var uiModel: TincanAgentBackend {
        TincanAgentBackend(
            id: name,
            type: type,
            options: .init(
                connectionType: options.connectionType ?? "",
                command: options.command ?? "",
                model: options.model ?? "",
                modelVariant: options.modelVariant ?? "",
                agent: options.agent ?? "",
                extraArgs: options.extraArgs ?? []
            )
        )
    }
}

private struct AgentProfilesResponse: Decodable {
    let profiles: [AgentProfileDTO]
}

private struct AgentProfileDTO: Decodable {
    let name: String
    let workingDirectory: String
    let agentBackend: String

    enum CodingKeys: String, CodingKey {
        case name
        case workingDirectory = "working_directory"
        case agentBackend = "agent_backend"
    }

    var uiModel: TincanAgentProfile {
        TincanAgentProfile(
            id: name.lowercased(),
            name: name,
            workingDirectory: workingDirectory,
            agentBackend: agentBackend
        )
    }
}
