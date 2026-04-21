import Foundation

actor OwnerProfileStore {
    private let fileURL: URL

    init(fileURL: URL = AppPaths.ownerProfileURL) {
        self.fileURL = fileURL
    }

    func loadProfile() throws -> OwnerVoiceProfile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OwnerVoiceProfile.self, from: data)
    }

    func saveProfile(_ profile: OwnerVoiceProfile) throws {
        try ensureParentDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        try data.write(to: fileURL, options: .atomic)
    }

    func clearProfile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func ensureParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
