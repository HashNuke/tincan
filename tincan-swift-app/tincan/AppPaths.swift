import Foundation

enum AppPaths {
    nonisolated static let projectRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    nonisolated static let appSupportDirectory: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("tincan", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }()

    nonisolated static let generatedConfigDirectory: URL = {
        let directory = appSupportDirectory.appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }()

    nonisolated static let temporaryDirectory: URL = {
        let directory = appSupportDirectory.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }()

    nonisolated static let logsDirectory: URL = {
        let directory = appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }()

    nonisolated static let generatedAgentProfilesURL = generatedConfigDirectory.appendingPathComponent("agent_profiles.json")
    nonisolated static let generatedAgentBackendsURL = generatedConfigDirectory.appendingPathComponent("agent_backends.json")
    nonisolated static let speakerProfilesURL = appSupportDirectory.appendingPathComponent("speaker_profiles.json")
    nonisolated static let legacyOwnerProfileURL = appSupportDirectory.appendingPathComponent("owner-voice-profile.json")
    nonisolated static let tincanServerLogURL = logsDirectory.appendingPathComponent("tincan-server.log")
    nonisolated static let tincanServerPIDURL = appSupportDirectory.appendingPathComponent("tincan-server.pid")
    nonisolated static let tincanServerLaunchLockURL = appSupportDirectory.appendingPathComponent("tincan-server.launch.lock")
    nonisolated static let macCallLogURL = logsDirectory.appendingPathComponent("mac-call.log")
    nonisolated static let backendDirectory = projectRoot.appendingPathComponent("backend", isDirectory: true)
    nonisolated static let backendServerModule = "backend.server"

    static func bootstrap() {
        _ = appSupportDirectory
        _ = generatedConfigDirectory
        _ = temporaryDirectory
        _ = logsDirectory
    }
}

extension JSONEncoder {
    nonisolated static func tincanFileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
