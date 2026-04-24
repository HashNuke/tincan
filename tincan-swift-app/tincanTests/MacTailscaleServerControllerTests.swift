import Foundation
import Testing
#if os(macOS)
@testable import tincan

@MainActor
struct MacTailscaleServerControllerTests {
    @Test func parsesAuthURLMarker() {
        let status = MacTailscaleServerController.RuntimeStatus.idle
            .applyingMarkerLine("TINCAN_TAILSCALE_STATUS=needs_login")
            .applyingMarkerLine("TINCAN_TAILSCALE_AUTH_URL=https://login.tailscale.com/a/abc123")

        #expect(status.state == "needs_login")
        #expect(status.authURL == "https://login.tailscale.com/a/abc123")
        #expect(!status.shouldShowSummaryRow)
    }

    @Test func parsesNodeMarkerAsDirectPairingPayload() {
        let status = MacTailscaleServerController.RuntimeStatus.idle
            .applyingMarkerLine("TINCAN_TAILSCALE_STATUS=running")
            .applyingMarkerLine("TINCAN_TAILSCALE_NODE=https://tincan-akash.tail.ts.net")

        #expect(status.state == "serving")
        #expect(status.httpsURL == "https://tincan-akash.tail.ts.net")
        #expect(status.pairingPayload == "https://tincan-akash.tail.ts.net")
    }

    @Test func parsesErrorMarker() {
        let status = MacTailscaleServerController.RuntimeStatus.idle
            .applyingMarkerLine("TINCAN_TAILSCALE_ERROR=no .ts.net domain")

        #expect(status.state == "error")
        #expect(status.message == "no .ts.net domain")
    }

    @Test func startingStatusUsesSingleProgressMessage() {
        let status = MacTailscaleServerController.RuntimeStatus.idle
            .applyingMarkerLine("TINCAN_TAILSCALE_STATUS=starting")

        #expect(status.message == "Starting Tailscale setup...")
        #expect(!status.shouldShowSummaryRow)
    }

    @Test func stopMonitoringTerminatesPendingSetupAndClearsStatus() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let executableURL = temporaryDirectory.appendingPathComponent("fake-tincan-server")
        try """
        #!/bin/sh
        echo TINCAN_TAILSCALE_AUTH_URL=https://login.tailscale.com/a/abc123
        sleep 60
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let controller = MacTailscaleServerController {
            executableURL
        }
        let setupTask = Task {
            try await controller.runSetup()
        }

        for _ in 0..<100 where controller.authURL == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.authURL?.absoluteString == "https://login.tailscale.com/a/abc123")
        controller.stopMonitoring(clearStatus: true)

        do {
            try await setupTask.value
            #expect(Bool(false), "setup task should throw after the setup process is terminated")
        } catch {
            #expect(controller.runtimeStatus == .idle)
        }
    }

    @Test func setupArgumentsUseSetupSubcommandAndDataDir() {
        #expect(MacTailscaleServerController.setupArguments(dataDir: "/tmp/tincan") == [
            "setup-tailscale",
            "--data-dir", "/tmp/tincan",
        ])
    }

    @Test func setupPortReclaimOnlyTargetsSetupTailscaleCommandForSameExecutable() {
        let executablePath = "/Applications/tincan.app/Contents/Resources/BundledRuntime/tincan-server"

        #expect(MacTailscaleServerController.shouldReclaimSetupListener(
            commandLine: "\(executablePath) setup-tailscale --data-dir /tmp/tincan",
            executablePath: executablePath
        ))
        #expect(!MacTailscaleServerController.shouldReclaimSetupListener(
            commandLine: "\(executablePath) run --data-dir /tmp/tincan",
            executablePath: executablePath
        ))
        #expect(!MacTailscaleServerController.shouldReclaimSetupListener(
            commandLine: "/usr/bin/python3 -m http.server 80",
            executablePath: executablePath
        ))
    }
}
#endif
