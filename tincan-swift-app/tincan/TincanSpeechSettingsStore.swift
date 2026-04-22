#if os(macOS)
import Combine
import Foundation

@MainActor
final class TincanSpeechSettingsStore: ObservableObject {
    struct LocalAppConfig {
        struct Services {
            struct Grok {
                let baseURL: String
            }

            let grok: Grok
            let rawPayload: [String: Any]
        }

        let sttModel: String
        let ttsModel: String
        let services: Services
        let rawPayload: [String: Any]
    }

    static let defaultSTTModel = "macos/parakeet-tdt-0.6b-v3-coreml"
    static let defaultTTSModel = "macos/kitten-tts-mini-0.8"
    static let grokSTTModel = "grok/grok-stt-v1"
    static let grokTTSModel = "grok/grok-tts-v1"
    static let defaultGrokBaseURL = "https://api.x.ai/v1"
    static let grokAPIKeyAccount = "GROK_API_KEY"

    @Published var sttModel = defaultSTTModel
    @Published var ttsModel = defaultTTSModel
    @Published var grokBaseURL = defaultGrokBaseURL
    @Published var grokAPIKey = ""
    @Published private(set) var hasStoredGrokAPIKey = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingConfig = false
    @Published private(set) var isSavingAPIKey = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?

    private let serverSettings: ServerConnectionStore
    private let keychain = MacKeychainService()
    private var persistedConfigPayload: [String: Any] = [:]
    private var persistedServicesPayload: [String: Any] = [:]

    init(serverSettings: ServerConnectionStore) {
        self.serverSettings = serverSettings
    }

    var isRemoteServerSelected: Bool {
        serverSettings.connectionMode == .remote
    }

    var usesGrok: Bool {
        sttModel.hasPrefix("grok/") || ttsModel.hasPrefix("grok/")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let config = try loadConfigFromDisk()
            apply(config)

            hasStoredGrokAPIKey = try keychain.containsValue(account: Self.grokAPIKeyAccount)
            grokAPIKey = ""
            lastLoadedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = "Speech settings failed: \(error.localizedDescription)"
        }
    }

    func saveConfig() async {
        let trimmedSTTModel = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSTTModel.isEmpty || trimmedTTSModel.isEmpty {
            errorMessage = "`stt_model` and `tts_model` must be set."
            return
        }

        isSavingConfig = true
        defer { isSavingConfig = false }

        var payload = persistedConfigPayload
        payload["stt_model"] = trimmedSTTModel
        payload["tts_model"] = trimmedTTSModel

        var servicesPayload = persistedServicesPayload
        var grokPayload = servicesPayload["grok"] as? [String: Any] ?? [:]
        let trimmedGrokBaseURL = grokBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGrokBaseURL.isEmpty || trimmedGrokBaseURL == Self.defaultGrokBaseURL {
            grokPayload.removeValue(forKey: "base_url")
        } else {
            grokPayload["base_url"] = trimmedGrokBaseURL
        }

        if grokPayload.isEmpty {
            servicesPayload.removeValue(forKey: "grok")
        } else {
            servicesPayload["grok"] = grokPayload
        }
        if servicesPayload.isEmpty {
            payload.removeValue(forKey: "services")
        } else {
            payload["services"] = servicesPayload
        }

        do {
            let config = try writeConfigToDisk(payload)
            apply(config)
            errorMessage = nil
            statusMessage = "Speech config saved."
            lastLoadedAt = Date()
        } catch {
            errorMessage = "Saving speech config failed: \(error.localizedDescription)"
        }
    }

    func saveGrokAPIKey() {
        isSavingAPIKey = true
        defer { isSavingAPIKey = false }

        do {
            let trimmedAPIKey = grokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAPIKey.isEmpty {
                try keychain.deleteValue(account: Self.grokAPIKeyAccount)
                hasStoredGrokAPIKey = false
                statusMessage = "Grok API key removed from Keychain."
            } else {
                try keychain.upsert(value: trimmedAPIKey, account: Self.grokAPIKeyAccount)
                hasStoredGrokAPIKey = true
                statusMessage = "Grok API key saved to Keychain."
            }

            grokAPIKey = ""
            errorMessage = nil
        } catch {
            errorMessage = "Updating GROK_API_KEY failed: \(error.localizedDescription)"
        }
    }

    func clearStatus() {
        statusMessage = nil
        errorMessage = nil
    }

    private func apply(_ config: LocalAppConfig) {
        sttModel = config.sttModel
        ttsModel = config.ttsModel
        grokBaseURL = config.services.grok.baseURL.isEmpty ? Self.defaultGrokBaseURL : config.services.grok.baseURL
        persistedConfigPayload = config.rawPayload
        persistedServicesPayload = config.services.rawPayload
    }

    private func loadConfigFromDisk() throws -> LocalAppConfig {
        try ensureConfigFileExists()
        let data = try Data(contentsOf: AppPaths.generatedAppConfigURL)
        let payload = try parseJSONObject(from: data)
        return decodeConfig(payload)
    }

    private func writeConfigToDisk(_ payload: [String: Any]) throws -> LocalAppConfig {
        var normalizedPayload = payload
        if normalizedPayload["stt_model"] == nil {
            normalizedPayload["stt_model"] = Self.defaultSTTModel
        }
        if normalizedPayload["tts_model"] == nil {
            normalizedPayload["tts_model"] = Self.defaultTTSModel
        }
        if let servicesPayload = normalizedPayload["services"] as? [String: Any], servicesPayload.isEmpty {
            normalizedPayload.removeValue(forKey: "services")
        }

        let data = try JSONSerialization.data(
            withJSONObject: normalizedPayload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var fileData = data
        fileData.append(0x0A)
        try fileData.write(to: AppPaths.generatedAppConfigURL, options: .atomic)
        return decodeConfig(normalizedPayload)
    }

    private func ensureConfigFileExists() throws {
        if FileManager.default.fileExists(atPath: AppPaths.generatedAppConfigURL.path) {
            return
        }

        let defaultPayload: [String: Any] = [
            "stt_model": Self.defaultSTTModel,
            "tts_model": Self.defaultTTSModel,
        ]
        _ = try writeConfigToDisk(defaultPayload)
    }

    private func parseJSONObject(from data: Data) throws -> [String: Any] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return payload
    }

    private func decodeConfig(_ payload: [String: Any]) -> LocalAppConfig {
        let sttModel = (payload["stt_model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ttsModel = (payload["tts_model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let servicesPayload = payload["services"] as? [String: Any] ?? [:]
        let grokPayload = servicesPayload["grok"] as? [String: Any] ?? [:]
        let grokBaseURL = (grokPayload["base_url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return LocalAppConfig(
            sttModel: (sttModel?.isEmpty == false ? sttModel! : Self.defaultSTTModel),
            ttsModel: (ttsModel?.isEmpty == false ? ttsModel! : Self.defaultTTSModel),
            services: .init(
                grok: .init(baseURL: grokBaseURL),
                rawPayload: servicesPayload
            ),
            rawPayload: payload
        )
    }
}
#endif
