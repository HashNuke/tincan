import FluidAudio
import Foundation
import MLXAudioTTS

enum InferenceAction: String, Codable {
    case stt
    case tts
}

enum InferenceMessageKind: String, Codable {
    case request
    case result
    case error
}

struct InferenceEnvelope: Codable {
    let kind: InferenceMessageKind
    let requestID: String
    let action: InferenceAction
    let model: String
    let contentType: String
    let bodyLength: Int
    let sampleRate: Int?
    let channels: Int?
    let voice: String?
    let textFormat: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id"
        case action
        case model
        case contentType = "content_type"
        case bodyLength = "body_length"
        case sampleRate = "sample_rate"
        case channels
        case voice
        case textFormat = "text_format"
        case message
    }
}

enum InferenceServerError: Error, CustomStringConvertible {
    case socketPathTooLong
    case failedToCreateSocket(errno: Int32)
    case failedToBind(errno: Int32)
    case failedToListen(errno: Int32)
    case failedToAccept(errno: Int32)
    case invalidHeaderLength(Int)
    case invalidRequest(String)

    var description: String {
        switch self {
        case .socketPathTooLong:
            return "Unix socket path exceeds sockaddr_un capacity"
        case .failedToCreateSocket(let errno):
            return "socket() failed with errno \(errno)"
        case .failedToBind(let errno):
            return "bind() failed with errno \(errno)"
        case .failedToListen(let errno):
            return "listen() failed with errno \(errno)"
        case .failedToAccept(let errno):
            return "accept() failed with errno \(errno)"
        case .invalidHeaderLength(let length):
            return "Invalid header length: \(length)"
        case .invalidRequest(let reason):
            return reason
        }
    }
}

final class InferenceSocketServer: @unchecked Sendable {
    private let config: InferenceRuntimeConfiguration
    private let socketURL: URL
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private let sttService: ParakeetSTTService
    private let ttsService: KittenTTSService

    init(config: InferenceRuntimeConfiguration) throws {
        try config.validateFileSystem()
        let sttModelDirectoryURL = try config.prepareSTTModelLoadDirectory()

        self.config = config
        self.socketURL = config.socketURL
        self.sttService = ParakeetSTTService(
            modelDirectoryURL: sttModelDirectoryURL,
            modelVersion: try config.sttModelVersion
        )
        self.ttsService = KittenTTSService(
            modelDirectoryURL: config.ttsModelDirectoryURL,
            g2pResourceDirectoryURL: config.kittenTTSG2PDirectoryURL
        )
    }

    func run() throws {
        try AppRuntimePaths.prepareSocketDirectory(for: socketURL)
        try removeExistingSocketIfPresent()

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw InferenceServerError.failedToCreateSocket(errno: errno)
        }
        defer { close(serverFD) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let socketPath = socketURL.path
        let utf8Bytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard utf8Bytes.count < maxPathLength else {
            throw InferenceServerError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
            sunPathPointer.withMemoryRebound(to: UInt8.self, capacity: maxPathLength) { pathBytes in
                pathBytes.initialize(repeating: 0, count: maxPathLength)
                pathBytes.update(from: utf8Bytes, count: utf8Bytes.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + utf8Bytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            throw InferenceServerError.failedToBind(errno: errno)
        }

        guard listen(serverFD, SOMAXCONN) == 0 else {
            throw InferenceServerError.failedToListen(errno: errno)
        }

        print(
            "tincan-inference-macos listening on unix://\(socketURL.path) " +
            "stt=\(config.sttModelDirectoryName) tts=\(config.ttsModelDirectoryName)"
        )

        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                throw InferenceServerError.failedToAccept(errno: errno)
            }

            let clientHandle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
            let server = self
            Task.detached {
                do {
                    try await server.handleConnection(clientHandle)
                } catch {
                    fputs("connection error: \(error)\n", stderr)
                    try? clientHandle.close()
                }
            }
        }
    }

    private func handleConnection(_ handle: FileHandle) async throws {
        defer { try? handle.close() }

        while true {
            guard let request = try readMessage(from: handle) else {
                return
            }

            let response = try await dispatch(request: request)
            try writeMessage(response, to: handle)
        }
    }

    private func dispatch(request: FramedMessage) async throws -> FramedMessage {
        guard request.header.kind == .request else {
            throw InferenceServerError.invalidRequest("Expected request message kind")
        }

        switch request.header.action {
        case .stt:
            return try await handleSTT(request: request)
        case .tts:
            return try await handleTTS(request: request)
        }
    }

