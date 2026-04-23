#if os(macOS)
import Combine
import Foundation

protocol TincanSpeechSettingsKeychainServicing {
    func containsValue(account: String) throws -> Bool
    func value(account: String) throws -> String?
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
    @Published private(set) var maskedStoredGrokAPIKey = ""
    @Published private(set) var hasEditedGrokAPIKey = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingConfig = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let serverSettings: ServerConnectionStore
    private let configURL: URL
    private let keychain: any TincanSpeechSettingsKeychainServicing
    private let fileManager: FileManager
    private let restartLocalServer: @Sendable () async throws -> Void
    private let syncLocalServerSecretUpdates: @Sendable ([String: String]) async throws -> Void
    private let syncLocalServerSecrets: @Sendable () async throws -> Void
    private var persistedConfigPayload: [String: Any] = [:]
    private var persistedServicesPayload: [String: Any] = [:]
    private var persistedGrokPayload: [String: Any] = [:]
    private var loadedSTTModel = defaultSTTModel
    private var loadedTTSModel = defaultTTSModel
    private var loadedGrokEnabled = false
    private var loadedGrokBaseURL = ""

    init(
        serverSettings: ServerConnectionStore,
        configURL: URL = AppPaths.generatedAppConfigURL,
        keychain: (any TincanSpeechSettingsKeychainServicing)? = nil,
        fileManager: FileManager = .default,
        restartLocalServer: @escaping @Sendable () async throws -> Void = {},
        syncLocalServerSecretUpdates: @escaping @Sendable ([String: String]) async throws -> Void = { _ in },
        syncLocalServerSecrets: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.serverSettings = serverSettings
        self.configURL = configURL
        self.keychain = keychain ?? MacKeychainService()
        self.fileManager = fileManager
        self.restartLocalServer = restartLocalServer
        self.syncLocalServerSecretUpdates = syncLocalServerSecretUpdates
        self.syncLocalServerSecrets = syncLocalServerSecrets
    }

    var isRemoteServerSelected: Bool {
        !serverSettings.shouldUseBundledServer
    }

    var grokBaseURLPlaceholder: String {
        Self.defaultGrokBaseURL
    }

    var usesGrok: Bool {
        TincanSpeechServiceCatalog.provider(for: sttModel) == .grok ||
            TincanSpeechServiceCatalog.provider(for: ttsModel) == .grok
    }

    var showsMaskedStoredGrokAPIKey: Bool {
        hasStoredGrokAPIKey && !maskedStoredGrokAPIKey.isEmpty && !hasEditedGrokAPIKey && grokAPIKey.isEmpty
    }

    var showsStoredGrokAPIKeyIndicator: Bool {
        hasStoredGrokAPIKey && !hasEditedGrokAPIKey
    }

    var hasPendingConfigChanges: Bool {
        sttModel != loadedSTTModel ||
            ttsModel != loadedTTSModel ||
            grokEnabled != loadedGrokEnabled ||
            normalizedBaseURL(grokBaseURL) != loadedGrokBaseURL
    }

    var hasPendingChanges: Bool {
        hasPendingConfigChanges || hasEditedGrokAPIKey
    }

    var canSave: Bool {
        !isLoading && !isSavingConfig && hasPendingChanges
    }

    var canReset: Bool {
        !isLoading && !isSavingConfig && hasPendingChanges
    }

    func modelOptions(for target: TincanSpeechModelTarget) -> [TincanSpeechModelOption] {
        TincanSpeechServiceCatalog.options(for: target)
    }

    func selectedModelOption(for target: TincanSpeechModelTarget) -> TincanSpeechModelOption {
        let selectedModel = model(for: target)
        return modelOptions(for: target).first(where: { $0.value == selectedModel }) ??
            TincanSpeechModelOption(
                id: "\(target.rawValue)-custom",
                title: selectedModel,
                value: selectedModel,
                note: ""
            )
    }

    func setModel(_ value: String, for target: TincanSpeechModelTarget) {
        if TincanSpeechServiceCatalog.provider(for: value) == .grok {
            grokEnabled = true
        }

        switch target {
        case .speechToText:
            sttModel = value
        case .textToSpeech:
            ttsModel = value
        }
    }

