import Foundation
import Testing
#if os(macOS)
@testable import tincan

struct BundledServerLogFilePolicyTests {
    @Test func openingForAppendDoesNotTruncateOversizedLog() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        let oversizedCount = Int(BundledServerLogFilePolicy.truncationThresholdBytes + 1)
        try Data(repeating: 0x41, count: oversizedCount).write(to: logURL)

        let handle = try BundledServerLogFilePolicy.openLogFileForAppend(at: logURL)
        try handle.write(contentsOf: Data([0x44]))
        try handle.close()

        let persistedData = try Data(contentsOf: logURL)
        #expect(persistedData.count == oversizedCount + 1)
        #expect(persistedData.last == 0x44)
    }

    @Test func appendsWhenLogFileIsAtThreshold() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        let threshold = BundledServerLogFilePolicy.truncationThresholdBytes
        try Data(repeating: 0x41, count: Int(threshold)).write(to: logURL)

        let result = try BundledServerLogFilePolicy.prepareLogFile(at: logURL)
        #expect(result.existingSize == threshold)
        #expect(!result.wasTruncated)

        try result.handle.write(contentsOf: Data([0x42]))
        try result.handle.close()

        let persistedData = try Data(contentsOf: logURL)
        #expect(persistedData.count == Int(threshold) + 1)
        #expect(persistedData.last == 0x42)
    }

    @Test func truncatesWhenLogFileExceedsThreshold() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        let oversizedCount = Int(BundledServerLogFilePolicy.truncationThresholdBytes + 1)
        try Data(repeating: 0x41, count: oversizedCount).write(to: logURL)

        let result = try BundledServerLogFilePolicy.prepareLogFile(at: logURL)
        #expect(result.existingSize == UInt64(oversizedCount))
        #expect(result.wasTruncated)

        try result.handle.write(contentsOf: Data([0x43]))
        try result.handle.close()

        let persistedData = try Data(contentsOf: logURL)
        #expect(persistedData == Data([0x43]))
    }
}
#endif
