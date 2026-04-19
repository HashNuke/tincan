import Foundation
import Vapor

func routes(_ app: Application) throws {
    app.get { _ async in
        "tincan-server"
    }

    app.get("health") { req async throws -> HealthResponse in
        await req.application.tincanInferenceService.health()
    }

    app.on(.POST, "infer", body: .collect(maxSize: "25mb")) { req async throws -> InferResponse in
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Expected a WAV request body")
        }

        let requestID = UUID()
        let audioData = Data(body.readableBytesView)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(requestID.uuidString)
            .appendingPathExtension("wav")

        try audioData.write(to: temporaryURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            let transcript = try await req.application.tincanInferenceService.transcribe(audioFileURL: temporaryURL)
            req.logger.info("Transcript: \(transcript)")
            return InferResponse(requestID: requestID, transcript: transcript)
        } catch {
            req.logger.error("Inference failed: \(String(describing: error))")
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }
}

struct HealthResponse: Content {
    let status: String
    let modelCacheDirectory: String
    let isModelReady: Bool
}

struct InferResponse: Content {
    let requestID: UUID
    let transcript: String

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case transcript
    }
}
