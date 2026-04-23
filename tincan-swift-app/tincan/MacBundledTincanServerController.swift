#if os(macOS)
import AppKit
import Darwin
import Foundation

struct BundledServerLogFilePreparationResult {
    let handle: FileHandle
    let existingSize: UInt64
    let wasTruncated: Bool
}

enum BundledServerLogFilePolicy {
    static let truncationThresholdBytes: UInt64 = 1_048_576

    static func shouldTruncate(existingSize: UInt64) -> Bool {
        existingSize > truncationThresholdBytes
    }

    static func openLogFileForAppend(
        at logURL: URL,
        fileManager: FileManager = .default
    ) throws -> FileHandle {
        ensureLogFileExists(at: logURL, fileManager: fileManager)
        let handle = try FileHandle(forWritingTo: logURL)
        _ = try handle.seekToEnd()
        return handle
    }

    static func prepareLogFile(
        at logURL: URL,
        fileManager: FileManager = .default
    ) throws -> BundledServerLogFilePreparationResult {
        ensureLogFileExists(at: logURL, fileManager: fileManager)

        let existingSize = try currentSizeOfLogFile(at: logURL, fileManager: fileManager)
        let handle = try FileHandle(forWritingTo: logURL)
        let wasTruncated = shouldTruncate(existingSize: existingSize)
        if wasTruncated {
            try handle.truncate(atOffset: 0)
        }
        _ = try handle.seekToEnd()

        return BundledServerLogFilePreparationResult(
            handle: handle,
            existingSize: existingSize,
            wasTruncated: wasTruncated
        )
    }

    private static func currentSizeOfLogFile(
        at logURL: URL,
        fileManager: FileManager
    ) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        if let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private static func ensureLogFileExists(at logURL: URL, fileManager: FileManager) {
        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(atPath: logURL.path, contents: nil)
        }
    }
}

struct BundledServerPortListenerLookup {
    static func listeningPIDs(
        on port: Int,
        excluding excludedPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
    ) throws -> [pid_t] {
        let result = try runLsof(on: port)
        switch result.status {
        case 0:
            return parseListeningPIDs(from: result.stdout, excluding: excludedPIDs)
        case 1:
            return []
        default:
            throw LookupError.commandFailed(
                port: port,
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func parseListeningPIDs(
        from output: String,
        excluding excludedPIDs: Set<pid_t> = []
    ) -> [pid_t] {
        var seen = Set<pid_t>()
        var pids: [pid_t] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(trimmedLine),
                  !excludedPIDs.contains(pid),
                  seen.insert(pid).inserted else {
                continue
            }
            pids.append(pid)
        }

        return pids
    }

    private static func runLsof(on port: Int) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-nP",
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-t",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    enum LookupError: LocalizedError {
        case commandFailed(port: Int, status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let port, let status, let message):
                if message.isEmpty {
                    return "Failed to inspect listeners on port \(port) with lsof (exit \(status))"
                }
                return "Failed to inspect listeners on port \(port) with lsof (exit \(status)): \(message)"
            }
        }
    }
}

final class BundledServerLaunchLock {
    private let lockURL: URL
    private let fileDescriptor: Int32

    init(
        lockURL: URL = AppPaths.tincanServerLaunchLockURL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LockError.failedToOpen(
                path: lockURL.path,
                message: String(cString: strerror(errno))
            )
        }

        self.lockURL = lockURL
        fileDescriptor = descriptor
    }

    deinit {
        _ = close(fileDescriptor)
    }

    func withExclusiveAccess<T>(
        timeout: TimeInterval = 15,
        operation: () async throws -> T
    ) async throws -> T {
        try await acquire(timeout: timeout)
        defer { release() }
        return try await operation()
    }

    private func acquire(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return
            }

            let errorCode = errno
            guard errorCode == EWOULDBLOCK else {
                throw LockError.failedToAcquire(
                    path: lockURL.path,
                    message: String(cString: strerror(errorCode))
                )
            }

            guard Date() < deadline else {
                throw LockError.timedOut(path: lockURL.path, timeout: timeout)
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func release() {
        _ = flock(fileDescriptor, LOCK_UN)
    }

    enum LockError: LocalizedError {
        case failedToOpen(path: String, message: String)
        case failedToAcquire(path: String, message: String)
        case timedOut(path: String, timeout: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .failedToOpen(let path, let message):
                return "Failed to open bundled server launch lock at \(path): \(message)"
            case .failedToAcquire(let path, let message):
                return "Failed to acquire bundled server launch lock at \(path): \(message)"
            case .timedOut(let path, let timeout):
                return "Timed out waiting \(timeout)s for bundled server launch lock at \(path)"
            }
        }
    }
}

