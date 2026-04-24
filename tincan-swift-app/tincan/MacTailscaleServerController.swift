#if os(macOS)
import Combine
import Darwin
import Foundation

@MainActor
final class MacTailscaleServerController: ObservableObject {
    struct RuntimeStatus: Equatable {
        let state: String
        let message: String?
        let hostname: String?
        let authURL: String?
        let httpsURL: String?

        static let idle = RuntimeStatus(
            state: "idle",
            message: nil,
            hostname: nil,
            authURL: nil,
            httpsURL: nil
        )

        var pairingPayload: String? {
            httpsURL
        }

        var shouldShowSummaryRow: Bool {
            switch state {
            case "starting", "needs_login", "running":
                return false
            default:
                return state != "idle"
            }
        }

        func applyingMarkerLine(_ line: String) -> RuntimeStatus {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { return self }

            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])

            switch key {
            case "TINCAN_TAILSCALE_STATUS":
                if value == "running", httpsURL != nil {
                    return replacing(state: "serving", message: nil)
                }
                return replacing(state: value, message: statusMessage(for: value))
            case "TINCAN_TAILSCALE_AUTH_URL":
                return RuntimeStatus(
                    state: "needs_login",
                    message: "Waiting for you to approve this Mac on Tailscale.",
                    hostname: hostname,
                    authURL: value,
                    httpsURL: httpsURL
                )
            case "TINCAN_TAILSCALE_NODE":
                return RuntimeStatus(
                    state: "serving",
                    message: nil,
                    hostname: hostname,
                    authURL: nil,
                    httpsURL: value
                )
            case "TINCAN_TAILSCALE_ERROR":
                return RuntimeStatus(
                    state: "error",
                    message: value,
                    hostname: hostname,
                    authURL: nil,
                    httpsURL: httpsURL
                )
            default:
                return self
            }
        }

        private func replacing(state: String? = nil, message: String? = nil) -> RuntimeStatus {
            RuntimeStatus(
                state: state ?? self.state,
                message: message,
                hostname: hostname,
                authURL: authURL,
                httpsURL: httpsURL
            )
        }

        private func statusMessage(for state: String) -> String? {
            switch state {
            case "starting":
                return "Starting Tailscale setup..."
            case "needs_login":
                return "Waiting for you to approve this Mac on Tailscale."
            case "running":
                return "Tailscale setup is finishing."
            default:
                return nil
            }
        }
    }

    @Published private(set) var runtimeStatus: RuntimeStatus = .idle

    private let executableURLProvider: () throws -> URL
    private var setupProcess: Process?
    private var setupLogHandle: FileHandle?

    init(executableURLProvider: @escaping () throws -> URL = MacTailscaleServerController.resolveDefaultExecutableURL) {
        self.executableURLProvider = executableURLProvider
    }

    var authURL: URL? {
        guard let value = runtimeStatus.authURL else { return nil }
        return URL(string: value)
    }

    var httpsURL: URL? {
        guard let value = runtimeStatus.httpsURL else { return nil }
        return URL(string: value)
    }

    var pairingPayload: String? {
        runtimeStatus.pairingPayload
    }

    var displayEndpoint: String? {
        runtimeStatus.httpsURL
    }

    var statusSummary: String {
        switch runtimeStatus.state {
        case "idle":
            return "disabled"
        case "starting":
            return "starting"
        case "needs_login":
            return "waiting for approval"
        case "running":
            return "finishing setup"
        case "serving":
            return "ready"
        case "error":
            return "unavailable"
        default:
            return runtimeStatus.state
        }
    }

    var progressMessage: String? {
        switch runtimeStatus.state {
        case "starting", "needs_login", "running":
            return runtimeStatus.message
        default:
            return nil
        }
    }

    var availabilityMessage: String? {
        guard runtimeStatus.state == "error" else { return nil }
        return runtimeStatus.message
    }

    nonisolated static func setupArguments(dataDir: String) -> [String] {
        [
            "setup-tailscale",
            "--data-dir", dataDir,
        ]
    }

    nonisolated static func shouldReclaimSetupListener(commandLine: String, executablePath: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let commandExecutablePath = Self.executablePath(fromCommandLine: trimmed),
              sameExecutablePath(commandExecutablePath, executablePath) else {
            return false
        }
        return trimmed.split(whereSeparator: \.isWhitespace).contains("setup-tailscale")
    }

    func runSetup() async throws {
        stopSetup(clearStatus: false)
        runtimeStatus = .idle.applyingMarkerLine("TINCAN_TAILSCALE_STATUS=starting")
        try prepareSetupLog()

        let process = Process()
        let executableURL = try executableURLProvider()
        try await reclaimSetupPortListenerIfNeeded(executableURL: executableURL)
        process.executableURL = executableURL
        process.currentDirectoryURL = process.executableURL?.deletingLastPathComponent()
        process.arguments = Self.setupArguments(dataDir: AppPaths.appSupportDirectory.path)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.handleProcessOutputData(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.handleProcessOutputData(data)
            }
        }

        setupProcess = process

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { [weak self] terminatedProcess in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil

                    Task { @MainActor [weak self] in
                        self?.closeSetupLog()
                        guard self?.setupProcess === terminatedProcess else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        self?.setupProcess = nil
                        if terminatedProcess.terminationStatus == 0 {
                            continuation.resume()
                        } else {
                            let message = self?.runtimeStatus.message ?? "Tailscale setup failed."
                            self?.runtimeStatus = self?.runtimeStatus.applyingMarkerLine("TINCAN_TAILSCALE_ERROR=\(message)") ?? .idle
                            continuation.resume(throwing: SetupError.processFailed(message))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    setupProcess = nil
                    closeSetupLog()
                    runtimeStatus = runtimeStatus.applyingMarkerLine("TINCAN_TAILSCALE_ERROR=\(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stopSetup(clearStatus: false)
            }
        }
    }

    func stopMonitoring(clearStatus: Bool) {
        stopSetup(clearStatus: clearStatus)
    }

    func startMonitoring() {
        // Runtime fallback state now comes from /healthz. Setup progress comes from runSetup().
    }

    func refreshStatus() {
        // Runtime fallback state now comes from /healthz. Setup progress comes from runSetup().
    }

    func applyStatusMarkerLine(_ line: String) {
        runtimeStatus = runtimeStatus.applyingMarkerLine(line)
    }

    private func stopSetup(clearStatus: Bool) {
        if let setupProcess, setupProcess.isRunning {
            setupProcess.terminate()
        }
        setupProcess = nil
        if clearStatus {
            runtimeStatus = .idle
        }
        closeSetupLog()
    }

    private func handleProcessOutputData(_ data: Data) {
        writeSetupLogData(data)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for line in lines {
                applyStatusMarkerLine(line)
            }
        }
    }

    private func prepareSetupLog() throws {
        closeSetupLog()
        let preparedLogFile = try BundledServerLogFilePolicy.prepareLogFile(at: AppPaths.tincanServerSetupTailscaleLogURL)
        setupLogHandle = preparedLogFile.handle
        writeSetupLogLine("mac launcher initialized setup-tailscale; log file at \(AppPaths.tincanServerSetupTailscaleLogURL.path)")
        if preparedLogFile.wasTruncated {
            writeSetupLogLine("truncated setup-tailscale log because it was \(preparedLogFile.existingSize) bytes")
        }
    }

    private func writeSetupLogData(_ data: Data) {
        guard !data.isEmpty, let setupLogHandle else { return }
        do {
            try setupLogHandle.seekToEnd()
            try setupLogHandle.write(contentsOf: data)
        } catch {
            NSLog("Failed writing setup-tailscale log data: %@", error.localizedDescription)
        }
    }

    private func writeSetupLogLine(_ message: String) {
        writeSetupLogData(Data("[\(Date())] \(message)\n".utf8))
    }

    private func closeSetupLog() {
        try? setupLogHandle?.close()
        setupLogHandle = nil
    }

    private func reclaimSetupPortListenerIfNeeded(executableURL: URL) async throws {
        let listenerPIDs = try BundledServerPortListenerLookup.listeningPIDs(on: 80)
        for pid in listenerPIDs {
            guard let commandLine = processCommandLine(pid),
                  Self.shouldReclaimSetupListener(commandLine: commandLine, executablePath: executableURL.path) else {
                continue
            }
            writeSetupLogLine("terminating existing setup-tailscale pid \(pid) on port 80")
            try await terminateProcess(pid)
        }
    }

    private func terminateProcess(_ pid: pid_t) async throws {
        guard isProcessRunning(pid) else { return }

        if kill(pid, SIGTERM) != 0 {
            let errorCode = errno
            guard errorCode != ESRCH else { return }
            throw SetupError.failedToTerminateSetupProcess(
                pid: pid,
                signal: SIGTERM,
                message: String(cString: strerror(errorCode))
            )
        }

        await waitForProcessToExit(pid, timeout: 5)
        guard !isProcessRunning(pid) else {
            if kill(pid, SIGKILL) != 0 {
                let errorCode = errno
                guard errorCode != ESRCH else { return }
                throw SetupError.failedToTerminateSetupProcess(
                    pid: pid,
                    signal: SIGKILL,
                    message: String(cString: strerror(errorCode))
                )
            }
            await waitForProcessToExit(pid, timeout: 2)
            guard !isProcessRunning(pid) else {
                throw SetupError.setupProcessDidNotExit(pid)
            }
            return
        }
    }

    private func waitForProcessToExit(_ pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning(pid) {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func processCommandLine(_ pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func resolveDefaultExecutableURL() throws -> URL {
        for runtimeRootURL in runtimeRootCandidates {
            let executableURL = runtimeRootURL.appendingPathComponent("tincan-server", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }

        throw SetupError.missingBundledRuntime(runtimeRootCandidates.map(\.path))
    }

    nonisolated private static var runtimeRootCandidates: [URL] {
        var candidates: [URL] = []
        if let bundleResourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("BundledRuntime", isDirectory: true) {
            candidates.append(bundleResourceURL)
        }
        candidates.append(AppPaths.projectRoot.appendingPathComponent("BundledRuntime", isDirectory: true))
        return candidates
    }

    nonisolated private static func executablePath(fromCommandLine commandLine: String) -> String? {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executable = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        let path = String(executable)
        return path.hasPrefix("/") ? path : nil
    }

    nonisolated private static func sameExecutablePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}

extension MacTailscaleServerController {
    enum SetupError: LocalizedError {
        case missingBundledRuntime([String])
        case processFailed(String)
        case failedToTerminateSetupProcess(pid: pid_t, signal: Int32, message: String)
        case setupProcessDidNotExit(pid_t)

        var errorDescription: String? {
            switch self {
            case .missingBundledRuntime(let paths):
                return "BundledRuntime/tincan-server was not found. Checked: \(paths.joined(separator: ", "))"
            case .processFailed(let message):
                return message
            case .failedToTerminateSetupProcess(let pid, let signal, let message):
                return "Failed to terminate setup-tailscale pid \(pid) with signal \(signal): \(message)"
            case .setupProcessDidNotExit(let pid):
                return "setup-tailscale pid \(pid) did not exit after termination attempts"
            }
        }
    }
}
#endif
