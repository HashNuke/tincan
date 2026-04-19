import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8004

    app.tincanInferenceService = TincanInferenceService()
    app.tincanSpeechService = TincanSpeechService()
    app.opencodeRunner = OpencodeRunner()

    try routes(app)
}