    func updateGrokAPIKey(_ value: String) {
        hasEditedGrokAPIKey = true
        grokAPIKey = value
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
            try reloadGrokAPIKeyState()
            errorMessage = nil
        } catch {
            errorMessage = "Speech settings failed: \(error.localizedDescription)"
        }
    }

    func saveConfig() async {
        normalizeDisabledServiceSelections()

        let keyUpdate = grokAPIKeyUpdate()
        let willHaveGrokAPIKey = switch keyUpdate {
        case .unchanged:
            hasStoredGrokAPIKey
        case .store(let value):
            !value.isEmpty
        case .clear:
            false
        }

        if usesGrok && !willHaveGrokAPIKey {
            errorMessage = "A Grok API key is required when a Grok model is selected."
            return
        }

        if !hasPendingChanges {
            statusMessage = "No changes to save."
            errorMessage = nil
            return
        }

        let trimmedSTTModel = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSTTModel.isEmpty || trimmedTTSModel.isEmpty {
            errorMessage = "`stt_model` and `tts_model` must be set."
            return
        }

        isSavingConfig = true
        defer { isSavingConfig = false }

        do {
            try applyGrokAPIKeyUpdate(keyUpdate)
        } catch {
            errorMessage = "Updating GROK_API_KEY failed: \(error.localizedDescription)"
            return
        }

        if !hasPendingConfigChanges {
            let secretUpdates = localServerSecretUpdates(for: keyUpdate)
            do {
                if !isRemoteServerSelected, let secretUpdates {
                    try await syncLocalServerSecretUpdates(secretUpdates)
                }
                try reloadGrokAPIKeyState()
                errorMessage = nil
                statusMessage = statusMessage(for: keyUpdate)
            } catch {
                do {
                    try reloadGrokAPIKeyState()
                } catch {
                    errorMessage = "Refreshing GROK_API_KEY state failed: \(error.localizedDescription)"
                    return
                }
                errorMessage = "GROK_API_KEY was updated, but syncing bundled server failed: \(error.localizedDescription)"
            }
            return
        }

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
            try reloadGrokAPIKeyState()
            errorMessage = nil

            if isRemoteServerSelected {
                statusMessage = "Speech settings saved. Changes apply when the local Mac server is used."
            } else {
                statusMessage = "Speech settings saved. Restarting bundled server..."
                do {
                    try await restartLocalServer()
                    statusMessage = "Speech settings saved. Bundled server restarted."
                } catch {
                    errorMessage = "Speech settings saved, but restarting bundled server failed: \(error.localizedDescription)"
                    return
                }

                do {
                    try await syncLocalServerSecrets()
                } catch {
                    errorMessage = "Speech settings saved and bundled server restarted, but syncing secrets failed: \(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "GROK_API_KEY was updated, but saving speech settings failed: \(error.localizedDescription)"
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
        loadedSTTModel = config.sttModel
        loadedTTSModel = config.ttsModel
        loadedGrokEnabled = config.services.grok.enabled
        loadedGrokBaseURL = config.services.grok.baseURLOverride
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

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadGrokAPIKeyState() throws {
        hasStoredGrokAPIKey = try keychain.containsValue(account: Self.grokAPIKeyAccount)
        maskedStoredGrokAPIKey = ""

        if hasStoredGrokAPIKey {
            do {
                let storedValue = try keychain.value(account: Self.grokAPIKeyAccount)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                maskedStoredGrokAPIKey = Self.maskedAPIKey(storedValue)
            } catch let error as KeychainError where error.isNonFatalReadAuthorizationFailure {
                // Keychain may allow existence checks while still requiring user authorization for the secret bytes.
                maskedStoredGrokAPIKey = ""
            }
        }

        grokAPIKey = ""
        hasEditedGrokAPIKey = false
    }

    private func grokAPIKeyUpdate() -> PendingGrokAPIKeyUpdate {
        guard hasEditedGrokAPIKey else {
            return .unchanged
        }

        let trimmedAPIKey = grokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAPIKey.isEmpty {
            return .clear
        }
        return .store(trimmedAPIKey)
    }

    private func applyGrokAPIKeyUpdate(_ update: PendingGrokAPIKeyUpdate) throws {
        switch update {
        case .unchanged:
            return
        case .store(let value):
            try keychain.upsert(value: value, account: Self.grokAPIKeyAccount)
        case .clear:
            try keychain.deleteValue(account: Self.grokAPIKeyAccount)
        }
    }

    private func localServerSecretUpdates(for update: PendingGrokAPIKeyUpdate) -> [String: String]? {
        switch update {
        case .unchanged:
            return nil
        case .store(let value):
            return [Self.grokAPIKeyAccount: value]
        case .clear:
            return [Self.grokAPIKeyAccount: ""]
        }
    }

    private func statusMessage(for update: PendingGrokAPIKeyUpdate) -> String {
        switch update {
        case .unchanged:
            return "No changes saved."
        case .store:
            return "Grok API key saved."
        case .clear:
            return "Grok API key removed."
        }
    }

    private static func maskedAPIKey(_ value: String?) -> String {
        guard let value,
              !value.isEmpty else {
            return ""
        }

        let suffix = String(value.suffix(4))
        return String(repeating: "*", count: 8) + suffix
    }
}

private enum PendingGrokAPIKeyUpdate {
    case unchanged
    case store(String)
    case clear
}
#endif
