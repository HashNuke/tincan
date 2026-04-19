import Foundation
import Vapor

actor OpencodeRunner {
    func run(transcript: String, logger: Logger) async {
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            logger.warning("Skipping opencode run for an empty transcript")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["opencode", "run", command]
        process.environment = environmentWithOpencodePaths()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        logger.info("Launching opencode for transcript: \(command)")

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch opencode: \(error.localizedDescription)")
            return
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !stdout.isEmpty {
            print(stdout)
        }

        if !stderr.isEmpty {
            print(stderr)
        }

        logger.info("opencode exited with status \(process.terminationStatus)")
    }

    private func environmentWithOpencodePaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "\(homeDirectory)/.opencode/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        let existingPath = environment["PATH"] ?? ""
        let mergedPath = (preferredPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { paths, entry in
                guard !paths.contains(entry) else { return }
                paths.append(entry)
            }
            .joined(separator: ":")

        environment["PATH"] = mergedPath
        return environment
    }
}

private struct OpencodeRunnerKey: StorageKey {
    typealias Value = OpencodeRunner
}

extension Application {
    var opencodeRunner: OpencodeRunner {
        get {
            guard let runner = storage[OpencodeRunnerKey.self] else {
                fatalError("OpencodeRunner not configured")
            }
            return runner
        }
        set {
            storage[OpencodeRunnerKey.self] = newValue
        }
    }
}
