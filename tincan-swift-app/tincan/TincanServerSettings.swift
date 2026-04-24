import Combine
import Foundation

@MainActor
final class ServerConnectionStore: ObservableObject {
    enum Scheme: String, CaseIterable, Identifiable {
        case http
        case https

        var id: String { rawValue }

        var title: String {
            rawValue.uppercased()
        }

        var websocketScheme: String {
            switch self {
            case .http:
                return "ws"
            case .https:
                return "wss"
            }
        }
    }

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
    @Published var draftScheme: Scheme
    @Published var draftHost: String
    @Published var draftPort: String
    @Published private(set) var configuredScheme: Scheme
    @Published private(set) var configuredRemoteHost: String
    @Published private(set) var configuredPort: Int
    @Published private(set) var hasExplicitEndpointConfiguration: Bool
    @Published private(set) var connectionRevision: Int = 0
    @Published private(set) var healthStatus: HealthStatus = .idle

    private let defaults: UserDefaults

    private static let connectionModeKey = "server_connection_mode"
    private static let configuredSchemeKey = "server_configured_scheme"
    private static let configuredHostKey = "server_configured_host"
    private static let configuredPortKey = "server_configured_port"
    private static let legacyBackendURLKey = "backend_url"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let persistedEndpoint = Self.loadPersistedEndpoint(defaults: defaults)
        configuredScheme = persistedEndpoint.scheme
        configuredRemoteHost = persistedEndpoint.host
        configuredPort = persistedEndpoint.port
        hasExplicitEndpointConfiguration = persistedEndpoint.isExplicit
        draftScheme = persistedEndpoint.scheme
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
        let scheme = effectiveScheme
        let host = effectiveHost
        let port = effectivePort

        guard !host.isEmpty, port > 0 else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        return components.url
    }

    var shouldUseBundledServer: Bool {
        !hasExplicitEndpointConfiguration
    }

    var liveUpdatesURL: URL? {
        guard let baseURL = serverBaseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = effectiveScheme.websocketScheme
        components.path = "/api/v1/live"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var liveUpdatesOriginHeaderValue: String? {
        serverBaseURL?.absoluteString
    }

    var shareableHost: String {
        if shouldUseBundledServer {
            return BackendConnectionConfig.publicHost
        }

        return configuredRemoteHost
    }

    var shareableConnectionLabel: String {
        "\(effectiveScheme.rawValue)://\(shareableHost):\(effectivePort)"
    }

    var qrPayload: String {
        "tincan://connect?scheme=\(effectiveScheme.rawValue)&host=\(shareableHost)&port=\(effectivePort)"
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

        configuredScheme = draftScheme
        configuredRemoteHost = host
        configuredPort = port
        hasExplicitEndpointConfiguration = true
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
        defaults.set(configuredScheme.rawValue, forKey: Self.configuredSchemeKey)
        defaults.set(configuredRemoteHost, forKey: Self.configuredHostKey)
        defaults.set(configuredPort, forKey: Self.configuredPortKey)
    }

    private var effectiveScheme: Scheme {
        if shouldUseBundledServer {
            return .http
        }

        return configuredScheme
    }

    private var effectiveHost: String {
        if shouldUseBundledServer {
            return "127.0.0.1"
        }

        return configuredRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectivePort: Int {
        if shouldUseBundledServer {
            return BackendConnectionConfig.port
        }

        return configuredPort
    }

    private static func loadPersistedEndpoint(defaults: UserDefaults) -> (scheme: Scheme, host: String, port: Int, isExplicit: Bool) {
        let persistedScheme = Scheme(rawValue: defaults.string(forKey: configuredSchemeKey) ?? "") ?? .http
        let persistedHost = defaults.string(forKey: configuredHostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedPort = defaults.integer(forKey: configuredPortKey)
        let hasPersistedScheme = defaults.object(forKey: configuredSchemeKey) != nil
        let hasPersistedHost = defaults.object(forKey: configuredHostKey) != nil
        let hasPersistedPort = defaults.object(forKey: configuredPortKey) != nil

        if hasPersistedHost, hasPersistedPort, let persistedHost, !persistedHost.isEmpty, persistedPort > 0 {
            let scheme = hasPersistedScheme ? persistedScheme : .http
            return (scheme, persistedHost, persistedPort, true)
        }

        if let legacyValue = defaults.string(forKey: legacyBackendURLKey),
           let components = URLComponents(string: legacyValue),
           let scheme = components.scheme.flatMap(Scheme.init(rawValue:)),
           let host = components.host,
           let port = components.port {
            return (scheme, host, port, true)
        }

        return (.http, BackendConnectionConfig.publicHost, BackendConnectionConfig.port, false)
    }
}
