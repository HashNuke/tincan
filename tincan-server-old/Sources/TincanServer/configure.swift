import Fluent
import FluentSQLiteDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8004

    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.file(app.directory.workingDirectory + "tincan.sqlite")), as: .sqlite)
    }

    app.migrations.add(CreateConversation())
    app.migrations.add(AddConversationNumberToConversation())
    try await app.autoMigrate()

    app.callSessionService = CallSessionService()
    app.conversationService = ConversationService()
    app.agentProfileStore = try AgentProfileStore()
    app.tincanInferenceService = TincanInferenceService()
    app.tincanSpeechService = TincanSpeechService()
    app.opencodeRunner = OpencodeRunner()

    try routes(app)
}
