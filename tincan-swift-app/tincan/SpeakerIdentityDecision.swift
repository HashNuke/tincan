import Foundation

enum TincanTranscriptDisplayState: Sendable, Equatable {
    case heard
    case approvedForUpload
}

struct TincanTranscriptDisplayItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let text: String
    let state: TincanTranscriptDisplayState
    let capturedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        text: String,
        state: TincanTranscriptDisplayState,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.capturedAt = capturedAt
    }
}

nonisolated struct SpeakerTranscript: Identifiable, Sendable, Equatable {
    let id: UUID
    let speakerId: String
    let transcript: String

    nonisolated init(id: UUID = UUID(), speakerId: String, transcript: String) {
        self.id = id
        self.speakerId = speakerId
        self.transcript = transcript
    }
}

enum SpeakerIdentityPhase: String, Sendable {
    case preparing
    case identificationRequired
    case awaitingChallengeResponse
    case ownerVerified
    case unavailable
}

struct SpeakerIdentityStatus: Sendable, Equatable {
    let phase: SpeakerIdentityPhase
    let description: String
    let ownerProfileName: String?
    let challengePrompt: String?
    let lastChallengeTranscript: String?
}

struct SpeakerIdentityOutcome: Sendable {
    let segmentApprovedForUpload: CapturedSpeechSegment?
    let status: SpeakerIdentityStatus
    let logMessage: String
    let recognizedTranscripts: [SpeakerTranscript]
    let approvedSpeakerIDs: [String]

    nonisolated init(
        segmentApprovedForUpload: CapturedSpeechSegment?,
        status: SpeakerIdentityStatus,
        logMessage: String,
        recognizedTranscripts: [SpeakerTranscript] = [],
        approvedSpeakerIDs: [String] = []
    ) {
        self.segmentApprovedForUpload = segmentApprovedForUpload
        self.status = status
        self.logMessage = logMessage
        self.recognizedTranscripts = recognizedTranscripts
        self.approvedSpeakerIDs = approvedSpeakerIDs
    }
}
