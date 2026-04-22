import Foundation
import Testing
#if os(macOS)
@testable import tincan

struct BundledServerPortListenerLookupTests {
    @Test func parseListeningPIDsDeduplicatesAndExcludesCurrentProcess() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let parsedPIDs = BundledServerPortListenerLookup.parseListeningPIDs(
            from: """
            101
            \(currentPID)

            nope
            202
            101
            """,
            excluding: [currentPID]
        )

        #expect(parsedPIDs == [101, 202])
    }

    @Test func parseListeningPIDsPreservesDiscoveryOrder() {
        let parsedPIDs = BundledServerPortListenerLookup.parseListeningPIDs(
            from: """
            404
            303
            404
            505
            """
        )

        #expect(parsedPIDs == [404, 303, 505])
    }
}
#endif
