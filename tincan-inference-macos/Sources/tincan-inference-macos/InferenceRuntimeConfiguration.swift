import FluidAudio
import Foundation

struct InferenceRuntimeConfiguration: Sendable {
    static let dependenciesDirectoryName = "_dependencies"
    static let kittenTTSG2PDirectoryName = "kitten-tts-g2p"
    static let kittenTTSG2PRequiredFilenames = [
        "us_gold.json",
        "us_silver.json",
        "us_bart_config.json",
        "us_bart.safetensors",
    ]

    let modelsDirectoryURL: URL
    let sttModelDirectoryName: String
    let ttsModelDirectoryName: String
    let socketURL: URL

    var sttModelDirectoryURL: URL {
        modelsDirectoryURL.appendingPathComponent(sttModelDirectoryName, isDirectory: true)
    }

    var ttsModelDirectoryURL: URL {
        modelsDirectoryURL.appendingPathComponent(ttsModelDirectoryName, isDirectory: true)
    }

    var dependenciesDirectoryURL: URL {
        modelsDirectoryURL.appendingPathComponent(Self.dependenciesDirectoryName, isDirectory: true)
    }

    var kittenTTSG2PDirectoryURL: URL {
        dependenciesDirectoryURL.appendingPathComponent(Self.kittenTTSG2PDirectoryName, isDirectory: true)
    }

    var sttModelVersion: AsrModelVersion {
        get throws {
            try Self.inferSTTModelVersion(from: sttModelDirectoryName)
        }
    }

    var sttModelLoadDirectoryURL: URL {
        get throws {
            modelsDirectoryURL.appendingPathComponent(try sttModelLoadDirectoryName, isDirectory: true)
        }
    }

    init(
        modelsDirectoryURL: URL,
        sttModelDirectoryName: String,
        ttsModelDirectoryName: String,
        socketURL: URL
    ) throws {
        let normalizedSTTName = try Self.normalizedSwitchValue(sttModelDirectoryName, switchName: "--stt-model")
        let normalizedTTSName = try Self.normalizedSwitchValue(ttsModelDirectoryName, switchName: "--tts-model")

        self.modelsDirectoryURL = modelsDirectoryURL.standardizedFileURL
        self.sttModelDirectoryName = normalizedSTTName
        self.ttsModelDirectoryName = normalizedTTSName
        self.socketURL = socketURL.standardizedFileURL
    }

    static func parse(arguments: [String]) throws -> InferenceRuntimeConfiguration {
        if arguments.contains("--help") || arguments.contains("-h") {
            throw InferenceRuntimeConfigurationError.helpRequested
        }

        let switchValues = try parseSwitchValues(arguments: arguments)

        let modelsDirectoryPath = try requireSwitch("--models-dir", in: switchValues)
        let sttModelDirectoryName = try requireSwitch("--stt-model", in: switchValues)
        let ttsModelDirectoryName = try requireSwitch("--tts-model", in: switchValues)
        let socketPath = switchValues["--socket-path"] ?? AppRuntimePaths.inferenceSocketURL.path

        return try InferenceRuntimeConfiguration(
            modelsDirectoryURL: resolveURL(from: modelsDirectoryPath, isDirectory: true),
            sttModelDirectoryName: sttModelDirectoryName,
            ttsModelDirectoryName: ttsModelDirectoryName,
            socketURL: resolveURL(from: socketPath, isDirectory: false)
        )
    }

    func validateFileSystem() throws {
        try Self.validateDirectoryExists(modelsDirectoryURL, switchName: "--models-dir")
        try Self.validateDirectoryExists(sttModelDirectoryURL, switchName: "--stt-model")
        try Self.validateDirectoryExists(ttsModelDirectoryURL, switchName: "--tts-model")

        let sttVersion = try sttModelVersion
        let sttLoadDirectoryURL = try prepareSTTModelLoadDirectory()
        guard AsrModels.modelsExist(at: sttLoadDirectoryURL, version: sttVersion) else {
            throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                switchName: "--stt-model",
                modelDirectoryURL: sttLoadDirectoryURL,
                reason: "expected a staged Parakeet repo folder with Core ML bundles and parakeet_vocab.json"
            )
        }

