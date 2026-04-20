import Fluent
import Foundation
import Vapor

struct ConversationCreateRequest: Content {
    let profileName: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case profileName = "profile_name"
        case message
    }
}

struct ConversationCreateResponse: Content {
    let id: UUID
    let displayHandle: String
    let conversationNumber: Int
    let agentProfileName: String
    let agentBackend: String
    let backendConversationID: String
    let status: String
    let announcementText: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayHandle = "display_handle"
        case conversationNumber = "conversation_number"
        case agentProfileName = "agent_profile_name"
        case agentBackend = "agent_backend"
        case backendConversationID = "backend_conversation_id"
        case status
        case announcementText = "announcement_text"
    }
}

struct OpenCodeHookEvent: Content {
    let eventType: String
    let sessionID: String?
    let statusType: String?
    let errorName: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case sessionID = "session_id"
        case statusType = "status_type"
        case errorName = "error_name"
        case errorMessage = "error_message"
    }
}

struct ConversationService: Sendable {
    func createConversation(on req: Request, request: ConversationCreateRequest) async throws -> ConversationCreateResponse {
        guard let profile = await req.application.agentProfileStore.profile(named: request.profileName) else {
            throw Abort(.notFound, reason: "Unknown agent profile: \(request.profileName)")
        }

        guard profile.agentBackend == .opencodeServer else {
            throw Abort(.badRequest, reason: "Only opencode-server profiles are supported right now")
        }

        guard let baseURL = profile.agentBackendOptions.baseURL, !baseURL.isEmpty else {
            throw Abort(.badRequest, reason: "Profile \(profile.name) is missing agent_backend_options.base_url")
        }

        let conversationNumber = try await Conversation.nextAvailableNumber(for: profile.name, on: req.db)
        let displayHandle = "\(profile.name)#\(conversationNumber)"
        let announcementText = "Hello, I'm \(displayHandle). I am working on \(request.message)"
        let session = try await req.application.openCodeClient.createSession(
            req.client,
            baseURL,
            profile.workingDirectory,
            displayHandle
        )

        let conversation = Conversation(
            displayHandle: displayHandle,
            agentProfileName: profile.name,
            conversationNumber: conversationNumber,
            agentBackend: profile.agentBackend.rawValue,
            workingDirectory: profile.workingDirectory,
            backendConversationID: session.id,
            status: ConversationStatus.starting.rawValue
        )
        try await conversation.create(on: req.db)

        do {
            try await req.application.openCodeClient.sendPromptAsync(
                req.client,
                baseURL,
                profile.workingDirectory,
                session.id,
                request.message,
                profile.agentBackendOptions.model,
                profile.agentBackendOptions.agent
            )
            conversation.status = ConversationStatus.running.rawValue
            conversation.lastMessageAt = Date()
            try await conversation.update(on: req.db)
        } catch {
            conversation.status = ConversationStatus.failed.rawValue
            conversation.endedAt = Date()
            conversation.lastMessageAt = conversation.endedAt
            try await conversation.update(on: req.db)
            throw error
        }

        guard let id = conversation.id else {
            throw Abort(.internalServerError, reason: "Conversation ID was not assigned")
        }

        return ConversationCreateResponse(
            id: id,
            displayHandle: displayHandle,
            conversationNumber: conversationNumber,
            agentProfileName: profile.name,
            agentBackend: profile.agentBackend.rawValue,
            backendConversationID: session.id,
            status: conversation.status,
            announcementText: announcementText
        )
    }

    func handleOpenCodeHook(on req: Request, event: OpenCodeHookEvent) async throws -> HTTPStatus {
        let now = Date()

        guard let sessionID = event.sessionID, !sessionID.isEmpty else {
            req.logger.warning("Ignoring OpenCode hook without a session ID")
            return .noContent
        }

        guard let conversation = try await Conversation.query(on: req.db)
            .filter(\.$backendConversationID == sessionID)
            .first()
        else {
            req.logger.warning("Ignoring OpenCode hook for unknown session \(sessionID)")
            return .noContent
        }

        switch event.eventType {
        case "session.status":
            conversation.status = event.statusType ?? conversation.status
            conversation.lastMessageAt = now
            if event.statusType == "idle" {
                conversation.endedAt = now
            }
        case "session.idle":
            conversation.status = "idle"
            conversation.lastMessageAt = now
            conversation.endedAt = now
        case "session.error":
            conversation.status = "failed"
            conversation.lastMessageAt = now
            conversation.endedAt = now
        default:
            req.logger.info("Ignoring unsupported OpenCode hook event: \(event.eventType)")
            return .noContent
        }

        try await conversation.update(on: req.db)
        return .noContent
    }
}

private struct ConversationServiceKey: StorageKey {
    typealias Value = ConversationService
}

extension Application {
    var conversationService: ConversationService {
        get {
            storage[ConversationServiceKey.self] ?? ConversationService()
        }
        set {
            storage[ConversationServiceKey.self] = newValue
        }
    }
}
