import Combine
import Foundation
import Testing
#if os(macOS)
@testable import tincan

@MainActor
struct TincanAppModelTests {
    @Test func forwardsTailscaleControllerChanges() {
        let model = TincanAppModel()
        var didPublishChange = false
        let cancellable = model.objectWillChange.sink {
            didPublishChange = true
        }

        model.tailscaleController.applyStatusMarkerLine("TINCAN_TAILSCALE_AUTH_URL=https://login.tailscale.com/a/abc123")

        #expect(didPublishChange)
        _ = cancellable
    }
}
#endif