        let configURL = ttsModelDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                switchName: "--tts-model",
                modelDirectoryURL: ttsModelDirectoryURL,
                reason: "missing config.json"
            )
        }

        let modelFiles = try FileManager.default.contentsOfDirectory(
            at: ttsModelDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let hasWeights = modelFiles.contains { fileURL in
            fileURL.pathExtension == "safetensors" && fileURL.lastPathComponent != "voices.safetensors"
        }
        guard hasWeights else {
            throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                switchName: "--tts-model",
                modelDirectoryURL: ttsModelDirectoryURL,
                reason: "expected at least one model .safetensors file"
            )
        }

        let voicesURL = ttsModelDirectoryURL.appendingPathComponent("voices.safetensors", isDirectory: false)
        guard FileManager.default.fileExists(atPath: voicesURL.path) else {
            throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                switchName: "--tts-model",
                modelDirectoryURL: ttsModelDirectoryURL,
                reason: "missing voices.safetensors"
            )
        }

        if requiresBundledKittenTTSG2P {
            var isG2PDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: kittenTTSG2PDirectoryURL.path, isDirectory: &isG2PDirectory), isG2PDirectory.boolValue else {
                throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                    switchName: "--tts-model",
                    modelDirectoryURL: kittenTTSG2PDirectoryURL,
                    reason: "missing bundled Kitten G2P directory; stage assets under <models-dir>/\(Self.dependenciesDirectoryName)/\(Self.kittenTTSG2PDirectoryName) or run build-deps.sh"
                )
            }

            let missingG2PResources = Self.kittenTTSG2PRequiredFilenames.filter { filename in
                let resourceURL = kittenTTSG2PDirectoryURL.appendingPathComponent(filename, isDirectory: false)
                return FileManager.default.fileExists(atPath: resourceURL.path) == false
            }

            guard missingG2PResources.isEmpty else {
                throw InferenceRuntimeConfigurationError.invalidModelDirectory(
                    switchName: "--tts-model",
                    modelDirectoryURL: kittenTTSG2PDirectoryURL,
                    reason: "missing bundled Kitten G2P assets (\(missingG2PResources.joined(separator: ", "))); stage them under <models-dir>/\(Self.dependenciesDirectoryName)/\(Self.kittenTTSG2PDirectoryName) or run build-deps.sh"
                )
            }
        }
    }

    @discardableResult
    func prepareSTTModelLoadDirectory() throws -> URL {
        let loadDirectoryURL = try sttModelLoadDirectoryURL
        guard loadDirectoryURL != sttModelDirectoryURL else {
            return loadDirectoryURL
        }

        if FileManager.default.fileExists(atPath: loadDirectoryURL.path) {
            return loadDirectoryURL
        }

        try FileManager.default.createSymbolicLink(
            at: loadDirectoryURL,
            withDestinationURL: sttModelDirectoryURL
        )
        return loadDirectoryURL
    }

    static let usage = """
    Usage:
      tincan-inference-macos --models-dir <path> --stt-model <dir-name> --tts-model <dir-name> [--socket-path <path>]

    Required:
      --models-dir   Base directory containing staged model subdirectories.
      --stt-model    STT model subdirectory inside --models-dir.
      --tts-model    TTS model subdirectory inside --models-dir.

    Optional:
      --socket-path  Unix domain socket path. Defaults to \(AppRuntimePaths.inferenceSocketURL.path)

    Example:
      swift run tincan-inference-macos \\
        --models-dir /opt/tincan/models \\
        --stt-model parakeet-tdt-0.6b-v3-coreml \\
        --tts-model kitten-tts-mini-0.8

    Notes:
      KittenTTS expects bundled G2P assets at:
      <models-dir>/\(dependenciesDirectoryName)/\(kittenTTSG2PDirectoryName)
    """

    private var requiresBundledKittenTTSG2P: Bool {
        ttsModelDirectoryName.lowercased().contains("kitten-tts")
    }

    private static func parseSwitchValues(arguments: [String]) throws -> [String: String] {
        let knownSwitches: Set<String> = ["--models-dir", "--stt-model", "--tts-model", "--socket-path"]
        var switchValues: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw InferenceRuntimeConfigurationError.unexpectedArgument(argument)
            }
            guard knownSwitches.contains(argument) else {
                throw InferenceRuntimeConfigurationError.unknownSwitch(argument)
            }
            guard switchValues[argument] == nil else {
                throw InferenceRuntimeConfigurationError.duplicateSwitch(argument)
            }

            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw InferenceRuntimeConfigurationError.missingValue(argument)
            }

            let value = arguments[valueIndex]
            guard value.hasPrefix("--") == false else {
                throw InferenceRuntimeConfigurationError.missingValue(argument)
            }

            switchValues[argument] = value
            index += 2
        }

        return switchValues
    }

    private static func requireSwitch(_ switchName: String, in switchValues: [String: String]) throws -> String {
        guard let value = switchValues[switchName] else {
            throw InferenceRuntimeConfigurationError.missingRequiredSwitch(switchName)
        }
        return try normalizedSwitchValue(value, switchName: switchName)
    }

    private static func normalizedSwitchValue(_ value: String, switchName: String) throws -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false else {
            throw InferenceRuntimeConfigurationError.emptyValue(switchName)
        }
        return trimmedValue
    }

    private static func resolveURL(from path: String, isDirectory: Bool) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath, isDirectory: isDirectory).standardizedFileURL
        }

        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return currentDirectoryURL
            .appendingPathComponent(expandedPath, isDirectory: isDirectory)
            .standardizedFileURL
    }

    private static func validateDirectoryExists(_ directoryURL: URL, switchName: String) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InferenceRuntimeConfigurationError.directoryNotFound(
                switchName: switchName,
                directoryURL: directoryURL
            )
        }
    }

    private static func inferSTTModelVersion(from directoryName: String) throws -> AsrModelVersion {
        let normalizedName = directoryName.lowercased()

        if normalizedName.contains("parakeet-tdt-0.6b-v2") {
            return .v2
        }
        if normalizedName.contains("parakeet-tdt-0.6b-v3") {
            return .v3
        }
        if normalizedName.contains("parakeet-tdt-ctc-110m") {
            return .tdtCtc110m
        }
        if normalizedName.contains("parakeet-0.6b-ja") || normalizedName.contains("parakeet-ja") {
            return .tdtJa
        }

        throw InferenceRuntimeConfigurationError.unsupportedSTTModel(directoryName)
    }

    private var sttModelLoadDirectoryName: String {
        get throws {
            switch try sttModelVersion {
            case .v2:
                return "parakeet-tdt-0.6b-v2"
            case .v3:
                return "parakeet-tdt-0.6b-v3"
            case .tdtCtc110m:
                return "parakeet-tdt-ctc-110m"
            case .tdtJa:
                return "parakeet-ctc-ja"
            case .ctcZhCn:
                return "parakeet-ctc-zh-cn"
            case .ctcJa:
                return "parakeet-ctc-ja"
            }
        }
    }
}

