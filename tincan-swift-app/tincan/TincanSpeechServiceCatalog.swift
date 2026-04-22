#if os(macOS)
import Foundation

enum TincanSpeechModelTarget: String, CaseIterable, Identifiable {
    case speechToText
    case textToSpeech

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speechToText:
            return "Speech to Text model"
        case .textToSpeech:
            return "Text to Speech model"
        }
    }
}

enum TincanSpeechServiceID: String, CaseIterable, Identifiable, Hashable {
    case grok

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok:
            return "Grok"
        }
    }
}

struct TincanSpeechModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

enum TincanSpeechServiceCatalog {
    static let defaultGrokBaseURL = "https://api.x.ai/v1"

    static func defaultModel(for target: TincanSpeechModelTarget) -> String {
        switch target {
        case .speechToText:
            return "macos/parakeet-tdt-0.6b-v3-coreml"
        case .textToSpeech:
            return "macos/kitten-tts-mini-0.8"
        }
    }

    static func options(
        for target: TincanSpeechModelTarget,
        enabledServices: Set<TincanSpeechServiceID>
    ) -> [TincanSpeechModelOption] {
        var result = [
            TincanSpeechModelOption(
                id: "\(target.rawValue)-default",
                title: defaultOptionTitle(for: target),
                value: defaultModel(for: target)
            ),
        ]

        if enabledServices.contains(.grok) {
            result.append(
                TincanSpeechModelOption(
                    id: "\(target.rawValue)-grok",
                    title: grokOptionTitle(for: target),
                    value: grokModel(for: target)
                )
            )
        }

        return result
    }

    static func normalizedModel(
        _ currentValue: String,
        for target: TincanSpeechModelTarget,
        disabling serviceID: TincanSpeechServiceID
    ) -> String {
        provider(for: currentValue) == serviceID ? defaultModel(for: target) : currentValue
    }

    static func provider(for selection: String) -> TincanSpeechServiceID? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = trimmed.firstIndex(of: "/") else {
            return nil
        }

        let provider = String(trimmed[..<separatorIndex]).lowercased()
        return TincanSpeechServiceID(rawValue: provider)
    }

    private static func defaultOptionTitle(for target: TincanSpeechModelTarget) -> String {
        switch target {
        case .speechToText:
            return "Parakeet (macOS default)"
        case .textToSpeech:
            return "Kitten (macOS default)"
        }
    }

    private static func grokOptionTitle(for target: TincanSpeechModelTarget) -> String {
        switch target {
        case .speechToText:
            return "Grok STT v1"
        case .textToSpeech:
            return "Grok TTS v1"
        }
    }

    private static func grokModel(for target: TincanSpeechModelTarget) -> String {
        switch target {
        case .speechToText:
            return "grok/grok-stt-v1"
        case .textToSpeech:
            return "grok/grok-tts-v1"
        }
    }
}
#endif
