import Foundation
import Vapor

struct AgentProfile: Content, Sendable, Equatable {
    let name: String
    let workingDirectory: String
    let agentBackend: AgentBackend
    let summarizer: String
    let agentBackendOptions: AgentBackendOptions

    enum CodingKeys: String, CodingKey {
        case name
        case workingDirectory = "working_directory"
        case agentBackend = "agent_backend"
        case summarizer
        case agentBackendOptions = "agent_backend_options"
    }
}

enum AgentBackend: String, Content, Sendable {
    case codex
    case opencode
    case opencodeServer = "opencode-server"
}

struct AgentBackendOptions: Content, Sendable, Equatable {
    let model: String
    let modelEffort: String?
    let baseURL: String?
    let agent: String?
    let extraArgs: [String]

    enum CodingKeys: String, CodingKey {
        case model
        case modelEffort = "model_effort"
        case baseURL = "base_url"
        case agent
        case extraArgs = "extra_args"
    }
}

actor AgentProfileStore {
    private let profiles: [AgentProfile]

    init(resourceName: String = "agent_profiles", bundle: Bundle = .module) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw Abort(.internalServerError, reason: "Missing agent profile resource: \(resourceName).json")
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let profiles = try decoder.decode([AgentProfile].self, from: data)

        try Self.validate(profiles)
        self.profiles = profiles
    }

    func list() -> [AgentProfile] {
        profiles
    }

    func profile(named name: String) -> AgentProfile? {
        profiles.first { $0.name == name }
    }

    private static func validate(_ profiles: [AgentProfile]) throws {
        var seenNames = Set<String>()

        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.internalServerError, reason: "Agent profile name must not be empty")
            }

            guard !profile.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.internalServerError, reason: "Agent profile working_directory must not be empty")
            }

            guard !profile.agentBackendOptions.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.internalServerError, reason: "Agent profile model must not be empty")
            }

            guard !profile.summarizer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.internalServerError, reason: "Agent profile summarizer must not be empty")
            }

            guard seenNames.insert(profile.name).inserted else {
                throw Abort(.internalServerError, reason: "Duplicate agent profile name: \(profile.name)")
            }
        }
    }
}

private struct AgentProfileStoreKey: StorageKey {
    typealias Value = AgentProfileStore
}

extension Application {
    var agentProfileStore: AgentProfileStore {
        get {
            guard let store = storage[AgentProfileStoreKey.self] else {
                fatalError("AgentProfileStore not configured")
            }
            return store
        }
        set {
            storage[AgentProfileStoreKey.self] = newValue
        }
    }
}
