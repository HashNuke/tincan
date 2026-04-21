import Foundation

actor OwnerProfileStore {
    private let fileURL: URL
    private let legacyFileURL: URL?

    init(fileURL: URL = AppPaths.speakerProfilesURL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        if let legacyFileURL {
            self.legacyFileURL = legacyFileURL
        } else if fileURL == AppPaths.speakerProfilesURL {
            self.legacyFileURL = AppPaths.legacyOwnerProfileURL
        } else {
            self.legacyFileURL = nil
        }
    }

    func loadProfile() throws -> OwnerVoiceProfile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(OwnerVoiceProfile.self, from: data)
        }

        guard let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: legacyFileURL)
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
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        if let legacyFileURL,
           legacyFileURL != fileURL,
           FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    private func ensureParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
