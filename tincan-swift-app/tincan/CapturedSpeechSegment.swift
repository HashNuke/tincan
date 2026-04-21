import Foundation

struct CapturedSpeechSegment: Sendable, Identifiable {
    let id: UUID
    let samples: [Float]
    let wavData: Data
    let sampleRate: Int
    let duration: TimeInterval
    let capturedAt: Date

    init(
        id: UUID = UUID(),
        samples: [Float],
        wavData: Data,
        sampleRate: Int,
        duration: TimeInterval,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.samples = samples
        self.wavData = wavData
        self.sampleRate = sampleRate
        self.duration = duration
        self.capturedAt = capturedAt
    }
}
