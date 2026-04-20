import Foundation
import Vapor

protocol Summarizer: Sendable {
    var key: String { get }
    func summarize(_ text: String) async throws -> String
}

struct NoSummarySummarizer: Summarizer {
    let key = "no-summary"

    func summarize(_ text: String) async throws -> String {
        text
    }
}

struct PluginRegistry: Sendable {
    let summarizers: [String: any Summarizer]

    static let `default` = PluginRegistry(
        summarizers: [
            "no-summary": NoSummarySummarizer(),
        ]
    )

    func summarizer(named name: String) -> (any Summarizer)? {
        summarizers[name]
    }
}

private struct PluginRegistryKey: StorageKey {
    typealias Value = PluginRegistry
}

extension Application {
    var pluginRegistry: PluginRegistry {
        get {
            storage[PluginRegistryKey.self] ?? .default
        }
        set {
            storage[PluginRegistryKey.self] = newValue
        }
    }
}
