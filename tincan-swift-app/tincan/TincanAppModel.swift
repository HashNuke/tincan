import Combine
import Foundation

@MainActor
final class TincanAppModel: ObservableObject {
    let serverSettings = ServerConnectionStore()
    let workspace: TincanWorkspaceStore

#if os(iOS)
    let callSession: CallSessionViewModel
#endif

#if os(macOS)
    let macOnboarding = MacOnboardingViewModel()
    let macCallSession: MacCallSessionViewModel
#endif

    init() {
        workspace = TincanWorkspaceStore(serverSettings: serverSettings)

#if os(iOS)
        callSession = CallSessionViewModel(serverSettings: serverSettings)
#endif

#if os(macOS)
        macCallSession = MacCallSessionViewModel(serverSettings: serverSettings)
#endif
    }
}
