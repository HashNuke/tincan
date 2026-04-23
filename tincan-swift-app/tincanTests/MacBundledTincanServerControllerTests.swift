import Foundation
import Testing
#if os(macOS)
@testable import tincan

struct MacBundledTincanServerControllerTests {
    @Test func classifyPortListenersOnlyReclaimsMatchingBundledExecutable() {
        let disposition = MacBundledTincanServerController.classifyPortListeners(
            [101, 202, 303],
            bundledExecutablePath: "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server",
            processExecutablePath: { pid in
                switch pid {
                case 101:
                    return "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server"
                case 202:
                    return "/usr/local/bin/tincan-server"
                default:
                    return nil
                }
            }
        )

        #expect(disposition.reclaimablePIDs == [101])
        #expect(disposition.blockingPIDs == [202, 303])
    }

    @Test func classifyPortListenersReclaimsTrackedPIDWhenExecutablePathIsUnavailable() {
        let disposition = MacBundledTincanServerController.classifyPortListeners(
            [101, 202],
            bundledExecutablePath: "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server",
            trackedPID: 202,
            processExecutablePath: { pid in
                switch pid {
                case 101:
                    return "/usr/local/bin/tincan-server"
                default:
                    return nil
                }
            }
        )

        #expect(disposition.reclaimablePIDs == [202])
        #expect(disposition.blockingPIDs == [101])
    }

    @Test func classifyPortListenersDoesNotReclaimUnknownExecutableWithoutTrackedPIDMatch() {
        let disposition = MacBundledTincanServerController.classifyPortListeners(
            [101, 202],
            bundledExecutablePath: "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server",
            trackedPID: 303,
            processExecutablePath: { pid in
                switch pid {
                case 101:
                    return "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server"
                default:
                    return nil
                }
            }
        )

        #expect(disposition.reclaimablePIDs == [101])
        #expect(disposition.blockingPIDs == [202])
    }

    @Test func sameBundledExecutablePathNormalizesSymlinks() {
        let lhs = "/tmp/../Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server"
        let rhs = "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server"

        #expect(MacBundledTincanServerController.sameBundledExecutablePath(lhs, rhs))
    }
}
#endif
