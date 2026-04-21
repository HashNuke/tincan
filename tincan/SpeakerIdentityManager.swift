#if os(macOS)
import FluidAudio
import Foundation

actor SpeakerIdentityManager {
    private let store: OwnerProfileStore
    private let speechRecognizer: LocalSpeechRecognizer
    private let phraseProvider = ChallengePhraseProvider()
    private let config: SpeakerIdentityConfig
    private let modelIdentifier = "FluidAudio.Diarizer"

    private var diarizerManager: DiarizerManager?
    private var ownerProfile: OwnerVoiceProfile?
    private var activeChallenge: ChallengePhrase?
    private var lastChallengeTranscript: String?
    private var speechRecognitionAuthorized = false

    init(
        store: OwnerProfileStore = OwnerProfileStore(),
        speechRecognizer: LocalSpeechRecognizer = LocalSpeechRecognizer(),
        config: SpeakerIdentityConfig = .default
    ) {
        self.store = store
        self.speechRecognizer = speechRecognizer
        self.config = config
    }

    func prepare() async throws -> SpeakerIdentityStatus {
        _ = try await loadProfileIfNeeded()

        if diarizerManager == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizerManager = manager
        }

        return makeStatus()
    }

    func currentStatus() async -> SpeakerIdentityStatus {
        do {
            _ = try await loadProfileIfNeeded()
        } catch {
            return SpeakerIdentityStatus(
                phase: .unavailable,
                description: error.localizedDescription,
                ownerProfileName: nil,
                challengePrompt: nil,
                lastChallengeTranscript: nil
            )
        }
        return makeStatus()
    }

    func hasOwnerProfile() async -> Bool {
        do {
            return try await loadProfileIfNeeded() != nil
        } catch {
            return false
        }
    }

    func setSpeechRecognitionAuthorized(_ value: Bool) {
        speechRecognitionAuthorized = value
    }

    func beginIdentification() async -> SpeakerIdentityStatus {
        lastChallengeTranscript = nil

        guard speechRecognitionAuthorized else {
            return makeStatus(
                phase: .unavailable,
                description: "Speech recognition permission is required before this Mac can identify the current speaker."
            )
        }

        activeChallenge = phraseProvider.nextPhrase()
        return makeStatus(
            phase: .awaitingChallengeResponse,
            description: "Say the challenge phrase to identify yourself before audio is sent."
        )
    }

    func resetOwnerProfile() async throws -> SpeakerIdentityStatus {
        try await store.clearProfile()
        ownerProfile = nil
        lastChallengeTranscript = nil
        activeChallenge = speechRecognitionAuthorized ? phraseProvider.nextPhrase() : nil

        return makeStatus(
            phase: activeChallenge == nil ? .identificationRequired : .awaitingChallengeResponse,
            description: activeChallenge == nil
                ? "The current-user voice profile was removed."
                : "The current-user voice profile was removed. Say the new challenge phrase to identify yourself again."
        )
    }

    func processSegment(_ segment: CapturedSpeechSegment) async -> SpeakerIdentityOutcome {
        do {
            _ = try await prepare()

            if let challenge = activeChallenge {
                return try await processChallengeResponse(segment, challenge: challenge)
            }

            guard let ownerProfile = try await loadProfileIfNeeded() else {
                if speechRecognitionAuthorized {
                    activeChallenge = phraseProvider.nextPhrase()
                    return blockedOutcome(
                        "Speaker is unknown. Identification is required before audio can be sent.",
                        phase: .awaitingChallengeResponse,
                        description: "Say the challenge phrase before tincan uploads anything to the backend."
                    )
                }

                return blockedOutcome(
                    "Speech recognition permission is required before this Mac can identify the current speaker.",
                    phase: .unavailable,
                    description: "Speech recognition permission is required before this Mac can identify the current speaker."
                )
            }

            guard segment.duration >= config.minimumClassificationDuration else {
                return blockedOutcome(
                    "Ignored a short speech segment (\(segment.duration.formatted(.number.precision(.fractionLength(2))))s) while waiting for a reliable speaker match."
                )
            }

            let embedding = try extractEmbedding(from: segment.samples)
            let distance = embedding.cosineDistance(to: ownerProfile.canonicalEmbedding)

            switch config.classification(for: distance) {
            case .owner:
                return SpeakerIdentityOutcome(
                    segmentApprovedForUpload: segment,
                    status: makeStatus(
                        phase: .ownerVerified,
                        description: "Only your voice is being sent to the backend."
                    ),
                    logMessage: "Accepted speech from the current user (distance \(distance.formatted(.number.precision(.fractionLength(2)))))."
                )
            case .nonOwner:
                return blockedOutcome(
                    "Filtered speech from a non-owner speaker (distance \(distance.formatted(.number.precision(.fractionLength(2)))))."
                )
            case .uncertain:
                guard speechRecognitionAuthorized else {
                    return blockedOutcome(
                        "Speaker match was uncertain and speech recognition permission is unavailable for recovery.",
                        phase: .unavailable,
                        description: "Speaker match was uncertain and speech recognition permission is unavailable for recovery."
                    )
                }

                activeChallenge = phraseProvider.nextPhrase()
                lastChallengeTranscript = nil
                return blockedOutcome(
                    "Speaker match was uncertain (distance \(distance.formatted(.number.precision(.fractionLength(2))))). Challenge required before more audio can be sent.",
                    phase: .awaitingChallengeResponse,
                    description: "tincan is not sure the current speaker is you. Say the challenge phrase to continue."
                )
            }
        } catch {
            return blockedOutcome(
                "Speaker identification failed: \(error.localizedDescription)",
                phase: .unavailable,
                description: "Speaker identification failed: \(error.localizedDescription)"
            )
        }
    }

    private func processChallengeResponse(
        _ segment: CapturedSpeechSegment,
        challenge: ChallengePhrase
    ) async throws -> SpeakerIdentityOutcome {
        guard segment.duration >= config.minimumClassificationDuration else {
            return blockedOutcome(
                "Challenge response was too short. Say the challenge phrase again.",
                phase: .awaitingChallengeResponse,
                description: "Challenge response was too short. Say the challenge phrase again."
            )
        }

        let transcript = try await speechRecognizer.transcribe(audioWAV: segment.wavData)
        lastChallengeTranscript = transcript

        guard ChallengePhraseProvider.matches(transcript: transcript, expected: challenge) else {
            activeChallenge = phraseProvider.nextPhrase()
            return blockedOutcome(
                "Challenge transcript did not match. tincan heard “\(transcript)”.",
                phase: .awaitingChallengeResponse,
                description: "The spoken challenge phrase did not match. Say the new challenge phrase to continue."
            )
        }

        let embedding = try extractEmbedding(from: segment.samples)
        if let existingProfile = try await loadProfileIfNeeded() {
            let distance = embedding.cosineDistance(to: existingProfile.canonicalEmbedding)
            guard distance <= config.challengeAcceptanceDistance else {
                activeChallenge = phraseProvider.nextPhrase()
                return blockedOutcome(
                    "Challenge phrase matched but the voice did not match the current-user profile (distance \(distance.formatted(.number.precision(.fractionLength(2))))).",
                    phase: .awaitingChallengeResponse,
                    description: "The phrase matched, but the voice did not match the current-user profile. Say the new challenge phrase to continue."
                )
            }

            let refreshedProfile = existingProfile.refreshed(with: embedding, config: config)
            try await store.saveProfile(refreshedProfile)
            ownerProfile = refreshedProfile
        } else {
            let newProfile = OwnerVoiceProfile.bootstrap(
                embedding: embedding,
                modelIdentifier: modelIdentifier
            )
            try await store.saveProfile(newProfile)
            ownerProfile = newProfile
        }

        activeChallenge = nil
        return SpeakerIdentityOutcome(
            segmentApprovedForUpload: nil,
            status: makeStatus(
                phase: .ownerVerified,
                description: "Current user verified. Repeat your request to send it to the backend."
            ),
            logMessage: "Current speaker verified successfully. Repeat the request to continue."
        )
    }

    private func loadProfileIfNeeded() async throws -> OwnerVoiceProfile? {
        if let ownerProfile {
            return ownerProfile
        }

        let loadedProfile = try await store.loadProfile()
        ownerProfile = loadedProfile
        return loadedProfile
    }

    private func extractEmbedding(from samples: [Float]) throws -> [Float] {
        guard let diarizerManager else {
            throw NSError(domain: "SpeakerIdentityManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speaker models are not ready."
            ])
        }

        return try diarizerManager.extractSpeakerEmbedding(from: samples)
    }

    private func blockedOutcome(
        _ logMessage: String,
        phase: SpeakerIdentityPhase? = nil,
        description: String? = nil
    ) -> SpeakerIdentityOutcome {
        SpeakerIdentityOutcome(
            segmentApprovedForUpload: nil,
            status: makeStatus(phase: phase, description: description),
            logMessage: logMessage
        )
    }

    private func makeStatus(
        phase requestedPhase: SpeakerIdentityPhase? = nil,
        description requestedDescription: String? = nil
    ) -> SpeakerIdentityStatus {
        let computedPhase: SpeakerIdentityPhase
        if let requestedPhase {
            computedPhase = requestedPhase
        } else if activeChallenge != nil {
            computedPhase = .awaitingChallengeResponse
        } else if ownerProfile != nil {
            computedPhase = .ownerVerified
        } else if speechRecognitionAuthorized {
            computedPhase = .identificationRequired
        } else {
            computedPhase = .unavailable
        }

        let description: String
        if let requestedDescription {
            description = requestedDescription
        } else {
            switch computedPhase {
            case .preparing:
                description = "Preparing speaker identification."
            case .identificationRequired:
                description = "Identify the current speaker before tincan uploads audio."
            case .awaitingChallengeResponse:
                description = "Say the challenge phrase before tincan uploads audio."
            case .ownerVerified:
                description = "Only your voice is being sent to the backend."
            case .unavailable:
                description = "Speaker identification is unavailable."
            }
        }

        return SpeakerIdentityStatus(
            phase: computedPhase,
            description: description,
            ownerProfileName: ownerProfile?.displayName,
            challengePrompt: activeChallenge?.text,
            lastChallengeTranscript: lastChallengeTranscript
        )
    }
}
#endif
