import Foundation
import Security
import Testing
#if os(macOS)
@testable import tincan

@MainActor
struct TincanSpeechSettingsStoreTests {
    @Test func speechModelOptionsIncludeGrokWhenServiceEnabledOrKeyStored() async throws {
        let store = makeStore()

        #expect(store.modelOptions(for: .speechToText).map(\.value) == [TincanSpeechSettingsStore.defaultSTTModel])
        #expect(store.modelOptions(for: .textToSpeech).map(\.value) == [TincanSpeechSettingsStore.defaultTTSModel])

        store.setServiceEnabled(true, serviceID: .grok)

        #expect(store.modelOptions(for: .speechToText).map(\.value) == [
            TincanSpeechSettingsStore.defaultSTTModel,
            TincanSpeechSettingsStore.grokSTTModel,
        ])
        #expect(store.modelOptions(for: .textToSpeech).map(\.value) == [
            TincanSpeechSettingsStore.defaultTTSModel,
            TincanSpeechSettingsStore.grokTTSModel,
        ])

        let keychain = TestSpeechSettingsKeychain(initialValues: [
            TincanSpeechSettingsStore.grokAPIKeyAccount: "secret-key-9876",
        ])
        let storedKeyStore = makeStore(keychain: keychain)

        await storedKeyStore.load()

        #expect(storedKeyStore.modelOptions(for: .speechToText).map(\.value) == [
            TincanSpeechSettingsStore.defaultSTTModel,
            TincanSpeechSettingsStore.grokSTTModel,
        ])
        #expect(storedKeyStore.modelOptions(for: .textToSpeech).map(\.value) == [
            TincanSpeechSettingsStore.defaultTTSModel,
            TincanSpeechSettingsStore.grokTTSModel,
        ])
    }

    @Test func disablingGrokResetsDependentModelsAndRestartsBundledServer() async throws {
        let keychain = TestSpeechSettingsKeychain()
        let restartRecorder = TestRestartRecorder()
        let configURL = makeConfigURL()
        try writeConfig(
            """
            {
              "stt_model": "grok/grok-stt-v1",
              "tts_model": "grok/grok-tts-v1",
              "services": {
                "grok": {
                  "enabled": true,
                  "base_url": "https://proxy.example/v1"
                }
              }
            }
            """,
            to: configURL
        )

        let store = makeStore(
            configURL: configURL,
            keychain: keychain,
            restartRecorder: restartRecorder
        )
        await store.load()

        store.setServiceEnabled(false, serviceID: .grok)

        #expect(store.sttModel == TincanSpeechSettingsStore.defaultSTTModel)
        #expect(store.ttsModel == TincanSpeechSettingsStore.defaultTTSModel)

        await store.saveConfig()

        let payload = try readJSONObject(from: configURL)
        let services = try #require(payload["services"] as? [String: Any])
        let grok = try #require(services["grok"] as? [String: Any])

        #expect(grok["enabled"] as? Bool == false)
        #expect(grok["base_url"] as? String == "https://proxy.example/v1")
        #expect(payload["stt_model"] as? String == TincanSpeechSettingsStore.defaultSTTModel)
        #expect(payload["tts_model"] as? String == TincanSpeechSettingsStore.defaultTTSModel)
        #expect(restartRecorder.restartCount == 1)
        #expect(store.statusMessage == "Speech settings saved. Bundled server restarted.")
    }

    @Test func savingConfigOmitsDefaultGrokBaseURLOverride() async throws {
        let configURL = makeConfigURL()
        let store = makeStore(configURL: configURL)

        store.setServiceEnabled(true, serviceID: .grok)
        store.grokBaseURL = ""

        await store.saveConfig()

        let payload = try readJSONObject(from: configURL)
        let services = try #require(payload["services"] as? [String: Any])
        let grok = try #require(services["grok"] as? [String: Any])

        #expect(grok["enabled"] as? Bool == true)
        #expect(grok["base_url"] == nil)
    }

    @Test func savingGrokKeyUsesPageSaveAndSkipsRestartWhenConfigIsUnchanged() async throws {
        let keychain = TestSpeechSettingsKeychain()
        let restartRecorder = TestRestartRecorder()
        let store = makeStore(
            keychain: keychain,
            restartRecorder: restartRecorder
        )

        store.updateGrokAPIKey("secret-key-1234")

        #expect(store.modelOptions(for: .speechToText).map(\.value) == [
            TincanSpeechSettingsStore.defaultSTTModel,
            TincanSpeechSettingsStore.grokSTTModel,
        ])

        await store.saveConfig()
        await store.load()

        #expect(store.maskedStoredGrokAPIKey == "********1234")
        #expect(store.showsMaskedStoredGrokAPIKey)
        #expect(store.showsStoredGrokAPIKeyIndicator)
        #expect(keychain.containsStoredValue(for: TincanSpeechSettingsStore.grokAPIKeyAccount))
        #expect(restartRecorder.restartCount == 0)
        #expect(store.statusMessage == "Grok API key saved.")
    }

    @Test func clearingStoredGrokKeyUsesPageSaveAndRemovesTheKey() async throws {
        let keychain = TestSpeechSettingsKeychain(initialValues: [
            TincanSpeechSettingsStore.grokAPIKeyAccount: "secret-key-1234",
        ])
        let restartRecorder = TestRestartRecorder()
        let store = makeStore(
            keychain: keychain,
            restartRecorder: restartRecorder
        )

        await store.load()

        #expect(!store.canSave)

        store.updateGrokAPIKey("")

        #expect(store.canSave)

        await store.saveConfig()
        await store.load()

        #expect(!store.hasStoredGrokAPIKey)
        #expect(store.maskedStoredGrokAPIKey.isEmpty)
        #expect(!store.showsMaskedStoredGrokAPIKey)
        #expect(!store.showsStoredGrokAPIKeyIndicator)
        #expect(!keychain.containsStoredValue(for: TincanSpeechSettingsStore.grokAPIKeyAccount))
        #expect(restartRecorder.restartCount == 0)
        #expect(store.statusMessage == "Grok API key removed.")
    }

    @Test func loadingWithUnreadableStoredGrokKeyKeepsSettingsAvailable() async throws {
        let keychain = TestSpeechSettingsKeychain(
            initialValues: [
                TincanSpeechSettingsStore.grokAPIKeyAccount: "secret-key-1234",
            ],
            unreadableAccounts: [
                TincanSpeechSettingsStore.grokAPIKeyAccount,
            ]
        )
        let store = makeStore(keychain: keychain)

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.hasStoredGrokAPIKey)
        #expect(store.maskedStoredGrokAPIKey.isEmpty)
        #expect(!store.showsMaskedStoredGrokAPIKey)
        #expect(store.showsStoredGrokAPIKeyIndicator)
    }

    @Test func savingConfigSkipsRestartWhenRemoteServerSelected() async throws {
        let restartRecorder = TestRestartRecorder()
        let store = makeStore(
            connectionMode: .remote,
            restartRecorder: restartRecorder
        )

        store.setServiceEnabled(true, serviceID: .grok)
        await store.saveConfig()

        #expect(restartRecorder.restartCount == 0)
        #expect(store.statusMessage == "Speech settings saved. Changes apply when the local Mac server is used.")
    }

    private func makeStore(
        connectionMode: ServerConnectionStore.ConnectionMode = .localMac,
        configURL: URL? = nil,
        keychain: TestSpeechSettingsKeychain = TestSpeechSettingsKeychain(),
        restartRecorder: TestRestartRecorder = TestRestartRecorder()
    ) -> TincanSpeechSettingsStore {
        let defaultsName = "TincanSpeechSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)

        let serverSettings = ServerConnectionStore(defaults: defaults)
        if serverSettings.connectionMode != connectionMode {
            serverSettings.setConnectionMode(connectionMode)
        }

        return TincanSpeechSettingsStore(
            serverSettings: serverSettings,
            configURL: configURL ?? Self.makeConfigURL(),
            keychain: keychain,
            restartLocalServer: {
                try await restartRecorder.restart()
            }
        )
    }

    private static func makeConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private func makeConfigURL() -> URL {
        Self.makeConfigURL()
    }

    private func writeConfig(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private func readJSONObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class TestSpeechSettingsKeychain: TincanSpeechSettingsKeychainServicing {
    private var values: [String: String]
    private let unreadableAccounts: Set<String>

    init(initialValues: [String: String] = [:], unreadableAccounts: Set<String> = []) {
        values = initialValues
        self.unreadableAccounts = unreadableAccounts
    }

    func containsValue(account: String) throws -> Bool {
        values[account] != nil
    }

    func value(account: String) throws -> String? {
        if unreadableAccounts.contains(account), values[account] != nil {
            throw KeychainError(status: errSecAuthFailed)
        }
        return values[account]
    }

    func upsert(value: String, account: String) throws {
        values[account] = value
    }

    func deleteValue(account: String) throws {
        values.removeValue(forKey: account)
    }

    func containsStoredValue(for account: String) -> Bool {
        values[account] != nil
    }
}

private final class TestRestartRecorder: @unchecked Sendable {
    var restartCount = 0

    func restart() async throws {
        restartCount += 1
    }
}
#endif
