#if os(macOS)
import AVFoundation
import FluidAudio
import Foundation

struct SpeakerTranscript: Sendable, Equatable {
    let speakerId: String
    let transcript: String
}

struct SpeakerSegmentSpan: Sendable, Equatable {
    let speakerId: String
    let startSample: Int
    let endSample: Int
    let duration: TimeInterval
    let embedding: [Float]
}

struct SpeakerSegmentGroup: Sendable, Equatable {
    let speakerId: String
    let spans: [SpeakerSegmentSpan]
    let totalDuration: TimeInterval
    let mergedEmbedding: [Float]
}

struct SpeakerIsolatedSegment: Sendable {
    let speakerId: String
    let samples: [Float]
    let wavData: Data
    let sampleRate: Int
    let duration: TimeInterval
    let embedding: [Float]
}

enum SpeakerIdentityHelpers {
    static func groupSpeakerSegments(
        _ diarizedSegments: [TimedSpeakerSegment],
        sampleRate: Int,
        sampleCount: Int
    ) -> [SpeakerSegmentGroup] {
        guard sampleRate > 0, sampleCount > 0 else { return [] }

        var speakerOrder: [String] = []
        var groupedSpans: [String: [SpeakerSegmentSpan]] = [:]

        for diarizedSegment in diarizedSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let startSample = max(
                0,
                min(sampleCount, Int((Double(diarizedSegment.startTimeSeconds) * Double(sampleRate)).rounded(.down)))
            )
            let endSample = max(
                startSample,
                min(sampleCount, Int((Double(diarizedSegment.endTimeSeconds) * Double(sampleRate)).rounded(.up)))
            )

            guard endSample > startSample else {
                continue
            }

            if groupedSpans[diarizedSegment.speakerId] == nil {
                speakerOrder.append(diarizedSegment.speakerId)
                groupedSpans[diarizedSegment.speakerId] = []
            }

            groupedSpans[diarizedSegment.speakerId]?.append(
                SpeakerSegmentSpan(
                    speakerId: diarizedSegment.speakerId,
                    startSample: startSample,
                    endSample: endSample,
                    duration: Double(endSample - startSample) / Double(sampleRate),
                    embedding: diarizedSegment.embedding
                )
            )
        }

        return speakerOrder.compactMap { speakerId in
            guard let spans = groupedSpans[speakerId], !spans.isEmpty else {
                return nil
            }

            return SpeakerSegmentGroup(
                speakerId: speakerId,
                spans: spans,
                totalDuration: spans.reduce(0) { $0 + $1.duration },
                mergedEmbedding: mergedEmbedding(for: spans)
            )
        }
    }

    static func matchingSpeakerIDs(
        in transcripts: [SpeakerTranscript],
        expected challenge: ChallengePhrase
    ) -> [String] {
        transcripts
            .filter { ChallengePhraseProvider.matches(transcript: $0.transcript, expected: challenge) }
            .map(\.speakerId)
    }

    static func challengeTranscriptSummary(for transcripts: [SpeakerTranscript]) -> String? {
        guard !transcripts.isEmpty else { return nil }

        return transcripts
            .prefix(3)
            .map { "\($0.speakerId): \($0.transcript)" }
            .joined(separator: " | ")
    }

    private static func mergedEmbedding(for spans: [SpeakerSegmentSpan]) -> [Float] {
        guard let first = spans.first else { return [] }
        let dimension = first.embedding.count
        guard dimension > 0 else { return [] }

        var weightedEmbedding = [Float](repeating: 0, count: dimension)
        var totalWeight: Float = 0

        for span in spans {
            guard span.embedding.count == dimension else { continue }
            let normalizedEmbedding = span.embedding.l2Normalized()
            let weight = max(Float(span.duration), 0.01)
            totalWeight += weight

            for index in weightedEmbedding.indices {
                weightedEmbedding[index] += normalizedEmbedding[index] * weight
            }
        }

        guard totalWeight > 0 else {
            return first.embedding.l2Normalized()
        }

        return weightedEmbedding
            .map { $0 / totalWeight }
            .l2Normalized()
    }
}

