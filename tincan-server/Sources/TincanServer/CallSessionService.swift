import Foundation
import Vapor

struct CommittedCommandRequest: Content {
    let rawTranscript: String

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
    }
}

struct RouterActionResponse: Content {
    let action: String
    let message: String?
    let agent: String?
    let conversationHandle: String?
    let immediateFeedback: String
    let rawTranscript: String

    enum CodingKeys: String, CodingKey {
        case action
        case message
        case agent
        case conversationHandle = "conversation_handle"
        case immediateFeedback = "immediate_feedback"
        case rawTranscript = "raw_transcript"
    }
}

struct CommittedCommandResponse: Content {
    let router: RouterActionResponse
    let conversation: ConversationCreateResponse?
}

struct CallSessionService: Sendable {
    func handleCommittedCommand(on req: Request, request: CommittedCommandRequest) async throws -> CommittedCommandResponse {
        let action = try await routeCommittedTranscript(on: req, rawTranscript: request.rawTranscript)

        switch action.action {
        case "new_conversation":
            guard let agent = action.agent, let message = action.message else {
                throw Abort(.internalServerError, reason: "Router returned incomplete new_conversation action")
            }

            let conversation = try await req.application.conversationService.createConversation(
                on: req,
                request: ConversationCreateRequest(profileName: agent, message: message)
            )
            return CommittedCommandResponse(router: action, conversation: conversation)

        default:
            return CommittedCommandResponse(router: action, conversation: nil)
        }
    }

    private func routeCommittedTranscript(on req: Request, rawTranscript: String) async throws -> RouterActionResponse {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return RouterActionResponse(
                action: "ignore",
                message: nil,
                agent: nil,
                conversationHandle: nil,
                immediateFeedback: "I didn't catch anything to send.",
                rawTranscript: rawTranscript
            )
        }

        let lowered = trimmed.lowercased()
        let profiles = await req.application.agentProfileStore.list().map(\ .name)

        for profile in profiles {
            let createPatterns = [
                "start a new \(profile) conversation",
                "new chat with \(profile)",
                "create a new \(profile) session",
            ]

            guard createPatterns.contains(where: lowered.contains) else {
                continue
            }

            let extractedMessage = extractCreateConversationMessage(from: trimmed, for: profile)
            guard extractedMessage.isEmpty == false else {
                return RouterActionResponse(
                    action: "ask_clarifying_question",
                    message: nil,
                    agent: profile,
                    conversationHandle: nil,
                    immediateFeedback: "What should I ask \(profile) to work on?",
                    rawTranscript: rawTranscript
                )
            }

            return RouterActionResponse(
                action: "new_conversation",
                message: extractedMessage,
                agent: profile,
                conversationHandle: nil,
                immediateFeedback: "Starting a new \(profile) conversation.",
                rawTranscript: rawTranscript
            )
        }

        return RouterActionResponse(
            action: "ask_clarifying_question",
            message: nil,
            agent: nil,
            conversationHandle: nil,
            immediateFeedback: "Say start a new conversation and the agent name, or mention an existing conversation handle.",
            rawTranscript: rawTranscript
        )
    }

    private func extractCreateConversationMessage(from transcript: String, for profile: String) -> String {
        let lowered = transcript.lowercased()
        let separators = [" to ", " for ", " about "]

        for separator in separators {
            if let range = lowered.range(of: separator) {
                let message = transcript[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty == false {
                    return message
                }
            }
        }

        let patterns = [
            "start a new \(profile) conversation",
            "new chat with \(profile)",
            "create a new \(profile) session",
        ]

        for pattern in patterns {
            if lowered.hasPrefix(pattern) {
                return ""
            }
        }

        return ""
    }
}

private struct CallSessionServiceKey: StorageKey {
    typealias Value = CallSessionService
}

extension Application {
    var callSessionService: CallSessionService {
        get {
            storage[CallSessionServiceKey.self] ?? CallSessionService()
        }
        set {
            storage[CallSessionServiceKey.self] = newValue
        }
    }
}
