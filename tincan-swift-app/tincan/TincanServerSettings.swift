import Combine
import Foundation

@MainActor
final class ServerConnectionStore: ObservableObject {
    enum ConnectionPayloadError: LocalizedError {
        case invalidURL
        case unsupportedScheme
        case missingHost
        case missingPort

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The scanned QR code did not contain a valid tincan connection URL."
            case .unsupportedScheme:
                return "The scanned QR code used an unsupported connection scheme."
            case .missingHost:
                return "The scanned QR code did not include a server host."
            case .missingPort:
                return "The scanned QR code did not include a valid server port."
            }
        }
    }

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

        var defaultPort: Int {
            switch self {
            case .http:
                return 80
            case .https:
                return 443
            }
        }
    }

    enum ConnectionMode: String, CaseIterable, Identifiable {
        case localMac
        case remote

        var id: String { rawValue }

        var configValue: String {
            switch self {
            case .localMac:
                return "local"
            case .remote:
                return "remote"
            }
        }

        init?(configValue: String) {
            switch configValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "local":
                self = .localMac
            case "remote":
                self = .remote
            default:
                return nil
            }
        }

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
    @Published var draftServerURL: String
    @Published private(set) var configuredScheme: Scheme
    @Published private(set) var configuredRemoteHost: String
    @Published private(set) var configuredPort: Int
    @Published private(set) var hasExplicitEndpointConfiguration: Bool
    @Published private(set) var connectionRevision: Int = 0
    @Published private(set) var healthStatus: HealthStatus = .idle
    @Published var connectPhoneEnabled: Bool
    @Published private(set) var isApplyingServerURL = false
    @Published private(set) var serverURLApplyMessage: String?

    private let defaults: UserDefaults
    private let configURL: URL
    private let fileManager: FileManager

    private static let connectionModeKey = "server_connection_mode"
    private static let configuredSchemeKey = "server_configured_scheme"
    private static let configuredHostKey = "server_configured_host"
    private static let configuredPortKey = "server_configured_port"
    private static let legacyBackendURLKey = "backend_url"

    init(
        defaults: UserDefaults = .standard,
        configURL: URL = AppPaths.generatedAppConfigURL,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.configURL = configURL
        self.fileManager = fileManager
        connectionMode = .remote
        draftScheme = .http
        draftHost = BackendConnectionConfig.publicHost
        draftPort = String(BackendConnectionConfig.port)
        draftServerURL = ""
        configuredScheme = .http
        configuredRemoteHost = BackendConnectionConfig.publicHost
        configuredPort = BackendConnectionConfig.port
        hasExplicitEndpointConfiguration = false
        connectPhoneEnabled = false
        restorePersistedConfiguration()
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
        connectionMode == .localMac
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
        if mode == .remote, !hasExplicitEndpointConfiguration {
            return
        }
        guard connectionMode != mode else { return }
        connectionMode = mode
        defaults.set(mode.rawValue, forKey: Self.connectionModeKey)
        persistConnectionTarget()
        connectionRevision += 1
    }

    func useBundledServer() {
        connectionMode = .localMac
        defaults.set(ConnectionMode.localMac.rawValue, forKey: Self.connectionModeKey)
        persistConnectionTarget()
        connectionRevision += 1
    }

    @discardableResult
    func setRemoteServerEnabled(_ isEnabled: Bool) -> Bool {
        if isEnabled {
            guard hasExplicitEndpointConfiguration else {
                serverURLApplyMessage = "Enter and save a server URL first."
                return false
            }
            setConnectionMode(.remote)
            return connectionMode == .remote
        }

        useBundledServer()
        return true
    }

    func setConnectPhoneEnabled(_ isEnabled: Bool) {
        guard connectPhoneEnabled != isEnabled else { return }
        connectPhoneEnabled = isEnabled
        updateConfig { payload in
            var tailscalePayload = payload["tailscale"] as? [String: Any] ?? [:]
            tailscalePayload["enabled"] = isEnabled
            payload["tailscale"] = tailscalePayload
        }
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
        draftServerURL = Self.urlString(scheme: draftScheme, host: host, port: port)
        persistEndpoint()
        setConnectionMode(.remote)
        connectionRevision += 1
        return true
    }

    func applyServerURLDraftWithHealthRetry() async -> Bool {
        guard !isApplyingServerURL else { return false }

        let trimmedURL = draftServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let endpoint = try Self.validatedEndpoint(from: trimmedURL)
            isApplyingServerURL = true
            serverURLApplyMessage = "Checking server..."
            defer { isApplyingServerURL = false }

            let deadline = Date().addingTimeInterval(60)
            var attempt = 1
            while true {
                do {
                    let agentCount = try await checkHealth(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.port)
                    applyRemoteEndpoint(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.port)
                    healthStatus = .connected(agentProfileCount: agentCount, checkedAt: Date())
                    serverURLApplyMessage = "Connected."
                    return true
                } catch {
                    healthStatus = .unreachable(message: error.localizedDescription, checkedAt: Date())
                    guard Date().addingTimeInterval(5) <= deadline else {
                        serverURLApplyMessage = "Could not reach server after 60 seconds."
                        return false
                    }
                    attempt += 1
                    serverURLApplyMessage = "Waiting for server... attempt \(attempt)"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        } catch {
            healthStatus = .unreachable(message: error.localizedDescription, checkedAt: Date())
            serverURLApplyMessage = error.localizedDescription
            return false
        }
    }

    func applyConnectionPayload(_ payload: String) throws {
        guard let url = URL(string: payload) else {
            throw ConnectionPayloadError.invalidURL
        }
        try applyConnectionURL(url)
    }

    func stageConnectionPayload(_ payload: String) throws {
        guard let url = URL(string: payload) else {
            throw ConnectionPayloadError.invalidURL
        }
        let endpoint = try Self.validatedEndpoint(from: url)
        draftServerURL = Self.urlString(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.port)
    }

    func applyConnectionURL(_ url: URL) throws {
        if url.scheme == "tincan" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ConnectionPayloadError.invalidURL
            }
            let queryItems = components.queryItems ?? []
            guard let schemeValue = queryItems.first(where: { $0.name == "scheme" })?.value,
                  let scheme = Scheme(rawValue: schemeValue) else {
                throw ConnectionPayloadError.unsupportedScheme
            }
            guard let host = queryItems.first(where: { $0.name == "host" })?.value,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionPayloadError.missingHost
            }
            guard let portValue = queryItems.first(where: { $0.name == "port" })?.value,
                  let port = Int(portValue),
                  port > 0 else {
                throw ConnectionPayloadError.missingPort
            }
            applyRemoteEndpoint(scheme: scheme, host: host, port: port)
            return
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionPayloadError.invalidURL
        }
        guard let schemeValue = components.scheme,
              let scheme = Scheme(rawValue: schemeValue) else {
            throw ConnectionPayloadError.unsupportedScheme
        }
        guard let host = components.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionPayloadError.missingHost
        }
        let port = components.port ?? scheme.defaultPort
        applyRemoteEndpoint(scheme: scheme, host: host, port: port)
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

    func resetAppConfiguration() {
        if fileManager.fileExists(atPath: configURL.path) {
            try? fileManager.removeItem(at: configURL)
        }

        defaults.removeObject(forKey: Self.connectionModeKey)
        defaults.removeObject(forKey: Self.configuredSchemeKey)
        defaults.removeObject(forKey: Self.configuredHostKey)
        defaults.removeObject(forKey: Self.configuredPortKey)
        defaults.removeObject(forKey: Self.legacyBackendURLKey)

        restorePersistedConfiguration()
        serverURLApplyMessage = nil
        healthStatus = .idle
        connectionRevision += 1
    }

    private func persistEndpoint() {
        defaults.set(configuredScheme.rawValue, forKey: Self.configuredSchemeKey)
        defaults.set(configuredRemoteHost, forKey: Self.configuredHostKey)
        defaults.set(configuredPort, forKey: Self.configuredPortKey)
        updateConfig { payload in
            payload["server_url"] = Self.urlString(
                scheme: configuredScheme,
                host: configuredRemoteHost,
                port: configuredPort
            )
        }
    }

    private func persistConnectionTarget() {
        updateConfig { payload in
            payload["connect_to"] = connectionMode.configValue
        }
    }

    private func applyRemoteEndpoint(scheme: Scheme, host: String, port: Int) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredScheme = scheme
        configuredRemoteHost = trimmedHost
        configuredPort = port
        hasExplicitEndpointConfiguration = true
        draftScheme = scheme
        draftHost = trimmedHost
        draftPort = String(port)
        draftServerURL = Self.urlString(scheme: scheme, host: trimmedHost, port: port)
        connectionMode = .remote
        defaults.set(ConnectionMode.remote.rawValue, forKey: Self.connectionModeKey)
        persistEndpoint()
        persistConnectionTarget()
        connectionRevision += 1
    }

    private func checkHealth(scheme: Scheme, host: String, port: Int) async throws -> Int {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        components.path = BackendConnectionConfig.healthPath
        guard let url = components.url else {
            throw ConnectionPayloadError.invalidURL
        }

        healthStatus = .checking
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let health = try TincanAPIClient.decodeHealthResponse(from: data)
        return health.agentProfileCount
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

    private func restorePersistedConfiguration() {
        let persistedEndpoint = Self.loadPersistedEndpoint(defaults: defaults)
        let config = Self.loadAppConfig(url: configURL)
        let endpoint = config.serverURL.flatMap { Self.endpoint(from: $0) } ?? persistedEndpoint
        configuredScheme = endpoint.scheme
        configuredRemoteHost = endpoint.host
        configuredPort = endpoint.port
        hasExplicitEndpointConfiguration = endpoint.isExplicit
        draftScheme = endpoint.scheme
        draftHost = endpoint.host
        draftPort = String(endpoint.port)
        draftServerURL = endpoint.isExplicit ? Self.urlString(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.port) : ""
        connectPhoneEnabled = config.tailscaleEnabled

#if os(macOS)
        let defaultMode: ConnectionMode = .localMac
#else
        let defaultMode: ConnectionMode = .remote
#endif

        if let configMode = config.connectTo {
            connectionMode = configMode == .remote && !endpoint.isExplicit ? .localMac : configMode
        } else if let persistedMode = ConnectionMode(rawValue: defaults.string(forKey: Self.connectionModeKey) ?? "") {
            connectionMode = persistedMode == .remote && !endpoint.isExplicit ? .localMac : persistedMode
        } else if endpoint.isExplicit && config.serverURL == nil {
            connectionMode = .remote
        } else {
            connectionMode = defaultMode
        }
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

    private static func validatedEndpoint(from value: String) throws -> (scheme: Scheme, host: String, port: Int) {
        guard let url = URL(string: value) else {
            throw ConnectionPayloadError.invalidURL
        }
        return try validatedEndpoint(from: url)
    }

    private static func validatedEndpoint(from url: URL) throws -> (scheme: Scheme, host: String, port: Int) {
        if url.scheme == "tincan" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ConnectionPayloadError.invalidURL
            }
            let queryItems = components.queryItems ?? []
            guard let schemeValue = queryItems.first(where: { $0.name == "scheme" })?.value,
                  let scheme = Scheme(rawValue: schemeValue) else {
                throw ConnectionPayloadError.unsupportedScheme
            }
            guard let host = queryItems.first(where: { $0.name == "host" })?.value,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionPayloadError.missingHost
            }
            guard let portValue = queryItems.first(where: { $0.name == "port" })?.value,
                  let port = Int(portValue),
                  port > 0 else {
                throw ConnectionPayloadError.missingPort
            }
            return (scheme, host, port)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionPayloadError.invalidURL
        }
        guard let schemeValue = components.scheme,
              let scheme = Scheme(rawValue: schemeValue) else {
            throw ConnectionPayloadError.unsupportedScheme
        }
        guard let host = components.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionPayloadError.missingHost
        }
        return (scheme, host, components.port ?? scheme.defaultPort)
    }

    private static func endpoint(from serverURL: String) -> (scheme: Scheme, host: String, port: Int, isExplicit: Bool)? {
        guard let endpoint = try? validatedEndpoint(from: serverURL) else { return nil }
        return (endpoint.scheme, endpoint.host, endpoint.port, true)
    }

    private static func urlString(scheme: Scheme, host: String, port: Int) -> String {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        return components.url?.absoluteString ?? "\(scheme.rawValue)://\(host):\(port)"
    }

    private static func loadAppConfig(url: URL) -> (serverURL: String?, connectTo: ConnectionMode?, tailscaleEnabled: Bool) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, false)
        }
        let serverURL = (payload["server_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectTo = (payload["connect_to"] as? String).flatMap(ConnectionMode.init(configValue:))
        let tailscalePayload = payload["tailscale"] as? [String: Any] ?? [:]
        return (serverURL?.isEmpty == false ? serverURL : nil, connectTo, tailscalePayload["enabled"] as? Bool ?? false)
    }

    private func updateConfig(_ update: (inout [String: Any]) -> Void) {
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = decoded
        }

        update(&payload)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            var fileData = data
            fileData.append(0x0A)
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fileData.write(to: configURL, options: .atomic)
        } catch {
            NSLog("Failed to update tincan config at %@: %@", configURL.path, error.localizedDescription)
        }
    }
}
