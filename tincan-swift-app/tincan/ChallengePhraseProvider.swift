import Foundation

nonisolated struct ChallengePhrase: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let issuedAt: Date

    init(id: UUID = UUID(), text: String, issuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.issuedAt = issuedAt
    }
}

nonisolated struct ChallengePhraseProvider {
    private static let phrases = [
        "I like apples",
        "Today I am talking to tincan",
        "Please verify my voice on this Mac",
        "This coding call belongs to me",
        "Only send my words to the backend",
        "The current speaker is the Mac owner",
    ]

    func nextPhrase() -> ChallengePhrase {
        let phrase = Self.phrases.randomElement() ?? "I like apples"
        return ChallengePhrase(text: phrase)
    }

    static func normalizeTranscript(_ text: String) -> String {
        let lowercased = text.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func matches(transcript: String, expected challenge: ChallengePhrase) -> Bool {
        let normalizedTranscript = normalizeTranscript(transcript)
        let normalizedExpected = normalizeTranscript(challenge.text)

        guard !normalizedExpected.isEmpty else { return false }
        return normalizedTranscript == normalizedExpected || normalizedTranscript.contains(normalizedExpected)
    }
}
