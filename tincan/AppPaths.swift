import Foundation

enum AppPaths {
    static let projectRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static let backendDirectory = projectRoot.appendingPathComponent("backend", isDirectory: true)
    static let backendServerModule = "backend.server"
}
