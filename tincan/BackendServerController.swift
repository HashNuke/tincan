#if os(macOS)
import Combine
import Darwin
import Foundation

@MainActor
final class BackendServerController: ObservableObject {
    @Published private(set) var statusDescription = "Starting local backend…"
    @Published private(set) var recentTranscripts: [String] = []
    @Published private(set) var logLines: [String] = []

    let port: Int = BackendConnectionConfig.port

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init() {
        Task {
            await start()
        }
    }

    var availableEndpoints: [String] {
        var endpoints = [
            BackendConnectionConfig.inferenceURLString,
            BackendConnectionConfig.loopbackInferenceURLString,
        ]

        for address in NetworkAddressProvider.localIPv4Addresses() {
            let endpoint = "http://\(address):\(port)\(BackendConnectionConfig.inferencePath)"
            if !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }

        return endpoints
    }

    var primaryEndpoint: String? {
        BackendConnectionConfig.inferenceURLString
    }

    func restart() {
        stop()
        Task {
            await start()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        statusDescription = "Backend stopped"
        appendLog("Stopped backend process")
    }

    private func start() async {
        guard process?.isRunning != true else { return }
        statusDescription = "Starting local backend…"

        if await isExistingBackendReachable() {
            statusDescription = "Backend already running on \(BackendConnectionConfig.bindHost):\(port)"
            appendLog("Reusing existing backend on 127.0.0.1:\(port)")
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.currentDirectoryURL = AppPaths.projectRoot
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "uv run python -m \(AppPaths.backendServerModule) --host \(BackendConnectionConfig.bindHost) --port \(port)",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendLog(line)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendLog(line)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            statusDescription = "Backend running on \(BackendConnectionConfig.bindHost):\(port)"
            appendLog("Started backend in \(AppPaths.projectRoot.path)")
        } catch {
            statusDescription = "Failed to launch backend"
            appendLog("Launch failed: \(error.localizedDescription)")
        }
    }

    private func handleTermination(status: Int32) async {
        process = nil

        if status == 1, await isExistingBackendReachable() {
            statusDescription = "Backend already running on \(BackendConnectionConfig.bindHost):\(port)"
            appendLog("Backend launch found an existing server on port \(port); using that instance")
            return
        }

        statusDescription = "Backend exited with code \(status)"
        appendLog("Backend exited")
    }

    private func isExistingBackendReachable() async -> Bool {
        guard let url = URL(string: BackendConnectionConfig.loopbackHealthURLString) else {
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

    private func appendLog(_ rawLine: String) {
        for line in rawLine.split(whereSeparator: \.isNewline) {
            let rendered = String(line)
            guard !rendered.isEmpty else { continue }

            if let transcript = transcriptPayload(from: rendered) {
                recentTranscripts.insert(transcript, at: 0)
                if recentTranscripts.count > 12 {
                    recentTranscripts.removeLast(recentTranscripts.count - 12)
                }
            }

            logLines.insert(rendered, at: 0)
            if logLines.count > 120 {
                logLines.removeLast(logLines.count - 120)
            }
        }
    }

    private func transcriptPayload(from logLine: String) -> String? {
        let marker = "[tincan-backend] transcript"
        guard logLine.hasPrefix(marker), let separatorRange = logLine.range(of: ": ") else {
            return nil
        }

        let transcript = String(logLine[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return transcript.isEmpty ? nil : transcript
    }
}

private enum NetworkAddressProvider {
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var addressesPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addressesPointer) == 0, let firstAddress = addressesPointer else {
            return result
        }

        defer { freeifaddrs(addressesPointer) }

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr else { continue }
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isRunning = (flags & IFF_RUNNING) == IFF_RUNNING
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            guard isUp, isRunning, !isLoopback else { continue }
            guard addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addressLength = socklen_t(addressPointer.pointee.sa_len)
            let resultCode = getnameinfo(
                addressPointer,
                addressLength,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard resultCode == 0 else { continue }

            let address = String(cString: hostBuffer)
            if !result.contains(address) {
                result.append(address)
            }
        }

        return result.sorted()
    }
}
#endif
