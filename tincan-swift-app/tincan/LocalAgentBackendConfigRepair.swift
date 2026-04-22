import Foundation

struct LocalAgentBackendConfigRepairResult: Equatable {
    let repairedBackendNames: [String]

    var didRepair: Bool {
        !repairedBackendNames.isEmpty
    }
}

enum LocalAgentBackendConfigRepair {
    static func repairOpencodeBackendsForLocalServer(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> LocalAgentBackendConfigRepairResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LocalAgentBackendConfigRepairResult(repairedBackendNames: [])
        }

        let data = try Data(contentsOf: fileURL)
        guard let rawRoot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RepairError.invalidRootObject(fileURL.path)
        }

        var root = rawRoot
        var repairedBackendNames: [String] = []

        for backendName in rawRoot.keys.sorted() {
            guard var backend = rawRoot[backendName] as? [String: Any],
                  let backendType = backend["type"] as? String,
                  backendType == "opencode" else {
                continue
            }

            var options = backend["options"] as? [String: Any] ?? [:]
            let previousConnectionType = (options["connection_type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var didChange = false
            if previousConnectionType != "command" {
                options["connection_type"] = "command"
                didChange = true
            }

            if options.removeValue(forKey: "base_url") != nil {
                didChange = true
            }

            guard didChange else { continue }

            backend["options"] = options
            root[backendName] = backend
            repairedBackendNames.append(backendName)
        }

        guard !repairedBackendNames.isEmpty else {
            return LocalAgentBackendConfigRepairResult(repairedBackendNames: [])
        }

        let repairedData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        var output = repairedData
        output.append(0x0A)
        try output.write(to: fileURL, options: .atomic)

        return LocalAgentBackendConfigRepairResult(repairedBackendNames: repairedBackendNames)
    }

    enum RepairError: LocalizedError {
        case invalidRootObject(String)

        var errorDescription: String? {
            switch self {
            case .invalidRootObject(let path):
                return "Agent backend config at \(path) must contain a JSON object."
            }
        }
    }
}
