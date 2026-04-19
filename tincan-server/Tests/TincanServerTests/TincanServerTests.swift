@testable import TincanServer
import Testing
import Vapor
import VaporTesting

@Suite("Tincan Server Tests", .serialized)
struct TincanServerTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Health route reports server status")
    func health() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .ok)

                let payload = try response.content.decode(HealthResponse.self)
                #expect(payload.status == "ok")
                #expect(payload.modelCacheDirectory.isEmpty == false)
                #expect(payload.isModelReady == false)
            }
        }
    }

    @Test("Infer rejects an empty body")
    func inferRejectsEmptyBody() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "infer") { response async throws in
                #expect(response.status == .badRequest)
            }
        }
    }
}
