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

    @Test func bundledServerArgumentsIncludeRunSubcommand() {
        let arguments = MacBundledTincanServerController.bundledServerArguments(
            dataDir: "/tmp/tincan",
            port: 4490,
            enableTailscale: false
        )

        #expect(arguments == ["run", "--data-dir", "/tmp/tincan", "--port", "4490"])
    }

    @Test func bundledServerArgumentsIncludeTailscaleOnlyWhenEnabled() {
        let enabledArguments = MacBundledTincanServerController.bundledServerArguments(
            dataDir: "/tmp/tincan",
            port: 4490,
            enableTailscale: true
        )
        let disabledArguments = MacBundledTincanServerController.bundledServerArguments(
            dataDir: "/tmp/tincan",
            port: 4490,
            enableTailscale: false
        )

        #expect(enabledArguments.contains("--tailscale"))
        #expect(!disabledArguments.contains("--tailscale"))
        #expect(!enabledArguments.contains("--tailscale-status-file"))
        #expect(!disabledArguments.contains("--no-tailscale"))
    }

    @Test func staleTerminationHandlerDoesNotFinishReplacementProcess() {
        #expect(MacBundledTincanServerController.shouldFinishProcessRun(
            currentProcessIdentifier: 200,
            terminatedProcessIdentifier: 200
        ))
        #expect(!MacBundledTincanServerController.shouldFinishProcessRun(
            currentProcessIdentifier: 201,
            terminatedProcessIdentifier: 200
        ))
    }
}
#endif
