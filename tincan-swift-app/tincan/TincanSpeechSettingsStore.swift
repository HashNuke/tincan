#if os(macOS)
import Combine
import Foundation

protocol TincanSpeechSettingsKeychainServicing {
    func containsValue(account: String) throws -> Bool
    func upsert(value: String, account: String) throws
    func deleteValue(account: String) throws
}

extension MacKeychainService: TincanSpeechSettingsKeychainServicing {}

@MainActor
final class TincanSpeechSettingsStore: ObservableObject {
    struct LocalAppConfig {
        struct Services {
            struct Grok {
                let enabled: Bool
                let baseURLOverride: String
                let rawPayload: [String: Any]
            }

            let grok: Grok
            let rawPayload: [String: Any]
        }

        let sttModel: String
        let ttsModel: String
        let services: Services
        let rawPayload: [String: Any]
    }

    static var defaultSTTModel: String {
        TincanSpeechServiceCatalog.defaultModel(for: .speechToText)
    }

    static var defaultTTSModel: String {
        TincanSpeechServiceCatalog.defaultModel(for: .textToSpeech)
    }

    static let grokSTTModel = "grok/grok-stt-v1"
    static let grokTTSModel = "grok/grok-tts-v1"
    static var defaultGrokBaseURL: String { TincanSpeechServiceCatalog.defaultGrokBaseURL }
    static let grokAPIKeyAccount = "GROK_API_KEY"

    @Published var sttModel = defaultSTTModel
    @Published var ttsModel = defaultTTSModel
    @Published var grokEnabled = false
    @Published var grokBaseURL = ""
    @Published var grokAPIKey = ""
    @Published private(set) var hasStoredGrokAPIKey = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingConfig = false
    @Published private(set) var isSavingAPIKey = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?

    private let serverSettings: ServerConnectionStore
    private let configURL: URL
    private let keychain: any TincanSpeechSettingsKeychainServicing
    private let fileManager: FileManager
    private let restartLocalServer: @Sendable () async throws -> Void
    private var persistedConfigPayload: [String: Any] = [:]
    private var persistedServicesPayload: [String: Any] = [:]
    private var persistedGrokPayload: [String: Any] = [:]

    init(
        serverSettings: ServerConnectionStore,
        configURL: URL = AppPaths.generatedAppConfigURL,
        keychain: (any TincanSpeechSettingsKeychainServicing)? = nil,
        fileManager: FileManager = .default,
        restartLocalServer: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.serverSettings = serverSettings
        self.configURL = configURL
        self.keychain = keychain ?? MacKeychainService()
        self.fileManager = fileManager
        self.restartLocalServer = restartLocalServer
    }

    var isRemoteServerSelected: Bool {
        serverSettings.connectionMode == .remote
    }

    var enabledServices: Set<TincanSpeechServiceID> {
        grokEnabled ? [.grok] : []
    }

    var grokBaseURLPlaceholder: String {
        Self.defaultGrokBaseURL
    }

    var grokAPIKeyPlaceholder: String {
        hasStoredGrokAPIKey ? String(repeating: "*", count: 12) : "GROK_API_KEY"
    }

    var canSaveGrokAPIKey: Bool {
        !grokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canClearStoredGrokAPIKey: Bool {
        hasStoredGrokAPIKey
    }

    var usesGrok: Bool {
        TincanSpeechServiceCatalog.provider(for: sttModel) == .grok ||
            TincanSpeechServiceCatalog.provider(for: ttsModel) == .grok
    }

    func modelOptions(for target: TincanSpeechModelTarget) -> [TincanSpeechModelOption] {
        TincanSpeechServiceCatalog.options(for: target, enabledServices: enabledServices)
    }

    func selectedModelTitle(for target: TincanSpeechModelTarget) -> String {
        let selectedModel = model(for: target)
        return modelOptions(for: target).first(where: { $0.value == selectedModel })?.title ?? selectedModel
    }

    func setModel(_ value: String, for target: TincanSpeechModelTarget) {
        switch target {
        case .speechToText:
            sttModel = value
        case .textToSpeech:
            ttsModel = value
        }
    }

    func setServiceEnabled(_ isEnabled: Bool, serviceID: TincanSpeechServiceID) {
        switch serviceID {
        case .grok:
            guard grokEnabled != isEnabled else { return }
            grokEnabled = isEnabled
            if !isEnabled {
                normalizeModels(disabling: .grok)
            }
        }
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
        normalizeDisabledServiceSelections()

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
        var grokPayload = persistedGrokPayload
        grokPayload["enabled"] = grokEnabled

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

            if isRemoteServerSelected {
                statusMessage = "Speech config saved. Changes apply when the local Mac server is used."
            } else {
                statusMessage = "Speech config saved. Restarting bundled server..."
                do {
                    try await restartLocalServer()
                    statusMessage = "Speech config saved. Bundled server restarted."
                } catch {
                    errorMessage = "Speech config saved, but restarting bundled server failed: \(error.localizedDescription)"
                }
            }

            lastLoadedAt = Date()
        } catch {
            errorMessage = "Saving speech config failed: \(error.localizedDescription)"
        }
    }

