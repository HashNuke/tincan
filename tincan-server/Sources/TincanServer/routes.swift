import Fluent
import Foundation
import Vapor

func routes(_ app: Application) throws {
    app.get { _ async in
        "tincan-server"
    }

    app.post("conversations") { req async throws -> ConversationCreateResponse in
        let request = try req.content.decode(ConversationCreateRequest.self)

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
            status: conversation.status
        )
    }

    app.get("health") { req async throws -> HealthResponse in
        async let inferenceHealth = req.application.tincanInferenceService.health()
        async let ttsHealth = req.application.tincanSpeechService.health()
        return await HealthResponse(
            status: "ok",
            modelCacheDirectory: inferenceHealth.modelCacheDirectory,
            isModelReady: inferenceHealth.isModelReady,
            tts: ttsHealth
        )
    }

    app.on(.POST, "infer", body: .collect(maxSize: "25mb")) { req async throws -> InferResponse in
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Expected a WAV request body")
        }

        let requestID = UUID()
        let audioData = Data(body.readableBytesView)
        req.logger.info("Received /infer request \(requestID) with \(audioData.count) bytes")
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(requestID.uuidString)
            .appendingPathExtension("wav")

        try audioData.write(to: temporaryURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            let transcript = try await req.application.tincanInferenceService.transcribe(audioFileURL: temporaryURL)
            req.logger.info("Transcript: \(transcript)")
            Task {
                await req.application.opencodeRunner.run(transcript: transcript, logger: req.logger)
            }
            return InferResponse(requestID: requestID, transcript: transcript)
        } catch {
            req.logger.error("Inference failed: \(String(describing: error))")
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }

    app.post("speak") { req async throws -> Response in
        let request = try req.content.decode(SpeakRequest.self)
        let audioData = try await req.application.tincanSpeechService.synthesize(text: request.text)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "audio/wav")
        return Response(
            status: .ok,
            headers: headers,
            body: .init(data: audioData)
        )
    }

    app.post("hooks", "opencode") { req async throws -> HTTPStatus in
        let event = try req.content.decode(OpenCodeHookEvent.self)
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

struct HealthResponse: Content {
    let status: String
    let modelCacheDirectory: String
    let isModelReady: Bool
    let tts: TtsHealthResponse
}

struct TtsHealthResponse: Content {
    let defaultVoice: String
    let isModelReady: Bool
}

struct InferResponse: Content {
    let requestID: UUID
    let transcript: String

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case transcript
    }
}

struct SpeakRequest: Content {
    let text: String
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

    enum CodingKeys: String, CodingKey {
        case id
        case displayHandle = "display_handle"
        case conversationNumber = "conversation_number"
        case agentProfileName = "agent_profile_name"
        case agentBackend = "agent_backend"
        case backendConversationID = "backend_conversation_id"
        case status
    }
}
