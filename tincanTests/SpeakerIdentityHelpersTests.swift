import Foundation
import Testing
@testable import tincan

struct SpeakerIdentityHelpersTests {
    @Test func challengePhraseMatchingIgnoresCaseAndPunctuation() {
        let challenge = ChallengePhrase(text: "I like apples")

        #expect(ChallengePhraseProvider.matches(transcript: "I like apples.", expected: challenge))
        #expect(ChallengePhraseProvider.matches(transcript: "i LIKE apples", expected: challenge))
        #expect(!ChallengePhraseProvider.matches(transcript: "I like oranges", expected: challenge))
    }

    @Test func ownerProfileStorePersistsRoundTrip() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = OwnerProfileStore(fileURL: tempURL)
        let profile = OwnerVoiceProfile.bootstrap(embedding: [1, 0, 0, 0])

        try await store.saveProfile(profile)
        let loadedProfile = try await store.loadProfile()

        #expect(loadedProfile?.displayName == profile.displayName)
        #expect(loadedProfile?.canonicalEmbedding == profile.canonicalEmbedding)
        #expect(loadedProfile?.acceptedEmbeddings == profile.acceptedEmbeddings)
        #expect(loadedProfile?.modelIdentifier == profile.modelIdentifier)

        try await store.clearProfile()
        let clearedProfile = try await store.loadProfile()
        #expect(clearedProfile == nil)
    }

    @Test func speakerIdentityConfigUsesUncertainBand() {
        let config = SpeakerIdentityConfig(
            minimumClassificationDuration: 1.0,
            ownerAcceptanceDistance: 0.4,
            ownerRejectionDistance: 0.6,
            challengeAcceptanceDistance: 0.45,
            profileSmoothingAlpha: 0.8
        )

        #expect(config.classification(for: 0.35) == .owner)
        #expect(config.classification(for: 0.7) == .nonOwner)
        #expect(config.classification(for: 0.5) == .uncertain)
    }
}
