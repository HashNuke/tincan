import Foundation
import Testing
#if os(macOS)
import FluidAudio
#endif
@testable import tincan

struct SpeakerIdentityHelpersTests {
    @Test func fileJSONEncoderDoesNotEscapeSlashes() throws {
        struct PathPayload: Codable {
            let baseURL: String
            let model: String
            let workingDirectory: String
        }

        let payload = PathPayload(
            baseURL: "http://127.0.0.1:4096",
            model: "openai/gpt-5.3-codex-spark",
            workingDirectory: "/Users/akash/code/apple/tincan"
        )

        let data = try JSONEncoder.tincanFileEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""baseURL" : "http://127.0.0.1:4096""#))
        #expect(json.contains(#""model" : "openai/gpt-5.3-codex-spark""#))
        #expect(json.contains(#""workingDirectory" : "/Users/akash/code/apple/tincan""#))
        #expect(!json.contains(#"\/"#))
    }

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
        let profile = OwnerVoiceProfile.bootstrap(
            embedding: [1, 0, 0, 0],
            sampleDuration: 1.4,
            inputDeviceName: "Studio Display Microphone"
        )

        try await store.saveProfile(profile)
        let loadedProfile = try await store.loadProfile()

        #expect(loadedProfile?.displayName == profile.displayName)
        #expect(loadedProfile?.canonicalEmbedding == profile.canonicalEmbedding)
        #expect(loadedProfile?.speakerProfiles == profile.speakerProfiles)
        #expect(loadedProfile?.modelIdentifier == profile.modelIdentifier)

        try await store.clearProfile()
        let clearedProfile = try await store.loadProfile()
        #expect(clearedProfile == nil)
    }

    @Test func ownerProfileDecodesLegacyAcceptedEmbeddings() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let json = """
        {
          "acceptedEmbeddings" : [
            [
              1,
              0,
              0,
              0
            ],
            [
              0,
              1,
              0,
              0
            ]
          ],
          "canonicalEmbedding" : [
            1,
            0,
            0,
            0
          ],
          "createdAt" : "2026-04-21T00:00:00Z",
          "displayName" : "Current User",
          "id" : "0E5F4DE8-A52E-42FD-9CA8-0D15F2F17B89",
          "modelIdentifier" : "FluidAudio.Diarizer",
          "successfulIdentifications" : 2,
          "updatedAt" : "2026-04-21T00:00:00Z"
        }
        """

        let profile = try decoder.decode(OwnerVoiceProfile.self, from: Data(json.utf8))

        #expect(profile.speakerProfiles.count == 2)
        #expect(profile.speakerProfiles[0].embedding == [1, 0, 0, 0])
        #expect(profile.speakerProfiles[1].embedding == [0, 1, 0, 0])
    }

    @Test func ownerProfileMatchesNearestStoredSample() {
        let profile = OwnerVoiceProfile(
            canonicalEmbedding: [1, 0, 0, 0],
            speakerProfiles: [
                SpeakerProfileSample(embedding: [1, 0, 0, 0], sampleDuration: 1.0),
                SpeakerProfileSample(embedding: [0, 1, 0, 0], sampleDuration: 1.0)
            ]
        )

        #expect(profile.bestMatchDistance(for: [0, 1, 0, 0]) == 0)
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

#if os(macOS)
    @Test func groupsDiarizedSegmentsPerSpeaker() {
        let grouped = SpeakerIdentityHelpers.groupSpeakerSegments(
            [
                TimedSpeakerSegment(
                    speakerId: "speaker-a",
                    embedding: [1, 0],
                    startTimeSeconds: 0.0,
                    endTimeSeconds: 0.5,
                    qualityScore: 0.9
                ),
                TimedSpeakerSegment(
                    speakerId: "speaker-b",
                    embedding: [0, 1],
                    startTimeSeconds: 0.6,
                    endTimeSeconds: 1.0,
                    qualityScore: 0.8
                ),
                TimedSpeakerSegment(
                    speakerId: "speaker-a",
                    embedding: [0.8, 0.2],
                    startTimeSeconds: 1.1,
                    endTimeSeconds: 1.4,
                    qualityScore: 0.85
                )
            ],
            sampleRate: 16_000,
            sampleCount: 32_000
        )

        #expect(grouped.count == 2)
        #expect(grouped[0].speakerId == "speaker-a")
        #expect(grouped[0].spans.count == 2)
        #expect(grouped[0].totalDuration > 0.79 && grouped[0].totalDuration < 0.81)
        #expect(grouped[0].mergedEmbedding[0] > grouped[0].mergedEmbedding[1])
        #expect(grouped[1].speakerId == "speaker-b")
        #expect(grouped[1].spans.count == 1)
    }

    @Test func challengeSpeakerMatchingReturnsAllMatchingSpeakers() {
        let challenge = ChallengePhrase(text: "I like apples")
        let transcripts = [
            SpeakerTranscript(speakerId: "speaker-a", transcript: "I like apples"),
            SpeakerTranscript(speakerId: "speaker-b", transcript: "I like oranges"),
            SpeakerTranscript(speakerId: "speaker-c", transcript: "I like apples.")
        ]

        let matchingSpeakerIDs = SpeakerIdentityHelpers.matchingSpeakerIDs(
            in: transcripts,
            expected: challenge
        )

        #expect(matchingSpeakerIDs == ["speaker-a", "speaker-c"])
        #expect(
            SpeakerIdentityHelpers.challengeTranscriptSummary(for: transcripts)
                == "speaker-a: I like apples | speaker-b: I like oranges | speaker-c: I like apples."
        )
    }
#endif
}
