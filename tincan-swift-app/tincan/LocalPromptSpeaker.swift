#if os(macOS)
import AVFoundation
import Foundation

@MainActor
final class LocalPromptSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var currentContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused
    }

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            currentContinuation?.resume()
            currentContinuation = nil
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = true

        await withCheckedContinuation { continuation in
            currentContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentContinuation?.resume()
        currentContinuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        currentContinuation?.resume()
        currentContinuation = nil
    }
}
#endif
