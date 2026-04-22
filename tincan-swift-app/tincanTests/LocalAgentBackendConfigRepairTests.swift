import Foundation
import Testing
@testable import tincan

struct LocalAgentBackendConfigRepairTests {
    @Test
    func repairRewritesOpencodeServerBackendsForLocalServer() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let payload = """
        {
          "opencode": {
            "type": "opencode",
            "options": {
              "connection_type": "server",
              "base_url": "http://127.0.0.1:4096",
              "model": "openai/gpt-5.3-codex-spark"
            }
          },
          "other": {
            "type": "mock",
            "options": {
              "connection_type": "server"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try LocalAgentBackendConfigRepair.repairOpencodeBackendsForLocalServer(at: fileURL)

        #expect(result == LocalAgentBackendConfigRepairResult(repairedBackendNames: ["opencode"]))

        let repairedData = try Data(contentsOf: fileURL)
        let root = try #require(JSONSerialization.jsonObject(with: repairedData) as? [String: Any])
        let opencode = try #require(root["opencode"] as? [String: Any])
        let options = try #require(opencode["options"] as? [String: Any])

        #expect(options["connection_type"] as? String == "command")
        #expect(options["base_url"] == nil)
        #expect(options["model"] as? String == "openai/gpt-5.3-codex-spark")

        let other = try #require(root["other"] as? [String: Any])
        let otherOptions = try #require(other["options"] as? [String: Any])
        #expect(otherOptions["connection_type"] as? String == "server")
    }

    @Test
    func repairLeavesValidCommandBackendsUnchanged() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let payload = """
        {
          "opencode": {
            "type": "opencode",
            "options": {
              "connection_type": "command",
              "model": "openai/gpt-5.3-codex-spark"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let originalData = try Data(contentsOf: fileURL)
        let result = try LocalAgentBackendConfigRepair.repairOpencodeBackendsForLocalServer(at: fileURL)

        #expect(result == LocalAgentBackendConfigRepairResult(repairedBackendNames: []))
        #expect(try Data(contentsOf: fileURL) == originalData)
    }
}