    private func handleSTT(request: FramedMessage) async throws -> FramedMessage {
        guard request.header.contentType.hasPrefix("audio/") else {
            return errorResponse(for: request, message: "STT request must use an audio/* content type")
        }

        print(
            "stt request id=\(request.header.requestID) bytes=\(request.body.count) " +
            "requestedModel=\(request.header.model) configuredModel=\(config.sttModelDirectoryName) " +
            "contentType=\(request.header.contentType)"
        )

        let transcriptText = try await sttService.transcribe(
            audioData: request.body,
            fileExtension: fileExtension(for: request.header.contentType)
        )
        print(
            "stt result id=\(request.header.requestID) model=\(config.sttModelDirectoryName) " +
            "length=\(transcriptText.count) text=\(String(reflecting: transcriptText))"
        )

        let body = try jsonEncoder.encode(["text": transcriptText])
        let header = InferenceEnvelope(
            kind: .result,
            requestID: request.header.requestID,
            action: .stt,
            model: config.sttModelDirectoryName,
            contentType: "application/json",
            bodyLength: body.count,
            sampleRate: nil,
            channels: nil,
            voice: nil,
            textFormat: "plain",
            message: nil
        )
        return FramedMessage(header: header, body: body)
    }

    private func fileExtension(for contentType: String) -> String {
        switch contentType {
        case "audio/wav", "audio/x-wav", "audio/wave":
            return "wav"
        case "audio/webm":
            return "webm"
        case "audio/mp4", "audio/m4a":
            return "m4a"
        default:
            return "bin"
        }
    }

    private func handleTTS(request: FramedMessage) async throws -> FramedMessage {
        guard request.header.contentType == "text/plain" || request.header.contentType == "application/json" else {
            return errorResponse(for: request, message: "TTS request must use text/plain or application/json")
        }

        let text: String
        let voice: String?

        if request.header.contentType == "text/plain" {
            text = String(decoding: request.body, as: UTF8.self)
            voice = request.header.voice
        } else {
            let payload = try jsonDecoder.decode(TTSRequestPayload.self, from: request.body)
            text = payload.text
            voice = payload.voice ?? request.header.voice
        }

        let synthesizedAudio = try await ttsService.synthesize(text: text, voice: voice)
        let header = InferenceEnvelope(
            kind: .result,
            requestID: request.header.requestID,
            action: .tts,
            model: config.ttsModelDirectoryName,
            contentType: "audio/wav",
            bodyLength: synthesizedAudio.audioData.count,
            sampleRate: synthesizedAudio.sampleRate,
            channels: 1,
            voice: synthesizedAudio.voice,
            textFormat: nil,
            message: nil
        )
        return FramedMessage(header: header, body: synthesizedAudio.audioData)
    }

    private func errorResponse(for request: FramedMessage, message: String) -> FramedMessage {
        let header = InferenceEnvelope(
            kind: .error,
            requestID: request.header.requestID,
            action: request.header.action,
            model: request.header.model,
            contentType: "text/plain",
            bodyLength: 0,
            sampleRate: nil,
            channels: nil,
            voice: nil,
            textFormat: nil,
            message: message
        )
        return FramedMessage(header: header, body: Data())
    }

    private func readMessage(from handle: FileHandle) throws -> FramedMessage? {
        guard let lengthData = try handle.readExactly(byteCount: 4) else {
            return nil
        }

        let headerLength = lengthData.withUnsafeBytes { buffer in
            buffer.load(as: UInt32.self).bigEndian
        }

        guard headerLength > 0, headerLength < 1_048_576 else {
            throw InferenceServerError.invalidHeaderLength(Int(headerLength))
        }

        guard let headerData = try handle.readExactly(byteCount: Int(headerLength)) else {
            throw InferenceServerError.invalidRequest("Unexpected EOF while reading header")
        }

        let header = try jsonDecoder.decode(InferenceEnvelope.self, from: headerData)
        let body = try handle.readExactly(byteCount: header.bodyLength) ?? Data()
        return FramedMessage(header: header, body: body)
    }

    private func writeMessage(_ message: FramedMessage, to handle: FileHandle) throws {
        let headerData = try jsonEncoder.encode(message.header)
        var headerLength = UInt32(headerData.count).bigEndian
        let lengthData = Data(bytes: &headerLength, count: MemoryLayout<UInt32>.size)

        try handle.write(contentsOf: lengthData)
        try handle.write(contentsOf: headerData)
        if message.body.isEmpty == false {
            try handle.write(contentsOf: message.body)
        }
    }

    private func removeExistingSocketIfPresent() throws {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            try FileManager.default.removeItem(at: socketURL)
        }
    }
}

struct FramedMessage {
    let header: InferenceEnvelope
    let body: Data
}

private struct TTSRequestPayload: Codable {
    let text: String
    let voice: String?
}

struct SynthesizedAudio {
    let audioData: Data
    let sampleRate: Int
    let voice: String
}

