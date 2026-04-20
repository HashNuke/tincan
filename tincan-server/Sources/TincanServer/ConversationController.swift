import Vapor

struct ConversationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("conversations", use: createConversation)
        routes.post("hooks", "opencode", use: openCodeHook)
    }

    @Sendable
    private func createConversation(req: Request) async throws -> ConversationCreateResponse {
        let request = try req.content.decode(ConversationCreateRequest.self)
        return try await req.application.conversationService.createConversation(on: req, request: request)
    }

    @Sendable
    private func openCodeHook(req: Request) async throws -> HTTPStatus {
        let event = try req.content.decode(OpenCodeHookEvent.self)
        return try await req.application.conversationService.handleOpenCodeHook(on: req, event: event)
    }
}