@MainActor
final class MacBundledTincanServerController {
    struct PortListenerDisposition: Equatable {
        let reclaimablePIDs: [pid_t]
        let blockingPIDs: [pid_t]
    }

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

    func startIfNeeded() async throws {
        prepareStartupLoggingIfNeeded()
        guard !Task.isCancelled else { throw CancellationError() }

        do {
            let repairResult = try LocalAgentBackendConfigRepair.repairOpencodeBackendsForLocalServer(
                at: AppPaths.generatedAgentBackendsURL
            )
            if repairResult.didRepair {
                writeStartupLog(
                    "repaired local opencode backend config for bundled server launch: \(repairResult.repairedBackendNames.joined(separator: ", "))"
                )
            }
        } catch {
            writeStartupLog("failed to repair local agent backend config: \(error.localizedDescription)")
        }

        if process?.isRunning == true {
            do {
                try await waitUntilReady(timeout: 10)
                writeStartupLog("bundled tincan-server already running and ready on port \(port)")
            } catch {
                writeStartupLog("bundled tincan-server is running but failed readiness check: \(error.localizedDescription)")
                NSLog("Bundled tincan-server is running but not ready: %@", error.localizedDescription)
                throw error
            }
            return
        }

        do {
            let launchLock = try BundledServerLaunchLock()
            try await launchLock.withExclusiveAccess {
                try Task.checkCancellation()
                let executableURL = try resolveExecutableURL()
                await reclaimTrackedBundledServerIfNeeded(executableURL: executableURL)
                try Task.checkCancellation()
                try await reclaimPortListenersIfNeeded(executableURL: executableURL)
                try Task.checkCancellation()
                try applyStartupLogCleanupIfNeeded()
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
                writeTrackedProcessID(process.processIdentifier)
                writeStartupLog("bundled tincan-server started with pid \(process.processIdentifier)")
                try await waitUntilReady(timeout: 10)
                writeStartupLog("bundled tincan-server became ready on port \(port)")
            }
        } catch is CancellationError {
            writeStartupLog("bundled tincan-server launch was cancelled")
            throw CancellationError()
        } catch {
            writeStartupLog("failed to start bundled tincan-server: \(error.localizedDescription)")
            if process == nil {
                finishProcessRun()
            }
            NSLog("Failed to start bundled tincan-server: %@", error.localizedDescription)
            throw error
        }
    }

    func restart() async throws {
        prepareStartupLoggingIfNeeded()
        stop()
        try await startIfNeeded()
    }

    func sendSecretUpdates(_ updates: [String: String]) async throws {
        try await TincanServerControlSocketClient(socketURL: AppPaths.tincanServerSocketURL).sendSecrets(updates)
    }

    func syncStoredSecretsFromKeychain() async throws {
        let updates = try storedSecretUpdatesFromKeychain()
        guard !updates.isEmpty else { return }
        try await sendSecretUpdates(updates)
    }

