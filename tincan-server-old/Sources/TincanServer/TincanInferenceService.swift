import FluidAudio
import Foundation
import Vapor

actor TincanInferenceService {
    private enum State {
        case idle
        case loading(Task<AsrManager, any Error>)
        case ready(AsrManager)
    }

    private var state: State = .idle

    func health() -> AsrHealthResponse {
        AsrHealthResponse(
            modelCacheDirectory: AsrModels.defaultCacheDirectory().path,
            isModelReady: isModelReady
        )
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        let manager = try await asrManager()
        let result = try await manager.transcribe(audioFileURL)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isModelReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    private func asrManager() async throws -> AsrManager {
        switch state {
        case let .ready(manager):
            return manager
        case let .loading(task):
            let manager = try await task.value
            state = .ready(manager)
            return manager
        case .idle:
            let task = Task { () throws -> AsrManager in
                let models = try await AsrModels.downloadAndLoad()
                let manager = AsrManager()
                try await manager.loadModels(models)
                return manager
            }

            state = .loading(task)

            do {
                let manager = try await task.value
                state = .ready(manager)
                return manager
            } catch {
                state = .idle
                throw error
            }
        }
    }
}

private struct TincanInferenceServiceKey: StorageKey {
    typealias Value = TincanInferenceService
}

extension Application {
    var tincanInferenceService: TincanInferenceService {
        get {
            guard let service = storage[TincanInferenceServiceKey.self] else {
                fatalError("TincanInferenceService not configured")
            }
            return service
        }
        set {
            storage[TincanInferenceServiceKey.self] = newValue
        }
    }
}

struct AsrHealthResponse: Sendable {
    let modelCacheDirectory: String
    let isModelReady: Bool
}