enum InferenceRuntimeConfigurationError: Error, CustomStringConvertible {
    case helpRequested
    case missingRequiredSwitch(String)
    case missingValue(String)
    case emptyValue(String)
    case duplicateSwitch(String)
    case unexpectedArgument(String)
    case unknownSwitch(String)
    case directoryNotFound(switchName: String, directoryURL: URL)
    case invalidModelDirectory(switchName: String, modelDirectoryURL: URL, reason: String)
    case unsupportedSTTModel(String)

    var exitCode: Int32 {
        switch self {
        case .helpRequested:
            return EXIT_SUCCESS
        default:
            return EX_USAGE
        }
    }

    var description: String {
        switch self {
        case .helpRequested:
            return InferenceRuntimeConfiguration.usage
        case .missingRequiredSwitch(let switchName):
            return "Missing required switch: \(switchName)"
        case .missingValue(let switchName):
            return "Missing value for switch: \(switchName)"
        case .emptyValue(let switchName):
            return "Switch requires a non-empty value: \(switchName)"
        case .duplicateSwitch(let switchName):
            return "Switch provided more than once: \(switchName)"
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        case .unknownSwitch(let switchName):
            return "Unknown switch: \(switchName)"
        case .directoryNotFound(let switchName, let directoryURL):
            return "\(switchName) does not point to an existing directory: \(directoryURL.path)"
        case .invalidModelDirectory(let switchName, let modelDirectoryURL, let reason):
            return "\(switchName) is not a valid staged model directory (\(reason)): \(modelDirectoryURL.path)"
        case .unsupportedSTTModel(let directoryName):
            return "Unsupported STT model directory '\(directoryName)'. Expected a Parakeet repo folder such as parakeet-tdt-0.6b-v3-coreml, parakeet-tdt-0.6b-v2-coreml, parakeet-tdt-ctc-110m-coreml, or parakeet-0.6b-ja-coreml."
        }
    }
}
