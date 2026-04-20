import Foundation
import Vapor

struct OpenCodeSession: Content, Sendable {
    let id: String
}

struct OpenCodeModelRef: Content, Sendable {
    let providerID: String
    let modelID: String
}

struct OpenCodeCreateSessionRequest: Content, Sendable {
    let title: String
}

struct OpenCodePromptPart: Content, Sendable {
    let type: String
    let text: String
}

struct OpenCodePromptAsyncRequest: Content, Sendable {
    let model: OpenCodeModelRef?
    let agent: String?
    let parts: [OpenCodePromptPart]
}

struct AnyOpenCodeClient: Sendable {
    let createSession: @Sendable (_ client: any Client, _ baseURL: String, _ directory: String, _ title: String) async throws -> OpenCodeSession
    let sendPromptAsync: @Sendable (
        _ client: any Client,
        _ baseURL: String,
        _ directory: String,
        _ sessionID: String,
        _ message: String,
        _ model: String,
        _ agent: String?
    ) async throws -> Void

    static let live = AnyOpenCodeClient(
        createSession: { client, baseURL, directory, title in
            let encodedDirectory = directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
            let uri = URI(string: "\(baseURL)/session?directory=\(encodedDirectory)")

            let response = try await client.post(uri) { request in
                try request.content.encode(OpenCodeCreateSessionRequest(title: title))
            }

            guard response.status == .ok else {
                throw Abort(.badGateway, reason: "OpenCode session creation failed with status \(response.status.code)")
            }

            return try response.content.decode(OpenCodeSession.self)
        },
        sendPromptAsync: { client, baseURL, directory, sessionID, message, model, agent in
            let encodedDirectory = directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
            let uri = URI(string: "\(baseURL)/session/\(sessionID)/prompt_async?directory=\(encodedDirectory)")
            let response = try await client.post(uri) { request in
                try request.content.encode(
                    OpenCodePromptAsyncRequest(
                        model: try OpenCodeModelRef.parse(model),
                        agent: agent,
                        parts: [OpenCodePromptPart(type: "text", text: message)]
                    )
                )
            }

            guard response.status == .noContent else {
                throw Abort(.badGateway, reason: "OpenCode prompt_async failed with status \(response.status.code)")
            }
        }
    )
}

extension OpenCodeModelRef {
    static func parse(_ rawValue: String) throws -> OpenCodeModelRef {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw Abort(.badRequest, reason: "Expected model in provider/model form")
        }

        return OpenCodeModelRef(providerID: parts[0], modelID: parts[1])
    }
}

private struct OpenCodeClientKey: StorageKey {
    typealias Value = AnyOpenCodeClient
}

extension Application {
    var openCodeClient: AnyOpenCodeClient {
        get {
            storage[OpenCodeClientKey.self] ?? .live
        }
        set {
            storage[OpenCodeClientKey.self] = newValue
        }
    }
}
