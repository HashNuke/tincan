import Foundation
import Testing
@testable import tincan

@MainActor
struct ServerConnectionStoreTests {
    @Test func localMacLiveUpdatesOriginUsesLoopbackServerOrigin() {
        let defaults = makeDefaults()
        let store = ServerConnectionStore(defaults: defaults)

        #expect(store.connectionMode == .localMac)
        #expect(store.shouldUseBundledServer)
        #expect(store.liveUpdatesURL?.absoluteString == "ws://127.0.0.1:4490/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "http://127.0.0.1:4490")
        #expect(store.shareableConnectionLabel == "http://wheeljack:4490")
    }

    @Test func remoteLiveUpdatesOriginUsesConfiguredServerOrigin() {
        let defaults = makeDefaults()
        let store = ServerConnectionStore(defaults: defaults)

        store.draftScheme = .https
        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())
        store.setConnectionMode(.remote)

        #expect(store.serverBaseURL?.absoluteString == "https://server.example:64000")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://server.example:64000/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "https://server.example:64000")
        #expect(store.shareableConnectionLabel == "https://server.example:64000")
    }

    @Test func explicitEndpointDisablesBundledServerEvenInLocalMode() {
        let defaults = makeDefaults()
        let store = ServerConnectionStore(defaults: defaults)

        store.draftScheme = .https
        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())
        store.setConnectionMode(.localMac)

        #expect(!store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "https://server.example:64000")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://server.example:64000/api/v1/live")
    }

    @Test func persistedExplicitEndpointDisablesBundledServerOnInit() {
        let defaults = makeDefaults()
        defaults.set("https", forKey: "server_configured_scheme")
        defaults.set("configured.example", forKey: "server_configured_host")
        defaults.set(65123, forKey: "server_configured_port")

        let store = ServerConnectionStore(defaults: defaults)

        #expect(!store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "https://configured.example:65123")
        #expect(store.draftScheme == .https)
    }

    @Test func legacyBackendURLLoadsSchemeFromURL() {
        let defaults = makeDefaults()
        defaults.set("https://legacy.example:8443", forKey: "backend_url")

        let store = ServerConnectionStore(defaults: defaults)

        #expect(!store.shouldUseBundledServer)
        #expect(store.serverBaseURL?.absoluteString == "https://legacy.example:8443")
        #expect(store.liveUpdatesURL?.absoluteString == "wss://legacy.example:8443/api/v1/live")
    }

    private func makeDefaults() -> UserDefaults {
        let defaultsName = "ServerConnectionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        return defaults
    }
}
