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
    private let bundledServerController: MacBundledTincanServerController
    private var bundledServerStartupTask: Task<Void, Never>?
#endif

    init() {
        workspace = TincanWorkspaceStore(serverSettings: serverSettings)

#if os(iOS)
        callSession = CallSessionViewModel(serverSettings: serverSettings)
#endif

#if os(macOS)
        macCallSession = MacCallSessionViewModel(serverSettings: serverSettings)
        bundledServerController = MacBundledTincanServerController(port: BackendConnectionConfig.port)
#endif
    }

#if os(macOS)
    func ensureMacServerStarted() async {
        if let bundledServerStartupTask {
            await bundledServerStartupTask.value
            return
        }

        let task = Task { @MainActor in
            await bundledServerController.startIfNeeded()
        }
        bundledServerStartupTask = task
        await task.value
        bundledServerStartupTask = nil
    }
#endif
}