actor ParakeetSTTService {
    private enum State {
        case idle
        case loading(Task<AsrManager, any Error>)
        case ready(AsrManager)
    }

    private let modelDirectoryURL: URL
    private let modelVersion: AsrModelVersion
    private var state: State = .idle

    init(modelDirectoryURL: URL, modelVersion: AsrModelVersion) {
        self.modelDirectoryURL = modelDirectoryURL
        self.modelVersion = modelVersion
    }

    func transcribe(audioData: Data, fileExtension: String) async throws -> String {
        guard audioData.isEmpty == false else {
            throw InferenceServerError.invalidRequest("STT request requires non-empty audio")
        }

        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        try audioData.write(to: temporaryFileURL)
        print("stt temp file path=\(temporaryFileURL.path) bytes=\(audioData.count)")

        let manager = try await asrManager()
        let result = try await manager.transcribe(temporaryFileURL)
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            print("stt empty transcript, preserving temp file at \(temporaryFileURL.path)")
        } else {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }

        return trimmed
    }

    private func asrManager() async throws -> AsrManager {
        switch state {
        case .ready(let manager):
            return manager
        case .loading(let task):
            let manager = try await task.value
            state = .ready(manager)
            return manager
        case .idle:
            let modelDirectoryURL = self.modelDirectoryURL
            let modelVersion = self.modelVersion

            let task = Task { () throws -> AsrManager in
                print("loading Parakeet models from \(modelDirectoryURL.path)")
                let models = try await AsrModels.load(from: modelDirectoryURL, version: modelVersion)
                let manager = AsrManager()
                try await manager.loadModels(models)
                print("Parakeet models ready")
                return manager
            }

            state = .loading(task)

            do {
                let manager = try await task.value
                state = .ready(manager)
                return manager
            } catch {
                state = .idle
                throw error
            }
        }
    }
}

actor KittenTTSService {
    static let defaultVoice = "Bella"

    private enum State {
        case idle
        case loading(Task<KittenTTSModel, any Error>)
        case ready(KittenTTSModel)
    }

    private let modelDirectoryURL: URL
    private let g2pResourceDirectoryURL: URL?
    private var state: State = .idle

    init(modelDirectoryURL: URL, g2pResourceDirectoryURL: URL? = nil) {
        self.modelDirectoryURL = modelDirectoryURL
        self.g2pResourceDirectoryURL = g2pResourceDirectoryURL?.standardizedFileURL
    }

    func synthesize(text: String, voice: String?) async throws -> SynthesizedAudio {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            throw InferenceServerError.invalidRequest("TTS request requires non-empty text")
        }

        let selectedVoice = normalizedVoice(from: voice) ?? Self.defaultVoice
        let model = try await kittenTTSModel()
        let generatedAudio = try await model.generate(
            text: trimmedText,
            voice: selectedVoice,
            refAudio: nil,
            refText: nil,
            language: nil
        )
        let samples = generatedAudio.asArray(Float.self)

        guard samples.isEmpty == false else {
            throw InferenceServerError.invalidRequest("KittenTTS produced no audio")
        }

        return SynthesizedAudio(
            audioData: try AudioWAV.data(from: samples, sampleRate: Double(model.sampleRate)),
            sampleRate: model.sampleRate,
            voice: selectedVoice
        )
    }

    private func kittenTTSModel() async throws -> KittenTTSModel {
        switch state {
        case .ready(let model):
            return model
        case .loading(let task):
            let model = try await task.value
            state = .ready(model)
            return model
        case .idle:
            let modelDirectoryURL = self.modelDirectoryURL
            let g2pResourceDirectoryURL = self.g2pResourceDirectoryURL

            let task = Task { () throws -> KittenTTSModel in
                print("loading KittenTTS model from \(modelDirectoryURL.path)")
                let textProcessor = g2pResourceDirectoryURL.map(MisakiTextProcessor.init(resourceDirectory:))
                let model = try await KittenTTSModel.fromModelDirectory(
                    modelDirectoryURL,
                    textProcessor: textProcessor
                )
                print("KittenTTS model ready")
                return model
            }

            state = .loading(task)

            do {
                let model = try await task.value
                state = .ready(model)
                return model
            } catch {
                state = .idle
                throw error
            }
        }
    }

    private func normalizedVoice(from voice: String?) -> String? {
        guard let voice else {
            return nil
        }

        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVoice.isEmpty ? nil : trimmedVoice
    }
}

enum AppRuntimePaths {
    static let inferenceSocketFilename = "tincan-inference-macos.sock"

    static let runDirectoryURL: URL = {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("tincan", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
    }()

    static let inferenceSocketURL = runDirectoryURL.appendingPathComponent(inferenceSocketFilename, isDirectory: false)

    static func prepareSocketDirectory(for socketURL: URL) throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}

extension FileHandle {
    func readExactly(byteCount: Int) throws -> Data? {
        if byteCount == 0 {
            return Data()
        }

        var collected = Data()
        while collected.count < byteCount {
            let nextChunk = try read(upToCount: byteCount - collected.count) ?? Data()
            if nextChunk.isEmpty {
                return collected.isEmpty ? nil : collected
            }
            collected.append(nextChunk)
        }
        return collected
    }
}
