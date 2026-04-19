#if os(macOS)
import Combine
import Darwin
import Foundation

@MainActor
final class BackendServerController: ObservableObject {
    @Published private(set) var statusDescription = "Checking manual backend…"
    @Published private(set) var logLines: [String] = []

    let port: Int = BackendConnectionConfig.port

    private var isBackendReachable = false

    init() {
        appendLog("Manual backend mode enabled")
        appendLog("Run in Terminal: \(manualLaunchCommand)")
        refresh()
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

    var manualLaunchCommand: String {
        "cd \(AppPaths.projectRoot.path) && uv run python -m \(AppPaths.backendServerModule) --host \(BackendConnectionConfig.bindHost) --port \(port)"
    }

    func refresh() {
        Task {
            await refreshStatus()
        }
    }

    var loopbackHealthEndpoint: String {
        BackendConnectionConfig.loopbackHealthURLString
    }

    private func refreshStatus() async {
        let result = await backendHealthCheck()

        switch result {
        case .reachable:
            statusDescription = "Manual backend is reachable on 127.0.0.1:\(port)"
            if !isBackendReachable {
                appendLog("Health check passed on 127.0.0.1:\(port)")
            }
            isBackendReachable = true
        case let .unreachable(reason):
            statusDescription = "Start the backend manually on 127.0.0.1:\(port)"
            if isBackendReachable {
                appendLog("Backend became unreachable: \(reason)")
            } else {
                appendLog("Health check failed: \(reason)")
            }
            isBackendReachable = false
        }
    }

    private func backendHealthCheck() async -> BackendHealthResult {
        guard let url = URL(string: BackendConnectionConfig.loopbackHealthURLString) else {
            return .unreachable("invalid loopback health URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unreachable("health endpoint returned a non-HTTP response")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return .unreachable("health endpoint returned HTTP \(httpResponse.statusCode)")
            }

            return .reachable
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private func appendLog(_ rawLine: String) {
        for line in rawLine.split(whereSeparator: \.isNewline) {
            let rendered = String(line)
            guard !rendered.isEmpty else { continue }

            logLines.insert(rendered, at: 0)
            if logLines.count > 120 {
                logLines.removeLast(logLines.count - 120)
            }
        }
    }
}

private enum BackendHealthResult {
    case reachable
    case unreachable(String)
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