    private func reclaimPortListenersIfNeeded(executableURL: URL) async throws {
        let listenerPIDs = try BundledServerPortListenerLookup.listeningPIDs(on: port)
        guard !listenerPIDs.isEmpty else { return }

        let disposition = Self.classifyPortListeners(
            listenerPIDs,
            bundledExecutablePath: executableURL.path,
            processExecutablePath: processExecutablePath(_:)
        )

        if !disposition.reclaimablePIDs.isEmpty {
            writeStartupLog(
                "reclaiming port \(port) by terminating bundled listener pid(s): \(disposition.reclaimablePIDs.map(String.init).joined(separator: ", "))"
            )
        }

        for pid in disposition.reclaimablePIDs {
            let executablePath = processExecutablePath(pid) ?? "unknown executable"
            writeStartupLog("terminating pid \(pid) listening on port \(port) (\(executablePath))")
            try await terminatePortListener(pid)
        }

        if !disposition.blockingPIDs.isEmpty {
            let blockingDescriptions = disposition.blockingPIDs.map { pid in
                let executablePath = processExecutablePath(pid) ?? "unknown executable"
                return "\(pid) (\(executablePath))"
            }
            writeStartupLog(
                "port \(port) is occupied by non-bundled listener pid(s): \(blockingDescriptions.joined(separator: ", "))"
            )
        }

        let remainingPIDs = try BundledServerPortListenerLookup.listeningPIDs(on: port)
        guard remainingPIDs.isEmpty else {
            throw LaunchError.portStillOccupied(port, remainingPIDs)
        }

        writeStartupLog("port \(port) is clear for bundled tincan-server launch")
    }

    func stop() {
        prepareStartupLoggingIfNeeded()

        guard let process, process.isRunning else {
            do {
                let executableURL = try resolveExecutableURL()
                terminateTrackedBundledServerIfNeeded(executableURL: executableURL)
            } catch {
                writeStartupLog("failed to resolve bundled tincan-server during stop: \(error.localizedDescription)")
            }
            finishProcessRun()
            return
        }

        process.terminate()
        process.waitUntilExit()
        finishProcessRun()
    }

    private func reclaimTrackedBundledServerIfNeeded(executableURL: URL) async {
        guard let trackedPID = readTrackedProcessID() else { return }

        guard isProcessRunning(trackedPID) else {
            clearTrackedProcessID()
            writeStartupLog("removed stale tincan-server pid file for pid \(trackedPID)")
            return
        }

        guard let executablePath = processExecutablePath(trackedPID),
              Self.sameBundledExecutablePath(executablePath, executableURL.path) else {
            writeStartupLog("tracked tincan-server pid \(trackedPID) does not match this bundled runtime; leaving it untouched")
            clearTrackedProcessID()
            return
        }

        writeStartupLog("terminating stale bundled tincan-server pid \(trackedPID) from previous app run")

        guard kill(trackedPID, SIGTERM) == 0 else {
            writeStartupLog("failed to terminate stale bundled tincan-server pid \(trackedPID): \(String(cString: strerror(errno)))")
            return
        }

        await waitForProcessToExit(trackedPID, timeout: 5)

        if isProcessRunning(trackedPID) {
            writeStartupLog("stale bundled tincan-server pid \(trackedPID) did not exit after SIGTERM")
            return
        }

        clearTrackedProcessID()
        writeStartupLog("stale bundled tincan-server pid \(trackedPID) exited")
    }