actor SpeakerIdentityManager {
    private let store: OwnerProfileStore
    private let speechRecognizer: LocalSpeechRecognizer
    private let phraseProvider = ChallengePhraseProvider()
    private let config: SpeakerIdentityConfig
    private let modelIdentifier = "FluidAudio.Diarizer"
    private let interSegmentSilenceDuration: TimeInterval = 0.12

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

            let isolatedSpeakerSegments = try isolateSpeakerSegments(from: segment)
            let eligibleSpeakerSegments = isolatedSpeakerSegments.filter {
                $0.duration >= config.minimumClassificationDuration
            }

            guard !eligibleSpeakerSegments.isEmpty else {
                return blockedOutcome(
                    "Ignored only short diarized speaker clips while waiting for a reliable speaker match."
                )
            }

            var approvedSpeakerSegments: [SpeakerIsolatedSegment] = []
            var filteredNonOwnerCount = 0
            var uncertainDistances: [Float] = []

            for isolatedSpeakerSegment in eligibleSpeakerSegments {
                let distance = ownerProfile.bestMatchDistance(for: isolatedSpeakerSegment.embedding)

                switch config.classification(for: distance) {
                case .owner:
                    approvedSpeakerSegments.append(isolatedSpeakerSegment)
                case .nonOwner:
                    filteredNonOwnerCount += 1
                case .uncertain:
                    uncertainDistances.append(distance)
                }
            }

            if !approvedSpeakerSegments.isEmpty {
                let uploadSegment = try mergedSegmentForUpload(
                    approvedSpeakerSegments,
                    sampleRate: segment.sampleRate,
                    capturedAt: segment.capturedAt
                )

                var logParts = [
                    "Accepted \(approvedSpeakerSegments.count) current-user speaker clip\(approvedSpeakerSegments.count == 1 ? "" : "s")"
                ]
                if filteredNonOwnerCount > 0 {
                    logParts.append(
                        "filtered \(filteredNonOwnerCount) non-owner clip\(filteredNonOwnerCount == 1 ? "" : "s")"
                    )
                }
                if !uncertainDistances.isEmpty {
                    logParts.append(
                        "ignored \(uncertainDistances.count) uncertain clip\(uncertainDistances.count == 1 ? "" : "s")"
                    )
                }

                return SpeakerIdentityOutcome(
                    segmentApprovedForUpload: uploadSegment,
                    status: makeStatus(
                        phase: .ownerVerified,
                        description: "Only your voice is being sent to the backend."
                    ),
                    logMessage: logParts.joined(separator: ", ") + "."
                )
            }

            if !uncertainDistances.isEmpty {
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
                    "Speaker match was uncertain for \(uncertainDistances.count) diarized speaker clip\(uncertainDistances.count == 1 ? "" : "s"). Challenge required before more audio can be sent.",
                    phase: .awaitingChallengeResponse,
                    description: "tincan is not sure the current speaker is you. Say the challenge phrase to continue."
                )
            }

            return blockedOutcome(
                "Filtered speech from \(filteredNonOwnerCount) non-owner diarized speaker clip\(filteredNonOwnerCount == 1 ? "" : "s")."
            )
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

        let isolatedSpeakerSegments = try isolateSpeakerSegments(from: segment)
        let eligibleSpeakerSegments = isolatedSpeakerSegments.filter {
            $0.duration >= config.minimumClassificationDuration
        }

        guard !eligibleSpeakerSegments.isEmpty else {
            return blockedOutcome(
                "Challenge response did not contain a long enough diarized speaker clip. Say the challenge phrase again.",
                phase: .awaitingChallengeResponse,
                description: "Challenge response was too short. Say the challenge phrase again."
            )
        }

        let transcripts = try await transcribeChallengeSegments(eligibleSpeakerSegments)
        lastChallengeTranscript = SpeakerIdentityHelpers.challengeTranscriptSummary(for: transcripts)

        let matchingSpeakerIDs = SpeakerIdentityHelpers.matchingSpeakerIDs(in: transcripts, expected: challenge)
        guard matchingSpeakerIDs.count == 1,
              let matchedSpeakerID = matchingSpeakerIDs.first,
              let matchedSegment = eligibleSpeakerSegments.first(where: { $0.speakerId == matchedSpeakerID }) else {
            activeChallenge = phraseProvider.nextPhrase()
            return blockedOutcome(
                challengeFailureLogMessage(
                    matchingSpeakerIDs: matchingSpeakerIDs,
                    transcripts: transcripts
                ),
                phase: .awaitingChallengeResponse,
                description: challengeFailureDescription(
                    matchingSpeakerIDs: matchingSpeakerIDs,
                    transcripts: transcripts
                )
            )
        }

        if let existingProfile = try await loadProfileIfNeeded() {
            let distance = existingProfile.bestMatchDistance(for: matchedSegment.embedding)
            guard distance <= config.challengeAcceptanceDistance else {
                activeChallenge = phraseProvider.nextPhrase()
                return blockedOutcome(
                    "Challenge phrase matched but the voice did not match the current-user profile (distance \(distance.formatted(.number.precision(.fractionLength(2))))).",
                    phase: .awaitingChallengeResponse,
                    description: "The phrase matched, but the voice did not match the current-user profile. Say the new challenge phrase to continue."
                )
            }

            let refreshedProfile = existingProfile.refreshed(
                with: matchedSegment.embedding,
                capturedAt: segment.capturedAt,
                sampleDuration: matchedSegment.duration,
                inputDeviceName: currentInputDeviceName(),
                config: config
            )
            try await store.saveProfile(refreshedProfile)
            ownerProfile = refreshedProfile
        } else {
            let newProfile = OwnerVoiceProfile.bootstrap(
                embedding: matchedSegment.embedding,
                sampleDuration: matchedSegment.duration,
                inputDeviceName: currentInputDeviceName(),
                capturedAt: segment.capturedAt,
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
            logMessage: "Current speaker verified successfully from diarized speaker clip \(matchedSpeakerID). Repeat the request to continue."
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

    private func currentInputDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    private func extractEmbedding(from samples: [Float]) throws -> [Float] {
        guard let diarizerManager else {
            throw NSError(domain: "SpeakerIdentityManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speaker models are not ready."
            ])
        }

        let validation = diarizerManager.validateAudio(samples)
        guard validation.isValid else {
            throw NSError(domain: "SpeakerIdentityManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: validation.issues.joined(separator: ". ")
            ])
        }

        return try diarizerManager.extractSpeakerEmbedding(from: samples)
    }

    private func isolateSpeakerSegments(from segment: CapturedSpeechSegment) throws -> [SpeakerIsolatedSegment] {
        guard let diarizerManager else {
            throw NSError(domain: "SpeakerIdentityManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Speaker models are not ready."
            ])
        }

        let validation = diarizerManager.validateAudio(segment.samples)
        guard validation.isValid else {
            throw NSError(domain: "SpeakerIdentityManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: validation.issues.joined(separator: ". ")
            ])
        }

        if let diarizationResult = try? diarizerManager.performCompleteDiarization(
            segment.samples,
            sampleRate: segment.sampleRate
        ) {
            let groupedSegments = SpeakerIdentityHelpers.groupSpeakerSegments(
                diarizationResult.segments,
                sampleRate: segment.sampleRate,
                sampleCount: segment.samples.count
            )
            let isolatedSegments = try groupedSegments.compactMap { groupedSegment in
                try isolatedSegment(
                    from: groupedSegment,
                    sourceSamples: segment.samples,
                    sampleRate: segment.sampleRate
                )
            }

            if !isolatedSegments.isEmpty {
                return isolatedSegments
            }
        }

        return [
            SpeakerIsolatedSegment(
                speakerId: "speaker-0",
                samples: segment.samples,
                wavData: segment.wavData,
                sampleRate: segment.sampleRate,
                duration: segment.duration,
                embedding: try extractEmbedding(from: segment.samples)
            )
        ]
    }

    private func isolatedSegment(
        from groupedSegment: SpeakerSegmentGroup,
        sourceSamples: [Float],
        sampleRate: Int
    ) throws -> SpeakerIsolatedSegment? {
        var isolatedSamples: [Float] = []
        let silenceSamples = max(0, Int((interSegmentSilenceDuration * Double(sampleRate)).rounded()))

        for (index, span) in groupedSegment.spans.enumerated() {
            guard span.startSample >= 0,
                  span.endSample <= sourceSamples.count,
                  span.endSample > span.startSample else {
                continue
            }

            if index > 0 && silenceSamples > 0 {
                isolatedSamples.append(contentsOf: Array(repeating: 0, count: silenceSamples))
            }
            isolatedSamples.append(contentsOf: sourceSamples[span.startSample..<span.endSample])
        }

        guard !isolatedSamples.isEmpty else {
            return nil
        }

        let duration = Double(isolatedSamples.count) / Double(sampleRate)
        return SpeakerIsolatedSegment(
            speakerId: groupedSegment.speakerId,
            samples: isolatedSamples,
            wavData: try AudioWAV.data(from: isolatedSamples, sampleRate: Double(sampleRate)),
            sampleRate: sampleRate,
            duration: duration,
            embedding: groupedSegment.mergedEmbedding
        )
    }

    private func mergedSegmentForUpload(
        _ speakerSegments: [SpeakerIsolatedSegment],
        sampleRate: Int,
        capturedAt: Date
    ) throws -> CapturedSpeechSegment {
        var mergedSamples: [Float] = []
        let silenceSamples = max(0, Int((interSegmentSilenceDuration * Double(sampleRate)).rounded()))

        for (index, speakerSegment) in speakerSegments.enumerated() {
            if index > 0 && silenceSamples > 0 {
                mergedSamples.append(contentsOf: Array(repeating: 0, count: silenceSamples))
            }
            mergedSamples.append(contentsOf: speakerSegment.samples)
        }

        let duration = Double(mergedSamples.count) / Double(sampleRate)
        return CapturedSpeechSegment(
            samples: mergedSamples,
            wavData: try AudioWAV.data(from: mergedSamples, sampleRate: Double(sampleRate)),
            sampleRate: sampleRate,
            duration: duration,
            capturedAt: capturedAt
        )
    }

    private func transcribeChallengeSegments(
        _ speakerSegments: [SpeakerIsolatedSegment]
    ) async throws -> [SpeakerTranscript] {
        var transcripts: [SpeakerTranscript] = []

        for speakerSegment in speakerSegments {
            do {
                let transcript = try await speechRecognizer.transcribe(audioWAV: speakerSegment.wavData)
                transcripts.append(
                    SpeakerTranscript(
                        speakerId: speakerSegment.speakerId,
                        transcript: transcript
                    )
                )
            } catch let error as LocalSpeechRecognizerError {
                switch error {
                case .recognizerUnavailable, .notAuthorized:
                    throw error
                case .audioTooShort, .noTranscript:
                    continue
                }
            }
        }

        return transcripts
    }

    private func challengeFailureLogMessage(
        matchingSpeakerIDs: [String],
        transcripts: [SpeakerTranscript]
    ) -> String {
        let transcriptSummary = SpeakerIdentityHelpers.challengeTranscriptSummary(for: transcripts)

        if matchingSpeakerIDs.isEmpty {
            if let transcriptSummary {
                return "Challenge transcript did not match any diarized speaker clip. tincan heard “\(transcriptSummary)”."
            }
            return "Challenge response could not be matched to any diarized speaker transcript."
        }

        return "Challenge phrase matched multiple diarized speaker clips (\(matchingSpeakerIDs.joined(separator: ", ")))."
    }

    private func challengeFailureDescription(
        matchingSpeakerIDs: [String],
        transcripts: [SpeakerTranscript]
    ) -> String {
        if matchingSpeakerIDs.isEmpty {
            return transcripts.isEmpty
                ? "tincan could not isolate a speaker saying the challenge phrase. Say the new challenge phrase to continue."
                : "The spoken challenge phrase did not match. Say the new challenge phrase to continue."
        }

        return "Multiple diarized speakers matched the challenge phrase. Say the new challenge phrase to continue."
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
