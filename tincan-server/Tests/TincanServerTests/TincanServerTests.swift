@testable import TincanServer
import Fluent
import Testing
import Vapor
import VaporTesting

@Suite("Tincan Server Tests", .serialized)
struct TincanServerTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func mockOpenCodeClient(createdSessionID: String = "session-123") -> AnyOpenCodeClient {
        AnyOpenCodeClient(
            createSession: { _, _, _, title in
                #expect(title.isEmpty == false)
                return OpenCodeSession(id: createdSessionID)
            },
            sendPromptAsync: { _, _, _, sessionID, message, model, _ in
                #expect(sessionID == createdSessionID)
                #expect(message.isEmpty == false)
                #expect(model.isEmpty == false)
            }
        )
    }

    @Test("Health route reports server status")
    func health() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(HealthResponse.self)
                #expect(payload.status == "ok")
                #expect(payload.modelCacheDirectory.isEmpty == false)
                #expect(payload.isModelReady == false)
            }
        }
    }

    @Test("Infer rejects an empty body")
    func inferRejectsEmptyBody() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "infer") { response async throws in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("Agent profile store loads JSON-backed profiles")
    func agentProfiles() async throws {
        let store = try AgentProfileStore()
        let payload = await store.list()

        #expect(payload.count == 2)
        #expect(payload[0].name == "emma")
        #expect(payload[0].workingDirectory == "/Users/akash/code/apple/tincan")
        #expect(payload[0].agentBackend == .opencodeServer)
        #expect(payload[0].agentBackendOptions.model == "openai/gpt-5.4")
        #expect(payload[1].name == "atlas")
        #expect(payload[1].agentBackend == .codex)
    }

    @Test("Conversation model persists to SQLite")
    func conversationPersistence() async throws {
        try await withApp { app in
            let conversation = Conversation(
                displayHandle: "emma#1",
                agentProfileName: "emma",
                conversationNumber: 1,
                agentBackend: "opencode-server",
                workingDirectory: "/Users/akash/code/apple/tincan",
                backendConversationID: "session-123",
                status: "running"
            )

            try await conversation.create(on: app.db)

            let stored = try await Conversation.query(on: app.db)
                .filter(\.$displayHandle == "emma#1")
                .first()

            #expect(stored != nil)
            #expect(stored?.agentProfileName == "emma")
            #expect(stored?.conversationNumber == 1)
            #expect(stored?.agentBackend == "opencode-server")
            #expect(stored?.backendConversationID == "session-123")
            #expect(stored?.status == "running")
            #expect(stored?.createdAt != nil)
        }
    }

    @Test("OpenCode hook route updates conversation status")
    func opencodeHooksUpdateConversation() async throws {
        try await withApp { app in
            let conversation = Conversation(
                displayHandle: "emma#1",
                agentProfileName: "emma",
                conversationNumber: 1,
                agentBackend: "opencode-server",
                workingDirectory: "/Users/akash/code/apple/tincan",
                backendConversationID: "session-123",
                status: "running"
            )
            try await conversation.create(on: app.db)

            try await app.testing().test(.POST, "hooks/opencode", beforeRequest: { request in
                try request.content.encode(
                    OpenCodeHookEvent(
                        eventType: "session.idle",
                        sessionID: "session-123",
                        statusType: "idle",
                        errorName: nil,
                        errorMessage: nil
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .noContent)
            })

            let stored = try await Conversation.query(on: app.db)
                .filter(\.$backendConversationID == "session-123")
                .first()

            #expect(stored?.status == "idle")
            #expect(stored?.endedAt != nil)
            #expect(stored?.lastMessageAt != nil)
        }
    }

    @Test("Conversation allocator picks lowest reusable number per profile")
    func conversationNumberAllocation() async throws {
        try await withApp { app in
            let conversations = [
                Conversation(
                    displayHandle: "emma#1",
                    agentProfileName: "emma",
                    conversationNumber: 1,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "running"
                ),
                Conversation(
                    displayHandle: "emma#2",
                    agentProfileName: "emma",
                    conversationNumber: 2,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "failed"
                ),
                Conversation(
                    displayHandle: "emma#3",
                    agentProfileName: "emma",
                    conversationNumber: 3,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "completed"
                ),
                Conversation(
                    displayHandle: "emma#4",
                    agentProfileName: "emma",
                    conversationNumber: 4,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "archived"
                ),
                Conversation(
                    displayHandle: "atlas#1",
                    agentProfileName: "atlas",
                    conversationNumber: 1,
                    agentBackend: "codex",
                    workingDirectory: "/Users/akash/sources/opencode",
                    status: "running"
                ),
            ]

            for conversation in conversations {
                try await conversation.create(on: app.db)
            }

            let nextEmma = try await Conversation.nextAvailableNumber(for: "emma", on: app.db)
            let nextAtlas = try await Conversation.nextAvailableNumber(for: "atlas", on: app.db)

            #expect(nextEmma == 3)
            #expect(nextAtlas == 2)
        }
    }

    @Test("Conversation creation creates OpenCode session and persists mapping")
    func createConversation() async throws {
        try await withApp { app in
            app.openCodeClient = mockOpenCodeClient(createdSessionID: "oc-session-1")

            try await app.testing().test(.POST, "conversations", beforeRequest: { request in
                try request.content.encode(ConversationCreateRequest(profileName: "emma", message: "Fix the server bug"))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(ConversationCreateResponse.self)
                #expect(payload.displayHandle == "emma#1")
                #expect(payload.conversationNumber == 1)
                #expect(payload.agentProfileName == "emma")
                #expect(payload.agentBackend == "opencode-server")
                #expect(payload.backendConversationID == "oc-session-1")
                #expect(payload.status == "running")
                #expect(payload.announcementText == "Hello, I'm emma#1. I am working on Fix the server bug")
            })

            let stored = try await Conversation.query(on: app.db)
                .filter(\.$backendConversationID == "oc-session-1")
                .first()

            #expect(stored != nil)
            #expect(stored?.conversationNumber == 1)
            #expect(stored?.displayHandle == "emma#1")
            #expect(stored?.status == "running")
        }
    }

    @Test("Conversation creation reuses lowest non-reserved number")
    func createConversationUsesLowestReusableNumber() async throws {
        try await withApp { app in
            app.openCodeClient = mockOpenCodeClient(createdSessionID: "oc-session-2")

            let existing = [
                Conversation(
                    displayHandle: "emma#1",
                    agentProfileName: "emma",
                    conversationNumber: 1,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "running"
                ),
                Conversation(
                    displayHandle: "emma#2",
                    agentProfileName: "emma",
                    conversationNumber: 2,
                    agentBackend: "opencode-server",
                    workingDirectory: "/Users/akash/code/apple/tincan",
                    status: "completed"
                ),
            ]

            for conversation in existing {
                try await conversation.create(on: app.db)
            }

            try await app.testing().test(.POST, "conversations", beforeRequest: { request in
                try request.content.encode(ConversationCreateRequest(profileName: "emma", message: "Do another task"))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(ConversationCreateResponse.self)
                #expect(payload.displayHandle == "emma#2")
                #expect(payload.conversationNumber == 2)
                #expect(payload.announcementText == "Hello, I'm emma#2. I am working on Do another task")
            })
        }
    }

    @Test("Committed command creates conversation through call session path")
    func committedCommandCreatesConversation() async throws {
        try await withApp { app in
            app.openCodeClient = mockOpenCodeClient(createdSessionID: "oc-session-3")

            try await app.testing().test(.POST, "call-session/committed-command", beforeRequest: { request in
                try request.content.encode(
                    CommittedCommandRequest(rawTranscript: "start a new emma conversation to fix the Vapor auth bug")
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(CommittedCommandResponse.self)
                #expect(payload.router.action == "new_conversation")
                #expect(payload.router.agent == "emma")
                #expect(payload.router.message == "fix the Vapor auth bug")
                #expect(payload.router.immediateFeedback == "Starting a new emma conversation.")
                #expect(payload.conversation?.displayHandle == "emma#1")
                #expect(payload.conversation?.backendConversationID == "oc-session-3")
            })
        }
    }

    @Test("Committed command asks for clarification when no explicit create intent exists")
    func committedCommandAsksForClarification() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "call-session/committed-command", beforeRequest: { request in
                try request.content.encode(
                    CommittedCommandRequest(rawTranscript: "tell emma to fix the Vapor auth bug")
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(CommittedCommandResponse.self)
                #expect(payload.router.action == "ask_clarifying_question")
                #expect(payload.conversation == nil)
            })
        }
    }
}
