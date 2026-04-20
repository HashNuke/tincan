import Fluent
import Foundation

enum ConversationStatus: String, Sendable {
    case starting
    case running
    case busy
    case retry
    case idle
    case completed
    case failed
    case aborted
    case archived

    var reservesConversationNumber: Bool {
        switch self {
        case .starting, .running, .busy, .retry, .failed, .aborted:
            return true
        case .idle, .completed, .archived:
            return false
        }
    }
}

final class Conversation: Model, @unchecked Sendable {
    static let schema = "conversations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "display_handle")
    var displayHandle: String

    @Field(key: "agent_profile_name")
    var agentProfileName: String

    @OptionalField(key: "conversation_number")
    var conversationNumber: Int?

    @Field(key: "agent_backend")
    var agentBackend: String

    @Field(key: "working_directory")
    var workingDirectory: String

    @OptionalField(key: "backend_conversation_id")
    var backendConversationID: String?

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "last_message_at")
    var lastMessageAt: Date?

    @OptionalField(key: "ended_at")
    var endedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        displayHandle: String,
        agentProfileName: String,
        conversationNumber: Int? = nil,
        agentBackend: String,
        workingDirectory: String,
        backendConversationID: String? = nil,
        status: String,
        lastMessageAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.displayHandle = displayHandle
        self.agentProfileName = agentProfileName
        self.conversationNumber = conversationNumber
        self.agentBackend = agentBackend
        self.workingDirectory = workingDirectory
        self.backendConversationID = backendConversationID
        self.status = status
        self.lastMessageAt = lastMessageAt
        self.endedAt = endedAt
    }

    static func nextAvailableNumber(for agentProfileName: String, on database: any Database) async throws -> Int {
        let conversations = try await Conversation.query(on: database)
            .filter(\.$agentProfileName == agentProfileName)
            .all()

        let reserved = Set(conversations.compactMap { conversation -> Int? in
            guard let number = conversation.conversationNumber else {
                return nil
            }

            guard let status = ConversationStatus(rawValue: conversation.status) else {
                return number
            }

            return status.reservesConversationNumber ? number : nil
        })

        var candidate = 1
        while reserved.contains(candidate) {
            candidate += 1
        }
        return candidate
    }
}

struct CreateConversation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .id()
            .field("display_handle", .string, .required)
            .field("agent_profile_name", .string, .required)
            .field("agent_backend", .string, .required)
            .field("working_directory", .string, .required)
            .field("backend_conversation_id", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("last_message_at", .datetime)
            .field("ended_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema).delete()
    }
}

struct AddConversationNumberToConversation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .field("conversation_number", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Conversation.schema)
            .deleteField("conversation_number")
            .update()
    }
}
