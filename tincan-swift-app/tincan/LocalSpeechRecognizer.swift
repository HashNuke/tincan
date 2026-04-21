#if os(macOS)
import Foundation
import Speech

enum LocalSpeechRecognizerError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioTooShort
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech recognition permission is required."
        case .recognizerUnavailable:
            "Speech recognition is currently unavailable on this Mac."
        case .audioTooShort:
            "The captured audio was too short to recognize."
        case .noTranscript:
            "No speech transcript was produced."
        }
    }
}

@MainActor
final class LocalSpeechRecognizer {
    nonisolated init() {}

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(audioWAV: Data) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw LocalSpeechRecognizerError.notAuthorized
        }

        guard audioWAV.count > 44 else {
            throw LocalSpeechRecognizerError.audioTooShort
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw LocalSpeechRecognizerError.recognizerUnavailable
        }

        let tempURL = AppPaths.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try FileManager.default.createDirectory(
            at: AppPaths.temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try audioWAV.write(to: tempURL, options: .atomic)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var recognitionTask: SFSpeechRecognitionTask?
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    recognitionTask?.cancel()
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal, !didResume {
                    didResume = true
                    recognitionTask?.cancel()
                    let transcript = result.bestTranscription.formattedString
                    if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(throwing: LocalSpeechRecognizerError.noTranscript)
                    } else {
                        continuation.resume(returning: transcript)
                    }
                }
            }
        }
    }
}
#endif