    private func terminateTrackedBundledServerIfNeeded(executableURL: URL) {
        guard let trackedPID = readTrackedProcessID() else { return }

        guard isProcessRunning(trackedPID) else {
            clearTrackedProcessID()
            writeStartupLog("removed stale tincan-server pid file for pid \(trackedPID) during stop")
            return
        }

        guard let executablePath = processExecutablePath(trackedPID),
              Self.sameBundledExecutablePath(executablePath, executableURL.path) else {
            writeStartupLog(
                "tracked tincan-server pid \(trackedPID) does not match this bundled runtime during stop; leaving it running"
            )
            return
        }

        writeStartupLog("terminating tracked bundled tincan-server pid \(trackedPID) during stop")

        if kill(trackedPID, SIGTERM) != 0 {
            let errorCode = errno
            guard errorCode != ESRCH else {
                clearTrackedProcessID()
                writeStartupLog("tracked bundled tincan-server pid \(trackedPID) exited before stop could terminate it")
                return
            }
            writeStartupLog(
                "failed to terminate tracked bundled tincan-server pid \(trackedPID): \(String(cString: strerror(errorCode)))"
            )
            return
        }

        waitForProcessToExitSynchronously(trackedPID, timeout: 5)

        if isProcessRunning(trackedPID) {
            writeStartupLog("tracked bundled tincan-server pid \(trackedPID) did not exit after SIGTERM; sending SIGKILL")

            if kill(trackedPID, SIGKILL) != 0 {
                let errorCode = errno
                guard errorCode != ESRCH else {
                    clearTrackedProcessID()
                    writeStartupLog("tracked bundled tincan-server pid \(trackedPID) exited before SIGKILL was delivered")
                    return
                }
                writeStartupLog(
                    "failed to force-terminate tracked bundled tincan-server pid \(trackedPID): \(String(cString: strerror(errorCode)))"
                )
                return
            }

            waitForProcessToExitSynchronously(trackedPID, timeout: 2)
        }

        guard !isProcessRunning(trackedPID) else {
            writeStartupLog("tracked bundled tincan-server pid \(trackedPID) did not exit during stop")
            return
        }

        clearTrackedProcessID()
        writeStartupLog("tracked bundled tincan-server pid \(trackedPID) exited during stop")
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

    private func waitUntilReady(timeout: TimeInterval) async throws {
        try await waitUntilReachable(timeout: timeout)
        try await waitUntilControlSocketAvailable(timeout: timeout)
    }

    private func waitUntilControlSocketAvailable(timeout: TimeInterval) async throws {
        let socketURL = AppPaths.tincanServerSocketURL
        let client = TincanServerControlSocketClient(socketURL: socketURL)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                try await client.ping()
                return
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw LaunchError.controlSocketDidNotBecomeAvailable(
            path: socketURL.path,
            reason: lastError?.localizedDescription
        )
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

    private func waitForProcessToExitSynchronously(_ pid: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning(pid) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func terminatePortListener(_ pid: pid_t) async throws {
        guard isProcessRunning(pid) else {
            clearTrackedProcessIDIfMatches(pid)
            return
        }

        if kill(pid, SIGTERM) != 0 {
            let errorCode = errno
            guard errorCode != ESRCH else {
                clearTrackedProcessIDIfMatches(pid)
                return
            }
            throw LaunchError.failedToTerminatePortListener(
                port: port,
                pid: pid,
                signal: SIGTERM,
                message: String(cString: strerror(errorCode))
            )
        }

        await waitForProcessToExit(pid, timeout: 5)

        if isProcessRunning(pid) {
            writeStartupLog("pid \(pid) on port \(port) did not exit after SIGTERM; sending SIGKILL")

            if kill(pid, SIGKILL) != 0 {
                let errorCode = errno
                guard errorCode != ESRCH else {
                    clearTrackedProcessIDIfMatches(pid)
                    return
                }
                throw LaunchError.failedToTerminatePortListener(
                    port: port,
                    pid: pid,
                    signal: SIGKILL,
                    message: String(cString: strerror(errorCode))
                )
            }

            await waitForProcessToExit(pid, timeout: 2)
        }

        guard !isProcessRunning(pid) else {
            throw LaunchError.portListenerDidNotExit(port: port, pid: pid)
        }

        clearTrackedProcessIDIfMatches(pid)
        writeStartupLog("terminated pid \(pid) that was listening on port \(port)")
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
            logHandle = try BundledServerLogFilePolicy.openLogFileForAppend(at: AppPaths.tincanServerLogURL)
            writeStartupLog("mac launcher initialized; log file at \(AppPaths.tincanServerLogURL.path)")
        } catch {
            NSLog("Failed to prepare tincan-server log file: %@", error.localizedDescription)
        }
    }

    private func applyStartupLogCleanupIfNeeded() throws {
        try? logHandle?.close()

        let preparedLogFile = try prepareLogFile()
        logHandle = preparedLogFile.handle
        if preparedLogFile.wasTruncated {
            writeStartupLog(
                "truncated tincan-server log before launch because it was \(preparedLogFile.existingSize) bytes"
            )
        }
    }

    private func prepareLogFile() throws -> BundledServerLogFilePreparationResult {
        try BundledServerLogFilePolicy.prepareLogFile(at: AppPaths.tincanServerLogURL)
    }

    private func storedSecretUpdatesFromKeychain() throws -> [String: String] {
        let keychain = MacKeychainService()
        let account = TincanSpeechSettingsStore.grokAPIKeyAccount
        let hasStoredValue = try keychain.containsValue(account: account)
        guard hasStoredValue else {
            return [account: ""]
        }

        do {
            let storedValue = try keychain.value(account: account)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [account: storedValue ?? ""]
        } catch let error as KeychainError where error.isNonFatalReadAuthorizationFailure {
            writeStartupLog("skipping bundled server secret sync for \(account) because keychain denied secret bytes")
            return [:]
        }
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

    private func readTrackedProcessID() -> pid_t? {
        guard let data = try? Data(contentsOf: AppPaths.tincanServerPIDURL),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text) else {
            return nil
        }
        return pid
    }

    private func writeTrackedProcessID(_ pid: pid_t) {
        do {
            try Data("\(pid)\n".utf8).write(to: AppPaths.tincanServerPIDURL, options: .atomic)
        } catch {
            writeStartupLog("failed to write tincan-server pid file: \(error.localizedDescription)")
        }
    }

    private func clearTrackedProcessID() {
        try? FileManager.default.removeItem(at: AppPaths.tincanServerPIDURL)
    }

    private func clearTrackedProcessIDIfMatches(_ pid: pid_t) {
        guard readTrackedProcessID() == pid else { return }
        clearTrackedProcessID()
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated static func classifyPortListeners(
        _ listenerPIDs: [pid_t],
        bundledExecutablePath: String,
        processExecutablePath: (pid_t) -> String?
    ) -> PortListenerDisposition {
        var reclaimablePIDs: [pid_t] = []
        var blockingPIDs: [pid_t] = []

        for pid in listenerPIDs {
            guard let executablePath = processExecutablePath(pid) else {
                blockingPIDs.append(pid)
                continue
            }

            if sameBundledExecutablePath(executablePath, bundledExecutablePath) {
                reclaimablePIDs.append(pid)
            } else {
                blockingPIDs.append(pid)
            }
        }

        return PortListenerDisposition(
            reclaimablePIDs: reclaimablePIDs,
            blockingPIDs: blockingPIDs
        )
    }

    nonisolated static func sameBundledExecutablePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }

    private func finishProcessRun() {
        if let process {
            writeStartupLog("bundled tincan-server exited with status \(process.terminationStatus)")
            clearTrackedProcessIDIfMatches(process.processIdentifier)
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
        case controlSocketDidNotBecomeAvailable(path: String, reason: String?)
        case logFileUnavailable(String)
        case failedToTerminatePortListener(port: Int, pid: pid_t, signal: Int32, message: String)
        case portListenerDidNotExit(port: Int, pid: pid_t)
        case portStillOccupied(Int, [pid_t])

        var errorDescription: String? {
            switch self {
            case .missingBundledRuntime(let candidatePaths):
                return "BundledRuntime/tincan-server was not found. Checked: \(candidatePaths.joined(separator: ", "))"
            case .serverDidNotBecomeHealthy(let port):
                return "tincan-server did not become healthy on port \(port)"
            case .controlSocketDidNotBecomeAvailable(let path, let reason):
                let suffix = reason.map { " Last error: \($0)" } ?? ""
                return "tincan-server control socket did not become available at \(path). " +
                    "The bundled runtime may be stale; rebuild it with ./build-deps.sh --skip-model-downloads.\(suffix)"
            case .logFileUnavailable(let path):
                return "tincan-server log file could not be opened at \(path)"
            case .failedToTerminatePortListener(let port, let pid, let signal, let message):
                return "Failed to terminate pid \(pid) that is listening on port \(port) with signal \(signal): \(message)"
            case .portListenerDidNotExit(let port, let pid):
                return "pid \(pid) kept listening on port \(port) after termination attempts"
            case .portStillOccupied(let port, let pids):
                return "Port \(port) is still occupied after reclaim attempt by pid(s): \(pids.map(String.init).joined(separator: ", "))"
            }
        }
    }
}
#endif
