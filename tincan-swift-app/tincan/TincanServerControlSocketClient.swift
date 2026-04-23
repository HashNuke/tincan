#if os(macOS)
import Darwin
import Foundation

struct TincanServerControlSocketClient {
    private struct Request: Encodable {
        let action: String
        let data: [String: String]
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
    }

    enum ClientError: LocalizedError {
        case socketPathTooLong(String)
        case createSocket(String)
        case connect(String, String)
        case shutdownWrite(String)
        case invalidResponse
        case serverRejected(String)

        var errorDescription: String? {
            switch self {
            case .socketPathTooLong(let path):
                return "Control socket path is too long: \(path)"
            case .createSocket(let message):
                return "Creating control socket failed: \(message)"
            case .connect(let path, let message):
                return "Connecting to control socket \(path) failed: \(message)"
            case .shutdownWrite(let message):
                return "Closing control socket write end failed: \(message)"
            case .invalidResponse:
                return "Control socket returned an invalid response."
            case .serverRejected(let message):
                return "tincan-server rejected the control request: \(message)"
            }
        }
    }

    let socketURL: URL

    init(socketURL: URL = AppPaths.tincanServerSocketURL) {
        self.socketURL = socketURL
    }

    func sendSecrets(_ updates: [String: String]) async throws {
        guard !updates.isEmpty else { return }

        let socketURL = self.socketURL
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.sendSecretsSync(updates, to: socketURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sendSecretsSync(_ updates: [String: String], to socketURL: URL) throws {
        let payload = try JSONEncoder().encode(Request(action: "secrets", data: updates))
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ClientError.createSocket(String(cString: strerror(errno)))
        }
        defer { _ = close(fileDescriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketURL.path.utf8)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        let maxPathLength = sunPathSize - 1
        guard pathBytes.count <= maxPathLength else {
            throw ClientError.socketPathTooLong(socketURL.path)
        }

        let pathLength = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { charPointer in
                charPointer.initialize(repeating: 0, count: sunPathSize)
                for (index, byte) in pathBytes.enumerated() {
                    charPointer[index] = CChar(bitPattern: byte)
                }
                return pathBytes.count
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathLength + 1)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fileDescriptor, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            throw ClientError.connect(socketURL.path, String(cString: strerror(errno)))
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: payload)

        guard shutdown(fileDescriptor, SHUT_WR) == 0 else {
            throw ClientError.shutdownWrite(String(cString: strerror(errno)))
        }

        guard let responseData = try handle.readToEnd(),
              !responseData.isEmpty else {
            throw ClientError.invalidResponse
        }

        let response = try JSONDecoder().decode(Response.self, from: responseData)
        guard response.ok else {
            throw ClientError.serverRejected(response.error ?? "Unknown error")
        }
    }
}
#endif
