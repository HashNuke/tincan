import Foundation

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
}
