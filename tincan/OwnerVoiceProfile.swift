import Foundation

nonisolated struct OwnerVoiceProfile: Codable, Sendable, Equatable {
    let id: UUID
    var displayName: String
    var canonicalEmbedding: [Float]
    var acceptedEmbeddings: [[Float]]
    let createdAt: Date
    var updatedAt: Date
    var successfulIdentifications: Int
    var modelIdentifier: String

    init(
        id: UUID = UUID(),
        displayName: String = "Current User",
        canonicalEmbedding: [Float],
        acceptedEmbeddings: [[Float]] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        successfulIdentifications: Int = 1,
        modelIdentifier: String = "FluidAudio.Diarizer"
    ) {
        let normalizedEmbedding = canonicalEmbedding.l2Normalized()
        self.id = id
        self.displayName = displayName
        self.canonicalEmbedding = normalizedEmbedding
        self.acceptedEmbeddings = (acceptedEmbeddings.isEmpty ? [normalizedEmbedding] : acceptedEmbeddings)
            .map { $0.l2Normalized() }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.successfulIdentifications = successfulIdentifications
        self.modelIdentifier = modelIdentifier
    }

    static func bootstrap(
        embedding: [Float],
        displayName: String = "Current User",
        modelIdentifier: String = "FluidAudio.Diarizer"
    ) -> OwnerVoiceProfile {
        OwnerVoiceProfile(
            displayName: displayName,
            canonicalEmbedding: embedding,
            acceptedEmbeddings: [embedding.l2Normalized()],
            successfulIdentifications: 1,
            modelIdentifier: modelIdentifier
        )
    }

    func refreshed(
        with embedding: [Float],
        config: SpeakerIdentityConfig,
        maxStoredEmbeddings: Int = 8
    ) -> OwnerVoiceProfile {
        let normalizedEmbedding = embedding.l2Normalized()
        var updatedEmbeddings = acceptedEmbeddings
        updatedEmbeddings.append(normalizedEmbedding)
        if updatedEmbeddings.count > maxStoredEmbeddings {
            updatedEmbeddings.removeFirst(updatedEmbeddings.count - maxStoredEmbeddings)
        }

        return OwnerVoiceProfile(
            id: id,
            displayName: displayName,
            canonicalEmbedding: canonicalEmbedding.blended(
                with: normalizedEmbedding,
                alpha: config.profileSmoothingAlpha
            ),
            acceptedEmbeddings: updatedEmbeddings,
            createdAt: createdAt,
            updatedAt: Date(),
            successfulIdentifications: successfulIdentifications + 1,
            modelIdentifier: modelIdentifier
        )
    }
}

extension Array where Element == Float {
    nonisolated func l2Normalized() -> [Float] {
        guard !isEmpty else { return self }
        let sumSquares = reduce(0) { $0 + ($1 * $1) }
        guard sumSquares > 0 else { return self }
        let norm = sumSquares.squareRoot()
        return map { $0 / norm }
    }

    nonisolated func cosineSimilarity(to other: [Float]) -> Float {
        guard count == other.count, !isEmpty else { return 0 }
        let lhs = l2Normalized()
        let rhs = other.l2Normalized()
        return zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
    }

    nonisolated func cosineDistance(to other: [Float]) -> Float {
        let similarity = Swift.max(-1, Swift.min(1, cosineSimilarity(to: other)))
        return 1 - similarity
    }

    nonisolated func blended(with other: [Float], alpha: Float) -> [Float] {
        guard count == other.count else { return l2Normalized() }
        let clampedAlpha = Swift.max(0, Swift.min(1, alpha))
        return zip(self, other)
            .map { (clampedAlpha * $0.0) + ((1 - clampedAlpha) * $0.1) }
            .l2Normalized()
    }
}
