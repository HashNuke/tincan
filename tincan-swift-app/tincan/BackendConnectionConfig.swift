import Foundation

enum BackendConnectionConfig {
    static let publicHost = "wheeljack"
    static let bindHost = "0.0.0.0"
    static let port = 8004

    static let inferencePath = "/infer"
    static let healthPath = "/health"

    static let serverBaseURLString = "http://\(publicHost):\(port)"
    static let loopbackServerBaseURLString = "http://127.0.0.1:\(port)"

    static let inferenceURLString = "http://\(publicHost):\(port)\(inferencePath)"
    static let healthURLString = "http://\(publicHost):\(port)\(healthPath)"
    static let loopbackInferenceURLString = "http://127.0.0.1:\(port)\(inferencePath)"
    static let loopbackHealthURLString = "http://127.0.0.1:\(port)\(healthPath)"
}
