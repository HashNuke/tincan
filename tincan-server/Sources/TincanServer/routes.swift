import Foundation
import Vapor

func routes(_ app: Application) throws {
    app.get { _ async in
        "tincan-server"
    }

    app.get("health") { req async throws -> HealthResponse in
        async let inferenceHealth = req.application.tincanInferenceService.health()
        async let ttsHealth = req.application.tincanSpeechService.health()
        return await HealthResponse(
            status: "ok",
            modelCacheDirectory: inferenceHealth.modelCacheDirectory,
            isModelReady: inferenceHealth.isModelReady,
            tts: ttsHealth
        )
    }

    app.on(.POST, "infer", body: .collect(maxSize: "25mb")) { req async throws -> InferResponse in
        guard let body = req.body.data, body.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Expected a WAV request body")
        }

        let requestID = UUID()
        let audioData = Data(body.readableBytesView)
        req.logger.info("Received /infer request \(requestID) with \(audioData.count) bytes")
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
            Task {
                await req.application.opencodeRunner.run(transcript: transcript, logger: req.logger)
            }
            return InferResponse(requestID: requestID, transcript: transcript)
        } catch {
            req.logger.error("Inference failed: \(String(describing: error))")
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }

    app.post("speak") { req async throws -> Response in
        let request = try req.content.decode(SpeakRequest.self)
        let audioData = try await req.application.tincanSpeechService.synthesize(text: request.text)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "audio/wav")
        return Response(
            status: .ok,
            headers: headers,
            body: .init(data: audioData)
        )
    }

    try app.register(collection: ConversationController())
}

struct HealthResponse: Content {
    let status: String
    let modelCacheDirectory: String
    let isModelReady: Bool
    let tts: TtsHealthResponse
}

struct TtsHealthResponse: Content {
    let defaultVoice: String
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

struct SpeakRequest: Content {
    let text: String
}
