import Foundation

struct BackendInferenceClient {
    struct Response: Decodable {
        let requestId: String
        let transcript: String
    }

    func infer(audioWAV: Data, endpoint: URL) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = audioWAV
        request.timeoutInterval = 180
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard let httpResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
