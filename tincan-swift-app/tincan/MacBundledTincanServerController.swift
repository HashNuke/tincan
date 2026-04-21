#if os(macOS)
import AppKit
import Foundation

@MainActor
final class MacBundledTincanServerController {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private let port: Int
    private var process: Process?
    private var logHandle: FileHandle?
    private var terminationObserver: NSObjectProtocol?

    init(port: Int) {
        self.port = port
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func startIfNeeded() async {
        prepareStartupLoggingIfNeeded()

        if process?.isRunning == true {
            do {
                try await waitUntilReachable(timeout: 10)
                writeStartupLog("bundled tincan-server already running on port \(port)")
            } catch {
                writeStartupLog("bundled tincan-server is running but failed health check: \(error.localizedDescription)")
                NSLog("Bundled tincan-server is running but not healthy: %@", error.localizedDescription)
            }
            return
        }

        if await isServerReachable() {
            writeStartupLog("skipping bundled tincan-server launch because a server is already reachable at 127.0.0.1:\(port)")
            return
        }

        do {
            let executableURL = try resolveExecutableURL()
            writeStartupLog("launching bundled tincan-server from \(executableURL.path)")
            let process = Process()
            process.executableURL = executableURL
            process.currentDirectoryURL = executableURL.deletingLastPathComponent()
            process.arguments = [
                "--data-dir", AppPaths.appSupportDirectory.path,
                "--port", String(port),
            ]
            guard let logHandle else {
                throw LaunchError.logFileUnavailable(AppPaths.tincanServerLogURL.path)
            }
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishProcessRun()
                }
            }
            try process.run()
            self.process = process
            try await waitUntilReachable(timeout: 10)
            writeStartupLog("bundled tincan-server became healthy on port \(port)")
        } catch {
            writeStartupLog("failed to launch bundled tincan-server: \(error.localizedDescription)")
            if process == nil {
                finishProcessRun()
            }
            NSLog("Failed to launch bundled tincan-server: %@", error.localizedDescription)
        }
    }

    func stop() {
        guard let process, process.isRunning else {
            finishProcessRun()
            return
        }

        process.terminate()
        process.waitUntilExit()
        finishProcessRun()
    }

    private func waitUntilReachable(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isServerReachable() {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LaunchError.serverDidNotBecomeHealthy(port)
    }

    private func isServerReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(BackendConnectionConfig.healthPath)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func resolveExecutableURL() throws -> URL {
        for runtimeRootURL in runtimeRootCandidates {
            let executableURL = runtimeRootURL.appendingPathComponent("tincan-server", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }

        throw LaunchError.missingBundledRuntime(runtimeRootCandidates.map(\.path))
    }

    private var runtimeRootCandidates: [URL] {
        var candidates: [URL] = []

        if let bundleResourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("BundledRuntime", isDirectory: true) {
            candidates.append(bundleResourceURL)
        }

        candidates.append(AppPaths.projectRoot.appendingPathComponent("BundledRuntime", isDirectory: true))
        return candidates
    }

    private func prepareStartupLoggingIfNeeded() {
        guard logHandle == nil else { return }

        do {
            let handle = try prepareLogFile()
            logHandle = handle
            writeStartupLog("mac launcher initialized; log file at \(AppPaths.tincanServerLogURL.path)")
        } catch {
            NSLog("Failed to prepare tincan-server log file: %@", error.localizedDescription)
        }
    }

    private func prepareLogFile() throws -> FileHandle {
        let logURL = AppPaths.tincanServerLogURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        return handle
    }

    private func writeStartupLog(_ message: String) {
        guard let logHandle else { return }

        let timestamp = Self.timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        do {
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: Data(line.utf8))
        } catch {
            NSLog("Failed writing tincan-server log entry: %@", error.localizedDescription)
        }
    }

    private func finishProcessRun() {
        if let process {
            writeStartupLog("bundled tincan-server exited with status \(process.terminationStatus)")
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }
}

extension MacBundledTincanServerController {
    enum LaunchError: LocalizedError {
        case missingBundledRuntime([String])
        case serverDidNotBecomeHealthy(Int)
        case logFileUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledRuntime(let candidatePaths):
                return "BundledRuntime/tincan-server was not found. Checked: \(candidatePaths.joined(separator: ", "))"
            case .serverDidNotBecomeHealthy(let port):
                return "tincan-server did not become healthy on port \(port)"
            case .logFileUnavailable(let path):
                return "tincan-server log file could not be opened at \(path)"
            }
        }
    }
}
#endif
