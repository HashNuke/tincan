import Foundation

nonisolated enum SpeakerMatchClassification: Sendable, Equatable {
    case owner
    case nonOwner
    case uncertain
}

nonisolated struct SpeakerIdentityConfig: Sendable {
    var minimumClassificationDuration: TimeInterval = 1.0
    var ownerAcceptanceDistance: Float = 0.45
    var ownerRejectionDistance: Float = 0.65
    var challengeAcceptanceDistance: Float = 0.50
    var profileSmoothingAlpha: Float = 0.85

    static let `default` = SpeakerIdentityConfig()

    func classification(for distance: Float) -> SpeakerMatchClassification {
        if distance <= ownerAcceptanceDistance {
            return .owner
        }
        if distance >= ownerRejectionDistance {
            return .nonOwner
        }
        return .uncertain
    }
}
