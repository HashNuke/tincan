import FluidAudio
import Foundation
import Vapor

actor TincanSpeechService {
    private enum State {
        case idle
        case loading(Task<PocketTtsManager, any Error>)
        case ready(PocketTtsManager)
    }

    static let defaultVoice = "alba"

    private var state: State = .idle

    func health() -> TtsHealthResponse {
        TtsHealthResponse(
            defaultVoice: Self.defaultVoice,
            isModelReady: isModelReady
        )
    }

    func synthesize(text: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Expected non-empty text")
        }

        let manager = try await pocketTtsManager()
        let session = try await manager.makeSession(voice: Self.defaultVoice)
        session.enqueue(trimmed)
        session.finish()

        var samples: [Float] = []
        for try await frame in session.frames {
            samples.append(contentsOf: frame.samples)
        }

        guard !samples.isEmpty else {
            throw Abort(.internalServerError, reason: "PocketTTS produced no audio")
        }

        return try AudioWAV.data(
            from: samples,
            sampleRate: Double(PocketTtsConstants.audioSampleRate)
        )
    }

    private var isModelReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    private func pocketTtsManager() async throws -> PocketTtsManager {
        switch state {
        case let .ready(manager):
            return manager
        case let .loading(task):
            let manager = try await task.value
            state = .ready(manager)
            return manager
        case .idle:
            let task = Task { () throws -> PocketTtsManager in
                let manager = PocketTtsManager(defaultVoice: Self.defaultVoice)
                try await manager.initialize()
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

private struct TincanSpeechServiceKey: StorageKey {
    typealias Value = TincanSpeechService
}

extension Application {
    var tincanSpeechService: TincanSpeechService {
        get {
            guard let service = storage[TincanSpeechServiceKey.self] else {
                fatalError("TincanSpeechService not configured")
            }
            return service
        }
        set {
            storage[TincanSpeechServiceKey.self] = newValue
        }
    }
}
