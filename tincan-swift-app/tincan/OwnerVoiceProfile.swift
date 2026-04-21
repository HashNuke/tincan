import Foundation

nonisolated struct SpeakerProfileSample: Codable, Sendable, Equatable {
    var embedding: [Float]
    var capturedAt: Date
    var sampleDuration: TimeInterval
    var inputDeviceName: String?

    init(
        embedding: [Float],
        capturedAt: Date = Date(),
        sampleDuration: TimeInterval,
        inputDeviceName: String? = nil
    ) {
        self.embedding = embedding.l2Normalized()
        self.capturedAt = capturedAt
        self.sampleDuration = sampleDuration
        self.inputDeviceName = inputDeviceName
    }
}

nonisolated struct OwnerVoiceProfile: Codable, Sendable, Equatable {
    let id: UUID
    var displayName: String
    var canonicalEmbedding: [Float]
    var speakerProfiles: [SpeakerProfileSample]
    let createdAt: Date
    var updatedAt: Date
    var successfulIdentifications: Int
    var modelIdentifier: String

    init(
        id: UUID = UUID(),
        displayName: String = "Current User",
        canonicalEmbedding: [Float],
        speakerProfiles: [SpeakerProfileSample] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        successfulIdentifications: Int = 1,
        modelIdentifier: String = "FluidAudio.Diarizer"
    ) {
        let normalizedEmbedding = canonicalEmbedding.l2Normalized()
        self.id = id
        self.displayName = displayName
        self.canonicalEmbedding = normalizedEmbedding
        self.speakerProfiles = speakerProfiles.isEmpty
            ? [SpeakerProfileSample(embedding: normalizedEmbedding, sampleDuration: 0)]
            : speakerProfiles.map {
                SpeakerProfileSample(
                    embedding: $0.embedding,
                    capturedAt: $0.capturedAt,
                    sampleDuration: $0.sampleDuration,
                    inputDeviceName: $0.inputDeviceName
                )
            }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.successfulIdentifications = successfulIdentifications
        self.modelIdentifier = modelIdentifier
    }

    static func bootstrap(
        embedding: [Float],
        sampleDuration: TimeInterval,
        inputDeviceName: String? = nil,
        capturedAt: Date = Date(),
        displayName: String = "Current User",
        modelIdentifier: String = "FluidAudio.Diarizer"
    ) -> OwnerVoiceProfile {
        OwnerVoiceProfile(
            displayName: displayName,
            canonicalEmbedding: embedding,
            speakerProfiles: [
                SpeakerProfileSample(
                    embedding: embedding,
                    capturedAt: capturedAt,
                    sampleDuration: sampleDuration,
                    inputDeviceName: inputDeviceName
                )
            ],
            successfulIdentifications: 1,
            modelIdentifier: modelIdentifier
        )
    }

    func refreshed(
        with embedding: [Float],
        capturedAt: Date,
        sampleDuration: TimeInterval,
        inputDeviceName: String?,
        config: SpeakerIdentityConfig,
        maxStoredProfiles: Int = 12
    ) -> OwnerVoiceProfile {
        let normalizedEmbedding = embedding.l2Normalized()
        var updatedProfiles = speakerProfiles
        updatedProfiles.append(
            SpeakerProfileSample(
                embedding: normalizedEmbedding,
                capturedAt: capturedAt,
                sampleDuration: sampleDuration,
                inputDeviceName: inputDeviceName
            )
        )
        if updatedProfiles.count > maxStoredProfiles {
            updatedProfiles.removeFirst(updatedProfiles.count - maxStoredProfiles)
        }

        return OwnerVoiceProfile(
            id: id,
            displayName: displayName,
            canonicalEmbedding: canonicalEmbedding.blended(
                with: normalizedEmbedding,
                alpha: config.profileSmoothingAlpha
            ),
            speakerProfiles: updatedProfiles,
            createdAt: createdAt,
            updatedAt: Date(),
            successfulIdentifications: successfulIdentifications + 1,
            modelIdentifier: modelIdentifier
        )
    }

    func bestMatchDistance(for embedding: [Float]) -> Float {
        let normalizedEmbedding = embedding.l2Normalized()
        let canonicalDistance = normalizedEmbedding.cosineDistance(to: canonicalEmbedding)
        let profileDistance = speakerProfiles
            .map { normalizedEmbedding.cosineDistance(to: $0.embedding) }
            .min()
        return min(canonicalDistance, profileDistance ?? canonicalDistance)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case canonicalEmbedding
        case speakerProfiles
        case createdAt
        case updatedAt
        case successfulIdentifications
        case modelIdentifier
        case acceptedEmbeddings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let canonicalEmbedding = try container.decode([Float].self, forKey: .canonicalEmbedding)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let successfulIdentifications = try container.decode(Int.self, forKey: .successfulIdentifications)
        let modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)

        let speakerProfiles: [SpeakerProfileSample]
        if let decodedProfiles = try container.decodeIfPresent([SpeakerProfileSample].self, forKey: .speakerProfiles) {
            speakerProfiles = decodedProfiles
        } else if let acceptedEmbeddings = try container.decodeIfPresent([[Float]].self, forKey: .acceptedEmbeddings) {
            speakerProfiles = acceptedEmbeddings.map { SpeakerProfileSample(embedding: $0, sampleDuration: 0) }
        } else {
            speakerProfiles = []
        }

        self.init(
            id: id,
            displayName: displayName,
            canonicalEmbedding: canonicalEmbedding,
            speakerProfiles: speakerProfiles,
            createdAt: createdAt,
            updatedAt: updatedAt,
            successfulIdentifications: successfulIdentifications,
            modelIdentifier: modelIdentifier
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(canonicalEmbedding, forKey: .canonicalEmbedding)
        try container.encode(speakerProfiles, forKey: .speakerProfiles)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(successfulIdentifications, forKey: .successfulIdentifications)
        try container.encode(modelIdentifier, forKey: .modelIdentifier)
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
