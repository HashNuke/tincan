import Foundation
import Testing
@testable import tincan

@MainActor
struct ServerConnectionStoreTests {
    @Test func localMacLiveUpdatesOriginUsesLoopbackServerOrigin() {
        let defaults = makeDefaults()
        let store = ServerConnectionStore(defaults: defaults)

        #expect(store.connectionMode == .localMac)
        #expect(store.liveUpdatesURL?.absoluteString == "ws://127.0.0.1:55055/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "http://127.0.0.1:55055")
    }

    @Test func remoteLiveUpdatesOriginUsesConfiguredServerOrigin() {
        let defaults = makeDefaults()
        let store = ServerConnectionStore(defaults: defaults)

        store.draftHost = "server.example"
        store.draftPort = "64000"
        #expect(store.applyRemoteDraft())
        store.setConnectionMode(.remote)

        #expect(store.liveUpdatesURL?.absoluteString == "ws://server.example:64000/api/v1/live")
        #expect(store.liveUpdatesOriginHeaderValue == "http://server.example:64000")
    }

    private func makeDefaults() -> UserDefaults {
        let defaultsName = "ServerConnectionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        return defaults
    }
}