    func saveGrokAPIKey() {
        let trimmedAPIKey = grokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            errorMessage = "Enter a Grok API key before saving."
            return
        }

        isSavingAPIKey = true
        defer { isSavingAPIKey = false }

        do {
            try keychain.upsert(value: trimmedAPIKey, account: Self.grokAPIKeyAccount)
            hasStoredGrokAPIKey = true
            grokAPIKey = ""
            errorMessage = nil
            statusMessage = "Grok API key saved to Keychain."
        } catch {
            errorMessage = "Updating GROK_API_KEY failed: \(error.localizedDescription)"
        }
    }

    func clearGrokAPIKey() {
        guard hasStoredGrokAPIKey else {
            grokAPIKey = ""
            return
        }

        isSavingAPIKey = true
        defer { isSavingAPIKey = false }

        do {
            try keychain.deleteValue(account: Self.grokAPIKeyAccount)
            hasStoredGrokAPIKey = false
            grokAPIKey = ""
            errorMessage = nil
            statusMessage = "Grok API key removed from Keychain."
        } catch {
            errorMessage = "Clearing GROK_API_KEY failed: \(error.localizedDescription)"
        }
    }

    func clearStatus() {
        statusMessage = nil
        errorMessage = nil
    }

    private func model(for target: TincanSpeechModelTarget) -> String {
        switch target {
        case .speechToText:
            return sttModel
        case .textToSpeech:
            return ttsModel
        }
    }

    private func apply(_ config: LocalAppConfig) {
        sttModel = config.sttModel
        ttsModel = config.ttsModel
        grokEnabled = config.services.grok.enabled
        grokBaseURL = config.services.grok.baseURLOverride

        if !grokEnabled {
            normalizeModels(disabling: .grok)
        }

        persistedConfigPayload = config.rawPayload
        persistedServicesPayload = config.services.rawPayload
        persistedGrokPayload = config.services.grok.rawPayload
    }

    private func normalizeDisabledServiceSelections() {
        if !grokEnabled {
            normalizeModels(disabling: .grok)
        }
    }

    private func normalizeModels(disabling serviceID: TincanSpeechServiceID) {
        sttModel = TincanSpeechServiceCatalog.normalizedModel(
            sttModel,
            for: .speechToText,
            disabling: serviceID
        )
        ttsModel = TincanSpeechServiceCatalog.normalizedModel(
            ttsModel,
            for: .textToSpeech,
            disabling: serviceID
        )
    }

    private func loadConfigFromDisk() throws -> LocalAppConfig {
        try ensureConfigFileExists()
        let data = try Data(contentsOf: configURL)
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
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileData.write(to: configURL, options: .atomic)
        return decodeConfig(normalizedPayload)
    }

    private func ensureConfigFileExists() throws {
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        if fileManager.fileExists(atPath: configURL.path) {
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
        let grokEnabled = grokPayload["enabled"] as? Bool ?? false
        let grokBaseURL = (grokPayload["base_url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return LocalAppConfig(
            sttModel: (sttModel?.isEmpty == false ? sttModel! : Self.defaultSTTModel),
            ttsModel: (ttsModel?.isEmpty == false ? ttsModel! : Self.defaultTTSModel),
            services: .init(
                grok: .init(
                    enabled: grokEnabled,
                    baseURLOverride: grokBaseURL,
                    rawPayload: grokPayload
                ),
                rawPayload: servicesPayload
            ),
            rawPayload: payload
        )
    }
}
#endif
