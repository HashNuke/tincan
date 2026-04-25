import Foundation
import Testing
@testable import tincan

@MainActor
struct ServerConnectionStoreTests {
    @Test func localMacLiveUpdatesOriginUsesLoopbackServerOrigin() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)
        #expect(store.draftServerURL.isEmpty)
        #expect(store.liveUpdatesURL?.absoluteString == "ws://127.0.0.1:4490/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "http://127.0.0.1:4490")
        #expect(store.shareableConnectionLabel == "http://wheeljack:4490")
    }

    @Test func defaultConfigUsesLocalConnectionTarget() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)
    }

    @Test func emptyServerURLKeepsRemoteDraftEmpty() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let emptyConfig = Data(#"{"server_url": ""}"#.utf8)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try emptyConfig.write(to: configURL)

        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        #expect(store.shouldUseBundledServer)
        #expect(store.draftServerURL.isEmpty)
    }

    @Test func remoteLiveUpdatesOriginUsesConfiguredServerOrigin() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.draftScheme = .https
        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())

        #expect(store.serverBaseURL?.absoluteString == "https://server.example:64000")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://server.example:64000/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "https://server.example:64000")
        #expect(store.shareableConnectionLabel == "https://server.example:64000")
    }

    @Test func explicitEndpointDoesNotDisableBundledServerWhenConnectToIsLocal() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        try writeConfig(
            [
                "connect_to": "local",
                "server_url": "https://server.example:64000",
            ],
            to: configURL
        )

        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "http://127.0.0.1:4490")
        #expect(store.draftServerURL == "https://server.example:64000")
    }

    @Test func configConnectToRemoteUsesPersistedServerURL() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        try writeConfig(
            [
                "connect_to": "remote",
                "server_url": "https://configured.example:65123",
            ],
            to: configURL
        )

        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        #expect(store.connectionMode == .remote)
        #expect(!store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "https://configured.example:65123")
        #expect(store.draftScheme == .https)
    }

    @Test func legacyBackendURLLoadsSchemeFromURL() {
        let defaults = makeDefaults()
        defaults.set("https://legacy.example:8443", forKey: "backend_url")

        let store = makeStore(defaults: defaults)

        #expect(!store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "https://legacy.example:8443")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://legacy.example:8443/api/v1/live")
    }

    @Test func useBundledServerPersistsConnectToLocalWithoutRemovingServerURL() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        store.draftScheme = .https
        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())

        store.useBundledServer()

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)
        #expect(store.draftServerURL == "https://server.example:64000")

        let payload = try readConfig(configURL)
        #expect(payload["connect_to"] as? String == "local")
        #expect(payload["server_url"] as? String == "https://server.example:64000")
    }

    @Test func enablingRemoteRequiresSavedServerURL() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        #expect(!store.setRemoteServerEnabled(true))

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)

        store.draftScheme = .https
        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())

        store.useBundledServer()
        #expect(store.setRemoteServerEnabled(true))

        #expect(store.connectionMode == .remote)
        #expect(!store.shouldUseBundledServer)

        let payload = try readConfig(configURL)
        #expect(payload["connect_to"] as? String == "remote")
        #expect(payload["server_url"] as? String == "https://server.example:64000")
    }

    @Test func applyConnectionPayloadLoadsTincanQRURL() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        try store.applyConnectionPayload("tincan://connect?scheme=https&host=tincan-akash.ts.net&port=443")

        #expect(store.connectionMode == .remote)
        #expect(store.serverBaseURL?.absoluteString == "https://tincan-akash.ts.net:443")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://tincan-akash.ts.net:443/api/v1/live")
    }

    @Test func applyConnectionPayloadLoadsDirectHTTPSURL() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        try store.applyConnectionPayload("https://tincan-akash.ts.net")

        #expect(store.connectionMode == .remote)
        #expect(store.serverBaseURL?.absoluteString == "https://tincan-akash.ts.net:443")
    }

    @Test func connectPhoneTogglePersistsToConfig() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        store.setConnectPhoneEnabled(true)
        #expect(store.connectPhoneEnabled)

        let reloaded = ServerConnectionStore(defaults: defaults, configURL: configURL)
        #expect(reloaded.connectPhoneEnabled)

        let data = try Data(contentsOf: configURL)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tailscale = try #require(payload["tailscale"] as? [String: Any])
        #expect(tailscale["enabled"] as? Bool == true)
    }

    @Test func resetAppConfigurationClearsConfigFileAndPersistedEndpointState() throws {
        let defaults = makeDefaults()
        let configURL = makeConfigURL()
        let store = ServerConnectionStore(defaults: defaults, configURL: configURL)

        store.draftServerURL = "https://phone.example.ts.net"
        defaults.set("https", forKey: "server_configured_scheme")
        defaults.set("phone.example.ts.net", forKey: "server_configured_host")
        defaults.set(443, forKey: "server_configured_port")
        defaults.set("remote", forKey: "server_connection_mode")
        defaults.set("https://legacy.example:8443", forKey: "backend_url")
        store.setConnectPhoneEnabled(true)

        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(store.connectPhoneEnabled)

        store.resetAppConfiguration()

        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        #expect(store.draftServerURL.isEmpty)
        #expect(store.connectionMode == .remote)
        #expect(!store.hasExplicitEndpointConfiguration)
        #expect(store.healthStatus == .idle)
        #expect(store.connectPhoneEnabled == false)
        #expect(defaults.string(forKey: "server_connection_mode") == nil)
        #expect(defaults.string(forKey: "server_configured_scheme") == nil)
        #expect(defaults.string(forKey: "server_configured_host") == nil)
        #expect(defaults.object(forKey: "server_configured_port") == nil)
        #expect(defaults.string(forKey: "backend_url") == nil)
    }

    private func makeDefaults() -> UserDefaults {
        let defaultsName = "ServerConnectionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> ServerConnectionStore {
        ServerConnectionStore(defaults: defaults, configURL: makeConfigURL())
    }

    private func makeConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerConnectionStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func writeConfig(_ payload: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
    }

    private func readConfig(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
