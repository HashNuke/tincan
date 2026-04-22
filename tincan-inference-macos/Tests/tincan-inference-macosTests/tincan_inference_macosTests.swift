import Foundation
import Testing
@testable import tincan_inference_macos

@Test func parseConfigurationUsesRequiredSwitchesAndDefaultSocket() throws {
    let configuration = try InferenceRuntimeConfiguration.parse(arguments: [
        "--models-dir", "Models",
        "--stt-model", "parakeet-tdt-0.6b-v3-coreml",
        "--tts-model", "kitten-tts-mini-0.8",
    ])

    let expectedModelsDirectoryURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    .appendingPathComponent("Models", isDirectory: true)
    .standardizedFileURL

    #expect(configuration.modelsDirectoryURL == expectedModelsDirectoryURL)
    #expect(configuration.sttModelDirectoryURL.lastPathComponent == "parakeet-tdt-0.6b-v3-coreml")
    #expect(configuration.ttsModelDirectoryURL.lastPathComponent == "kitten-tts-mini-0.8")
    #expect(configuration.kittenTTSG2PDirectoryURL.lastPathComponent == "kitten-tts-g2p")
    #expect(configuration.socketURL == AppRuntimePaths.inferenceSocketURL)

    switch try configuration.sttModelVersion {
    case .v3:
        break
    default:
        Issue.record("Expected v3 Parakeet STT model inference")
    }
}

@Test func validateFileSystemCreatesSTTAliasForCoreMLRepoName() throws {
    try withTemporaryDirectory { temporaryDirectoryURL in
        let modelsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        let sttDirectoryURL = modelsDirectoryURL.appendingPathComponent(
            "parakeet-tdt-0.6b-v3-coreml",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sttDirectoryURL, withIntermediateDirectories: true)
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Encoder.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Decoder.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("JointDecision.mlmodelc", isDirectory: true))
        try Data("{}".utf8).write(to: sttDirectoryURL.appendingPathComponent("parakeet_vocab.json"))

        let ttsDirectoryURL = modelsDirectoryURL.appendingPathComponent("kitten-tts-mini-0.8", isDirectory: true)
        try FileManager.default.createDirectory(at: ttsDirectoryURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ttsDirectoryURL.appendingPathComponent("config.json"))
        try Data().write(to: ttsDirectoryURL.appendingPathComponent("model.safetensors"))
        try Data().write(to: ttsDirectoryURL.appendingPathComponent("voices.safetensors"))

        let g2pDirectoryURL = modelsDirectoryURL
            .appendingPathComponent(InferenceRuntimeConfiguration.dependenciesDirectoryName, isDirectory: true)
            .appendingPathComponent(InferenceRuntimeConfiguration.kittenTTSG2PDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: g2pDirectoryURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: g2pDirectoryURL.appendingPathComponent("us_gold.json"))
        try Data("{}".utf8).write(to: g2pDirectoryURL.appendingPathComponent("us_silver.json"))
        try Data("{}".utf8).write(to: g2pDirectoryURL.appendingPathComponent("us_bart_config.json"))
        try Data().write(to: g2pDirectoryURL.appendingPathComponent("us_bart.safetensors"))

        let configuration = try InferenceRuntimeConfiguration(
            modelsDirectoryURL: modelsDirectoryURL,
            sttModelDirectoryName: "parakeet-tdt-0.6b-v3-coreml",
            ttsModelDirectoryName: "kitten-tts-mini-0.8",
            socketURL: temporaryDirectoryURL.appendingPathComponent("inference.sock")
        )

        try configuration.validateFileSystem()

        let sttLoadDirectoryURL = try configuration.sttModelLoadDirectoryURL
        let symlinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: sttLoadDirectoryURL.path)
        #expect(sttLoadDirectoryURL.lastPathComponent == "parakeet-tdt-0.6b-v3")
        #expect(FileManager.default.fileExists(atPath: sttLoadDirectoryURL.path))
        #expect(symlinkDestination == sttDirectoryURL.path)
    }
}

@Test func validateFileSystemRejectsMissingKittenG2PResources() throws {
    try withTemporaryDirectory { temporaryDirectoryURL in
        let modelsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        let sttDirectoryURL = modelsDirectoryURL.appendingPathComponent(
            "parakeet-tdt-0.6b-v3-coreml",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sttDirectoryURL, withIntermediateDirectories: true)
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Encoder.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("Decoder.mlmodelc", isDirectory: true))
        try createDirectory(at: sttDirectoryURL.appendingPathComponent("JointDecision.mlmodelc", isDirectory: true))
        try Data("{}".utf8).write(to: sttDirectoryURL.appendingPathComponent("parakeet_vocab.json"))

        let ttsDirectoryURL = modelsDirectoryURL.appendingPathComponent("kitten-tts-mini-0.8", isDirectory: true)
        try FileManager.default.createDirectory(at: ttsDirectoryURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ttsDirectoryURL.appendingPathComponent("config.json"))
        try Data().write(to: ttsDirectoryURL.appendingPathComponent("model.safetensors"))
        try Data().write(to: ttsDirectoryURL.appendingPathComponent("voices.safetensors"))

        let configuration = try InferenceRuntimeConfiguration(
            modelsDirectoryURL: modelsDirectoryURL,
            sttModelDirectoryName: "parakeet-tdt-0.6b-v3-coreml",
            ttsModelDirectoryName: "kitten-tts-mini-0.8",
            socketURL: temporaryDirectoryURL.appendingPathComponent("inference.sock")
        )

        do {
            try configuration.validateFileSystem()
            Issue.record("Expected validation to fail when bundled Kitten G2P assets are missing")
        } catch let error as InferenceRuntimeConfigurationError {
            switch error {
            case .invalidModelDirectory("--tts-model", let directoryURL, _):
                #expect(directoryURL == configuration.kittenTTSG2PDirectoryURL)
            default:
                Issue.record("Expected invalidModelDirectory for bundled Kitten G2P directory, got \(error)")
            }
        }
    }
}
@Test func parseConfigurationRejectsMissingRequiredSwitch() {
    do {
        _ = try InferenceRuntimeConfiguration.parse(arguments: [
            "--models-dir", "/tmp/models",
            "--stt-model", "parakeet-tdt-0.6b-v3-coreml",
        ])
        Issue.record("Expected parsing to fail when --tts-model is missing")
    } catch let error as InferenceRuntimeConfigurationError {
        switch error {
        case .missingRequiredSwitch("--tts-model"):
            break
        default:
            Issue.record("Expected missingRequiredSwitch(--tts-model), got \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
    try body(temporaryDirectoryURL)
}

private func createDirectory(at directoryURL: URL) throws {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
}
