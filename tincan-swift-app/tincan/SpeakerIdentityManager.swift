#if os(macOS)
import FluidAudio
import Foundation

nonisolated struct SpeakerSegmentSpan: Sendable, Equatable {
    let speakerId: String
    let startSample: Int
    let endSample: Int
    let duration: TimeInterval
    let embedding: [Float]
}

nonisolated struct SpeakerSegmentGroup: Sendable, Equatable {
    let speakerId: String
    let spans: [SpeakerSegmentSpan]
    let totalDuration: TimeInterval
    let mergedEmbedding: [Float]
}

nonisolated struct SpeakerIsolatedSegment: Sendable {
    let speakerId: String
    let samples: [Float]
    let wavData: Data
    let sampleRate: Int
    let duration: TimeInterval
    let embedding: [Float]
}

nonisolated enum SpeakerIdentityHelpers {
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
            .map(\.transcript)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    static func wakeWordTranscriptSummary(
        in transcripts: [SpeakerTranscript],
        wakeWord: String
    ) -> String? {
        let matchingTranscripts = transcripts
            .filter { containsWakeWord(transcript: $0.transcript, wakeWord: wakeWord) }
            .map(\.transcript)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !matchingTranscripts.isEmpty else { return nil }

        return matchingTranscripts
            .prefix(3)
            .joined(separator: " | ")
    }

    static func wakeWordMatchingSpeakerIDs(
        in transcripts: [SpeakerTranscript],
        wakeWord: String
    ) -> [String] {
        transcripts
            .filter { containsWakeWord(transcript: $0.transcript, wakeWord: wakeWord) }
            .map(\.speakerId)
    }

    static func containsWakeWord(transcript: String, wakeWord: String) -> Bool {
        let transcriptTokens = normalizedTokens(in: transcript)
        let wakeWordTokens = normalizedTokens(in: wakeWord)

        guard !transcriptTokens.isEmpty, !wakeWordTokens.isEmpty else {
            return false
        }
        guard transcriptTokens.count >= wakeWordTokens.count else {
            return false
        }

        for startIndex in 0...(transcriptTokens.count - wakeWordTokens.count) {
            let slice = transcriptTokens[startIndex..<(startIndex + wakeWordTokens.count)]
            if Array(slice) == wakeWordTokens {
                return true
            }
        }

        return false
    }

    private static func normalizedTokens(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
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
    private let speechRecognizer: LocalSpeechRecognizer
    private let config: SpeakerIdentityConfig
    private let interSegmentSilenceDuration: TimeInterval = 0.12
    private let defaultWakeWord = "Atlas"

    private var diarizerManager: DiarizerManager?
    private var wakeWord: String?
    private var lastWakeWordTranscript: String?
    private var speechRecognitionAuthorized = false

    init(
        speechRecognizer: LocalSpeechRecognizer = LocalSpeechRecognizer(),
        config: SpeakerIdentityConfig = .default
    ) {
        self.speechRecognizer = speechRecognizer
        self.config = config
    }

    func prepare() async throws -> SpeakerIdentityStatus {
        if diarizerManager == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizerManager = manager
        }

        _ = resolveWakeWord()

        return makeStatus()
    }

    func currentStatus() async -> SpeakerIdentityStatus {
        return makeStatus()
    }

    func setSpeechRecognitionAuthorized(_ value: Bool) {
        speechRecognitionAuthorized = value
    }

    func processSegment(_ segment: CapturedSpeechSegment) async -> SpeakerIdentityOutcome {
        do {
            _ = try await prepare()
            let resolvedWakeWord = resolveWakeWord()

            guard speechRecognitionAuthorized else {
                return blockedOutcome(
                    "Speech recognition permission is required before tincan can gate audio on the wake word.",
                    phase: .unavailable,
                    description: "Speech recognition permission is required before tincan can gate audio on the wake word."
                )
            }

            guard segment.duration >= config.minimumClassificationDuration else {
                return blockedOutcome(
                    "Ignored a short speech segment (\(segment.duration.formatted(.number.precision(.fractionLength(2))))s) while waiting for the wake word “\(resolvedWakeWord)”."
                )
            }

            let isolatedSpeakerSegments = try isolateSpeakerSegments(from: segment)
            let eligibleSpeakerSegments = isolatedSpeakerSegments.filter {
                $0.duration >= config.minimumClassificationDuration
            }

            guard !eligibleSpeakerSegments.isEmpty else {
                return blockedOutcome(
                    "Ignored only short diarized speaker clips while waiting for the wake word “\(resolvedWakeWord)”."
                )
            }

            let transcripts = try await transcribeSpeakerSegments(eligibleSpeakerSegments)
            let heardTranscriptSummary = SpeakerIdentityHelpers.challengeTranscriptSummary(for: transcripts)
            lastWakeWordTranscript = SpeakerIdentityHelpers.wakeWordTranscriptSummary(
                in: transcripts,
                wakeWord: resolvedWakeWord
            )

            let matchingSpeakerIDs = SpeakerIdentityHelpers.wakeWordMatchingSpeakerIDs(
                in: transcripts,
                wakeWord: resolvedWakeWord
            )

            if matchingSpeakerIDs.count == 1,
               let matchedSpeakerID = matchingSpeakerIDs.first,
               let matchedSegment = eligibleSpeakerSegments.first(where: { $0.speakerId == matchedSpeakerID }) {
                let uploadSegment = try mergedSegmentForUpload(
                    [matchedSegment],
                    sampleRate: segment.sampleRate,
                    capturedAt: segment.capturedAt
                )

                return SpeakerIdentityOutcome(
                    segmentApprovedForUpload: uploadSegment,
                    status: makeStatus(
                        phase: .ownerVerified,
                        description: "Wake word heard. Only audio from the speaker who said “\(resolvedWakeWord)” is being sent."
                    ),
                    logMessage: "Matched wake word “\(resolvedWakeWord)” to one diarized speaker clip and filtered the rest.",
                    recognizedTranscripts: transcripts,
                    approvedSpeakerIDs: [matchedSpeakerID]
                )
            }

            if matchingSpeakerIDs.count > 1 {
                return blockedOutcome(
                    "Multiple diarized speakers said the wake word “\(resolvedWakeWord)”.",
                    phase: .awaitingChallengeResponse,
                    description: "Multiple speakers said “\(resolvedWakeWord)”. Say it again so tincan can isolate one speaker.",
                    recognizedTranscripts: transcripts
                )
            }

            return blockedOutcome(
                transcripts.isEmpty
                    ? "No diarized speaker clip produced a usable transcript for the wake word “\(resolvedWakeWord)”."
                    : "No diarized speaker said the wake word “\(resolvedWakeWord)”. Heard \(heardTranscriptSummary ?? "no transcript").",
                phase: .identificationRequired,
                description: "Say “\(resolvedWakeWord)” and tincan will send only that speaker’s audio.",
                recognizedTranscripts: transcripts
            )
        } catch {
            return blockedOutcome(
                "Wake-word speaker gating failed: \(error.localizedDescription)",
                phase: .unavailable,
                description: "Wake-word speaker gating failed: \(error.localizedDescription)"
            )
        }
    }

    private func resolveWakeWord() -> String {
        if let wakeWord, !wakeWord.isEmpty {
            return wakeWord
        }

        let loadedWakeWord = (try? loadWakeWordFromGeneratedProfiles())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWakeWord = (loadedWakeWord?.isEmpty == false ? loadedWakeWord : nil) ?? defaultWakeWord
        wakeWord = resolvedWakeWord
        return resolvedWakeWord
    }

    private func loadWakeWordFromGeneratedProfiles() throws -> String? {
        guard FileManager.default.fileExists(atPath: AppPaths.generatedAgentProfilesURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: AppPaths.generatedAgentProfilesURL)
        let profiles = try JSONDecoder().decode([String: RouterAgentProfile].self, from: data)
        if let atlasProfile = profiles["atlas"]?.name.trimmingCharacters(in: .whitespacesAndNewlines), !atlasProfile.isEmpty {
            return atlasProfile
        }

        return profiles
            .values
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .sorted()
            .first(where: { !$0.isEmpty })
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

    private func transcribeSpeakerSegments(
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

    private func blockedOutcome(
        _ logMessage: String,
        phase: SpeakerIdentityPhase? = nil,
        description: String? = nil,
        recognizedTranscripts: [SpeakerTranscript] = []
    ) -> SpeakerIdentityOutcome {
        SpeakerIdentityOutcome(
            segmentApprovedForUpload: nil,
            status: makeStatus(phase: phase, description: description),
            logMessage: logMessage,
            recognizedTranscripts: recognizedTranscripts
        )
    }

    private func makeStatus(
        phase requestedPhase: SpeakerIdentityPhase? = nil,
        description requestedDescription: String? = nil
    ) -> SpeakerIdentityStatus {
        let resolvedWakeWord = resolveWakeWord()
        let computedPhase: SpeakerIdentityPhase
        if let requestedPhase {
            computedPhase = requestedPhase
        } else {
            computedPhase = speechRecognitionAuthorized ? .identificationRequired : .unavailable
        }

        let description: String
        if let requestedDescription {
            description = requestedDescription
        } else {
            switch computedPhase {
            case .preparing:
                description = "Preparing wake-word speaker gating."
            case .identificationRequired:
                description = "Say “\(resolvedWakeWord)” and tincan will send only that speaker’s audio."
            case .awaitingChallengeResponse:
                description = "Multiple speakers matched the wake word. Say it again more clearly."
            case .ownerVerified:
                description = "Wake word heard. Only that speaker’s audio is being sent to the backend."
            case .unavailable:
                description = "Wake-word speaker gating is unavailable."
            }
        }

        return SpeakerIdentityStatus(
            phase: computedPhase,
            description: description,
            ownerProfileName: resolvedWakeWord,
            challengePrompt: nil,
            lastChallengeTranscript: lastWakeWordTranscript
        )
    }
}

private struct RouterAgentProfile: Decodable {
    let name: String
}
#endif
