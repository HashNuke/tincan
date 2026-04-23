#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class MacOnboardingViewModel: ObservableObject {
    enum Step {
        case preflight
        case agents
    }

    enum AgentBackend: String, CaseIterable, Identifiable, Codable {
        case opencode

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .opencode:
                return "OpenCode"
            }
        }

        var configBackendType: String {
            rawValue
        }
    }

    struct AgentDraft: Identifiable, Equatable {
        let id: UUID
        var name: String
        var backend: AgentBackend
        var agentFolder: String
        var model: String
    }

    @Published private(set) var step: Step = .preflight
    @Published private(set) var isCompleted: Bool
    @Published private(set) var isCheckingOpencode = false
    @Published private(set) var opencodePath: String?
    @Published private(set) var modelOptionsByBackend: [AgentBackend: [String]] = [:]
    @Published private(set) var preflightErrorMessage: String?
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var isSaving = false
    @Published var additionalAgents: [AgentDraft] = []

    let atlasName = "Atlas"
    let atlasBackend: AgentBackend = .opencode
    let atlasAgentFolder: String

    init() {
        atlasAgentFolder = AppPaths.appSupportDirectory.path
        isCompleted = Self.hasGeneratedAgentProfiles()

        if !isCompleted {
            refreshOpenCodeStatus()
        }
    }

    var atlasModel: String {
        preferredModel(for: atlasBackend) ?? ""
    }

    var canContinueFromPreflight: Bool {
        opencodePath != nil && !availableModels(for: .opencode).isEmpty
    }

    var canSaveAgents: Bool {
        guard !atlasModel.isEmpty else {
            return false
        }

        return additionalAgents.allSatisfy { draft in
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.agentFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func refreshOpenCodeStatus() {
        isCheckingOpencode = true
        preflightErrorMessage = nil
        saveErrorMessage = nil
        opencodePath = nil
        modelOptionsByBackend[.opencode] = []

        Task {
            do {
                let detection = try Self.detectOpenCode()
                opencodePath = detection.path
                modelOptionsByBackend[.opencode] = detection.models
                resetAdditionalAgentModelsIfNeeded()
            } catch {
                preflightErrorMessage = error.localizedDescription
            }
            isCheckingOpencode = false
        }
    }

    func continueToAgentSetup() {
        guard canContinueFromPreflight else { return }
        step = .agents
    }

    func returnToPreflight() {
        step = .preflight
    }

    func addAgent() {
        let defaultModel = preferredModel(for: .opencode) ?? ""
        additionalAgents.append(AgentDraft(
            id: UUID(),
            name: "",
            backend: .opencode,
            agentFolder: "",
            model: defaultModel
        ))
    }

    func removeAgent(id: UUID) {
        additionalAgents.removeAll { $0.id == id }
    }

    func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder this agent should work in."

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        updateAgentFolder(folderURL.path, for: id)
    }

    func updateAgentFolder(_ path: String, for id: UUID) {
        guard let index = additionalAgents.firstIndex(where: { $0.id == id }) else {
            return
        }

        additionalAgents[index].agentFolder = path
        if additionalAgents[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            additionalAgents[index].name = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func updateBackend(_ backend: AgentBackend, for id: UUID) {
        guard let index = additionalAgents.firstIndex(where: { $0.id == id }) else {
            return
        }

        additionalAgents[index].backend = backend
        let allowedModels = availableModels(for: backend)
        if !allowedModels.contains(additionalAgents[index].model) {
            additionalAgents[index].model = preferredModel(for: backend) ?? ""
        }
    }

    func availableModels(for backend: AgentBackend) -> [String] {
        modelOptionsByBackend[backend] ?? []
    }

    func filteredModelSuggestions(for draft: AgentDraft) -> [String] {
        let options = availableModels(for: draft.backend)
        let query = draft.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return Array(options.prefix(6))
        }

        let filtered = options.filter { $0.lowercased().contains(query) }
        return Array(filtered.prefix(6))
    }

    func completeOnboarding() {
        guard canSaveAgents, !isSaving else { return }

        isSaving = true
        saveErrorMessage = nil

        do {
            try writeGeneratedConfig()
            refreshCompletionFromDisk()
        } catch {
            saveErrorMessage = error.localizedDescription
        }

        isSaving = false
    }

    private func preferredModel(for backend: AgentBackend) -> String? {
        let options = availableModels(for: backend)
        if options.contains("openai/gpt-5.3-codex-spark") {
            return "openai/gpt-5.3-codex-spark"
        }
        return options.first
    }

    private func resetAdditionalAgentModelsIfNeeded() {
        for index in additionalAgents.indices {
            let backend = additionalAgents[index].backend
            let allowedModels = availableModels(for: backend)
            if !allowedModels.contains(additionalAgents[index].model) {
                additionalAgents[index].model = preferredModel(for: backend) ?? ""
            }
        }
    }

    private func writeGeneratedConfig() throws {
        let encoder = JSONEncoder.tincanFileEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        var backendNamesInUse: Set<String> = ["__router__", "opencode"]
        var backendDefinitions: [String: GeneratedAgentBackend] = [
            "__router__": makeBackendDefinition(model: atlasModel, backend: atlasBackend),
            "opencode": makeBackendDefinition(model: atlasModel, backend: atlasBackend),
        ]

        var profileKeysInUse: Set<String> = ["atlas"]
        var profiles: [String: GeneratedAgentProfile] = [
            "atlas": GeneratedAgentProfile(
                name: atlasName,
                workingDirectory: atlasAgentFolder,
                agentBackend: "opencode"
            ),
        ]

        for draft in additionalAgents {
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedFolder = draft.agentFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let backendName = uniqueBackendName(for: draft, backendNamesInUse: &backendNamesInUse)

            backendDefinitions[backendName] = makeBackendDefinition(model: trimmedModel, backend: draft.backend)
            let profileKey = uniqueProfileKey(for: trimmedName, profileKeysInUse: &profileKeysInUse)
            profiles[profileKey] = GeneratedAgentProfile(
                name: trimmedName,
                workingDirectory: trimmedFolder,
                agentBackend: backendName
            )
        }

        let backendsData = try encoder.encode(backendDefinitions)
        let profilesData = try encoder.encode(profiles)

        try backendsData.write(to: AppPaths.generatedAgentBackendsURL, options: .atomic)
        try profilesData.write(to: AppPaths.generatedAgentProfilesURL, options: .atomic)
    }

    private func uniqueBackendName(for draft: AgentDraft, backendNamesInUse: inout Set<String>) -> String {
        let baseName = "\(draft.backend.rawValue)-\(slugify(draft.name))"
        var candidate = baseName
        var counter = 2

        while backendNamesInUse.contains(candidate) || candidate.isEmpty {
            candidate = "\(baseName)-\(counter)"
            counter += 1
        }

        backendNamesInUse.insert(candidate)
        return candidate
    }

    private func uniqueProfileKey(for name: String, profileKeysInUse: inout Set<String>) -> String {
        let baseName = slugify(name)
        var candidate = baseName
        var counter = 2

        while profileKeysInUse.contains(candidate) || candidate.isEmpty {
            candidate = "\(baseName)-\(counter)"
            counter += 1
        }

        profileKeysInUse.insert(candidate)
        return candidate
    }

    private func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "agent" : collapsed
    }

    private func makeBackendDefinition(model: String, backend: AgentBackend) -> GeneratedAgentBackend {
        switch backend {
        case .opencode:
            return GeneratedAgentBackend(
                type: backend.configBackendType,
                options: GeneratedAgentBackendOptions(
                    connectionType: "command",
                    command: commandPath(for: backend),
                    model: model,
                    modelVariant: "medium",
                    agent: "build",
                    extraArgs: []
                )
            )
        }
    }

    private func commandPath(for backend: AgentBackend) -> String? {
        switch backend {
        case .opencode:
            return opencodePath
        }
    }

    private func refreshCompletionFromDisk() {
        isCompleted = Self.hasGeneratedAgentProfiles()
    }

    private static func hasGeneratedAgentProfiles() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.generatedAgentProfilesURL.path)
    }

    private static func detectOpenCode() throws -> OpenCodeDetection {
        let path = try runLoginShell("command -v opencode").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw OnboardingError(message: "OpenCode not found on PATH.")
        }

        let rawModels = try runLoginShell("opencode models")
        let models = parseOpenCodeModels(rawModels)
        guard !models.isEmpty else {
            throw OnboardingError(message: "OpenCode was found, but `opencode models` returned no usable models.")
        }

        return OpenCodeDetection(path: path, models: models)
    }

    private static func runLoginShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw OnboardingError(message: "Command failed: \(command)")
            }
            throw OnboardingError(message: message)
        }

        return output
    }

    private static func parseOpenCodeModels(_ raw: String) -> [String] {
        var seen = Set<String>()
        var models: [String] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            for field in line.split(whereSeparator: \.isWhitespace) {
                let value = String(field)
                guard looksLikeOpenCodeModel(value), !seen.contains(value) else {
                    continue
                }
                seen.insert(value)
                models.append(value)
            }
        }

        return models.sorted()
    }

    private static func looksLikeOpenCodeModel(_ value: String) -> Bool {
        if value == "provider/model" || value.contains("://") {
            return false
        }

        guard let slashIndex = value.firstIndex(of: "/") else {
            return false
        }

        let providerID = String(value[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let modelStartIndex = value.index(after: slashIndex)
        guard modelStartIndex < value.endIndex else {
            return false
        }

        let modelID = String(value[modelStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !providerID.isEmpty && !modelID.isEmpty
    }
}

private struct OpenCodeDetection {
    let path: String
    let models: [String]
}

private struct OnboardingError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct GeneratedAgentProfile: Encodable {
    let name: String
    let workingDirectory: String
    let agentBackend: String
}

private struct GeneratedAgentBackend: Encodable {
    let type: String
    let options: GeneratedAgentBackendOptions
}

private struct GeneratedAgentBackendOptions: Encodable {
    let connectionType: String
    let command: String?
    let model: String
    let modelVariant: String
    let agent: String
    let extraArgs: [String]
}
#endif
