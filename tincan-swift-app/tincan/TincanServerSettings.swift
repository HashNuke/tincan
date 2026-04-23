import Combine
import Foundation

@MainActor
final class ServerConnectionStore: ObservableObject {
    enum ConnectionMode: String, CaseIterable, Identifiable {
        case localMac
        case remote

        var id: String { rawValue }

        var title: String {
            switch self {
            case .localMac:
                return "Run on this Mac"
            case .remote:
                return "Connect remote"
            }
        }
    }

    enum HealthStatus: Equatable {
        case idle
        case checking
        case connected(agentProfileCount: Int, checkedAt: Date)
        case unreachable(message: String, checkedAt: Date)

        var checkedAt: Date? {
            switch self {
            case .connected(_, let checkedAt), .unreachable(_, let checkedAt):
                return checkedAt
            case .idle, .checking:
                return nil
            }
        }
    }

    @Published private(set) var connectionMode: ConnectionMode
    @Published var draftHost: String
    @Published var draftPort: String
    @Published private(set) var configuredRemoteHost: String
    @Published private(set) var configuredPort: Int
    @Published private(set) var connectionRevision: Int = 0
    @Published private(set) var healthStatus: HealthStatus = .idle

    private let defaults: UserDefaults

    private static let connectionModeKey = "server_connection_mode"
    private static let configuredHostKey = "server_configured_host"
    private static let configuredPortKey = "server_configured_port"
    private static let legacyBackendURLKey = "backend_url"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let persistedEndpoint = Self.loadPersistedEndpoint(defaults: defaults)
        configuredRemoteHost = persistedEndpoint.host
        configuredPort = persistedEndpoint.port
        draftHost = persistedEndpoint.host
        draftPort = String(persistedEndpoint.port)

#if os(macOS)
        let defaultMode: ConnectionMode = .localMac
#else
        let defaultMode: ConnectionMode = .remote
#endif

        connectionMode = ConnectionMode(
            rawValue: defaults.string(forKey: Self.connectionModeKey) ?? ""
        ) ?? defaultMode
    }

    var serverBaseURL: URL? {
        let host: String
        switch connectionMode {
        case .localMac:
            host = "127.0.0.1"
        case .remote:
            host = configuredRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = activePort
        return components.url
    }

    var liveUpdatesURL: URL? {
        guard let baseURL = serverBaseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/live"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var liveUpdatesOriginHeaderValue: String? {
        serverBaseURL?.absoluteString
    }

    var shareableHost: String {
        switch connectionMode {
        case .localMac:
            return BackendConnectionConfig.publicHost
        case .remote:
            return configuredRemoteHost
        }
    }

    var shareableConnectionLabel: String {
        "\(shareableHost):\(activePort)"
    }

    var qrPayload: String {
        "tincan://connect?host=\(shareableHost)&port=\(activePort)"
    }

    func setConnectionMode(_ mode: ConnectionMode) {
        guard connectionMode != mode else { return }
        connectionMode = mode
        defaults.set(mode.rawValue, forKey: Self.connectionModeKey)
        connectionRevision += 1
    }

    @discardableResult
    func applyRemoteDraft() -> Bool {
        let host = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(draftPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            return false
        }

        configuredRemoteHost = host
        configuredPort = port
        persistEndpoint()
        connectionRevision += 1
        return true
    }

    func refreshHealth() async {
        guard let url = serverBaseURL?.appendingPathComponent(BackendConnectionConfig.healthPath) else {
            healthStatus = .unreachable(message: "Connection target is incomplete.", checkedAt: Date())
            return
        }

        healthStatus = .checking

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let health = try TincanAPIClient.decodeHealthResponse(from: data)
            healthStatus = .connected(agentProfileCount: health.agentProfileCount, checkedAt: Date())
        } catch {
            healthStatus = .unreachable(message: error.localizedDescription, checkedAt: Date())
        }
    }

    private func persistEndpoint() {
        defaults.set(configuredRemoteHost, forKey: Self.configuredHostKey)
        defaults.set(configuredPort, forKey: Self.configuredPortKey)
    }

    private var activePort: Int {
        switch connectionMode {
        case .localMac:
            return BackendConnectionConfig.port
        case .remote:
            return configuredPort
        }
    }

    private static func loadPersistedEndpoint(defaults: UserDefaults) -> (host: String, port: Int) {
        let persistedHost = defaults.string(forKey: configuredHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedPort = defaults.integer(forKey: configuredPortKey)

        if let persistedHost, !persistedHost.isEmpty, persistedPort > 0 {
            return (persistedHost, persistedPort)
        }

        if let legacyValue = defaults.string(forKey: legacyBackendURLKey),
           let components = URLComponents(string: legacyValue),
           let host = components.host,
           let port = components.port {
            return (host, port)
        }

        return (BackendConnectionConfig.publicHost, BackendConnectionConfig.port)
    }
}
