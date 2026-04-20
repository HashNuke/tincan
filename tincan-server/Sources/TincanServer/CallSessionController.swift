import Vapor

struct CallSessionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("call-session", "committed-command", use: committedCommand)
    }

    @Sendable
    private func committedCommand(req: Request) async throws -> CommittedCommandResponse {
        let request = try req.content.decode(CommittedCommandRequest.self)
        return try await req.application.callSessionService.handleCommittedCommand(on: req, request: request)
    }
}
