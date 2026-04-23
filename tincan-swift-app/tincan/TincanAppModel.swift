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
    let macSpeechSettings: TincanSpeechSettingsStore
    private let bundledServerController: MacBundledTincanServerController
    private var bundledServerStartupTask: Task<Void, Never>?
    private var connectionModeCancellable: AnyCancellable?
#endif

    init() {
        workspace = TincanWorkspaceStore(serverSettings: serverSettings)

#if os(iOS)
        callSession = CallSessionViewModel(serverSettings: serverSettings)
#endif

#if os(macOS)
        macCallSession = MacCallSessionViewModel(serverSettings: serverSettings)
        let bundledServerController = MacBundledTincanServerController(port: BackendConnectionConfig.port)
        self.bundledServerController = bundledServerController
        macSpeechSettings = TincanSpeechSettingsStore(
            serverSettings: serverSettings,
            restartLocalServer: {
                try await bundledServerController.restart()
            }
        )
        connectionModeCancellable = serverSettings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    await self?.handleConnectionModeChange(mode)
                }
            }
#endif
    }

#if os(macOS)
    func ensureMacServerStarted() async {
        guard serverSettings.connectionMode == .localMac else {
            bundledServerStartupTask?.cancel()
            bundledServerStartupTask = nil
            bundledServerController.stop()
            return
        }

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

    private func handleConnectionModeChange(_ mode: ServerConnectionStore.ConnectionMode) async {
        switch mode {
        case .localMac:
            await ensureMacServerStarted()
        case .remote:
            bundledServerStartupTask?.cancel()
            bundledServerStartupTask = nil
            bundledServerController.stop()
        }
    }
#endif
}
