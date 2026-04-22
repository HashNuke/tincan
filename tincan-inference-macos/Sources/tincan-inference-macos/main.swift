import Foundation

do {
    let configuration = try InferenceRuntimeConfiguration.parse(
        arguments: Array(ProcessInfo.processInfo.arguments.dropFirst())
    )
    let server = try InferenceSocketServer(config: configuration)
    try server.run()
} catch let error as InferenceRuntimeConfigurationError {
    fputs("\(error)\n", stderr)
    if case .helpRequested = error {
        Foundation.exit(error.exitCode)
    }

    fputs("\n\(InferenceRuntimeConfiguration.usage)\n", stderr)
    Foundation.exit(error.exitCode)
} catch {
    fputs("tincan-inference-macos failed: \(error)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
