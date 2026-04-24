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
    let tailscaleController: MacTailscaleServerController
    @Published private(set) var connectPhoneSetupRequested = false
    private let bundledServerController: MacBundledTincanServerController
    private var bundledServerStartupTask: Task<Void, Never>?
    private var connectionModeCancellable: AnyCancellable?
    private var tailscaleControllerCancellable: AnyCancellable?
#endif

    init() {
        workspace = TincanWorkspaceStore(serverSettings: serverSettings)

#if os(iOS)
        callSession = CallSessionViewModel(serverSettings: serverSettings)
#endif

#if os(macOS)
        macCallSession = MacCallSessionViewModel(serverSettings: serverSettings)
        let sharedServerSettings = serverSettings
        let bundledServerController = MacBundledTincanServerController(port: BackendConnectionConfig.port)
        self.bundledServerController = bundledServerController
        tailscaleController = MacTailscaleServerController()
        macSpeechSettings = TincanSpeechSettingsStore(
            serverSettings: serverSettings,
            restartLocalServer: {
                try await bundledServerController.restart(enableTailscale: sharedServerSettings.connectPhoneEnabled)
            },
            syncLocalServerSecretUpdates: { updates in
                try await bundledServerController.startIfNeeded(enableTailscale: sharedServerSettings.connectPhoneEnabled)
                try await bundledServerController.sendSecretUpdates(updates)
            },
            syncLocalServerSecrets: {
                try await bundledServerController.startIfNeeded(enableTailscale: sharedServerSettings.connectPhoneEnabled)
                try await bundledServerController.syncStoredSecretsFromKeychain()
            }
        )
        connectionModeCancellable = serverSettings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    await self?.handleConnectionModeChange(mode)
                }
            }
        tailscaleControllerCancellable = tailscaleController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
#endif
    }

#if os(macOS)
    var connectPhoneToggleIsOn: Bool {
        serverSettings.connectPhoneEnabled || connectPhoneSetupRequested
    }

    func setConnectPhoneToggle(_ isEnabled: Bool) {
        Task { @MainActor in
            if isEnabled {
                await handleConnectPhoneEnableRequest()
            } else {
                await handleConnectPhoneDisableRequest()
            }
        }
    }

    func stopConnectPhoneSetupIfPending() {
        guard connectPhoneSetupRequested, !serverSettings.connectPhoneEnabled else { return }
        connectPhoneSetupRequested = false
        tailscaleController.stopMonitoring(clearStatus: true)
    }

    func ensureMacServerStarted() async {
        guard serverSettings.shouldUseBundledServer else {
            bundledServerStartupTask?.cancel()
            bundledServerStartupTask = nil
            tailscaleController.stopMonitoring(clearStatus: true)
            bundledServerController.stop()
            return
        }

        if let bundledServerStartupTask {
            await bundledServerStartupTask.value
            return
        }

        let task = Task { @MainActor in
            do {
                try await bundledServerController.startIfNeeded(enableTailscale: serverSettings.connectPhoneEnabled)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Failed to start bundled tincan-server: %@", error.localizedDescription)
                return
            }

            do {
                try await bundledServerController.syncStoredSecretsFromKeychain()
            } catch {
                NSLog("Failed to sync bundled tincan-server secrets: %@", error.localizedDescription)
            }

            if self.serverSettings.connectPhoneEnabled {
                self.tailscaleController.startMonitoring()
                self.tailscaleController.refreshStatus()
            } else {
                self.tailscaleController.stopMonitoring(clearStatus: true)
            }
        }
        bundledServerStartupTask = task
        await task.value
        bundledServerStartupTask = nil
    }

    private func handleConnectionModeChange(_ mode: ServerConnectionStore.ConnectionMode) async {
        _ = mode

        if serverSettings.shouldUseBundledServer {
            await ensureMacServerStarted()
        } else {
            bundledServerStartupTask?.cancel()
            bundledServerStartupTask = nil
            tailscaleController.stopMonitoring(clearStatus: true)
            bundledServerController.stop()
        }
    }

    private func handleConnectPhoneEnableRequest() async {
        guard serverSettings.shouldUseBundledServer else {
            tailscaleController.stopMonitoring(clearStatus: true)
            return
        }

        guard !serverSettings.connectPhoneEnabled, !connectPhoneSetupRequested else { return }

        connectPhoneSetupRequested = true
        do {
            try await tailscaleController.runSetup()
            serverSettings.setConnectPhoneEnabled(true)
            connectPhoneSetupRequested = false
            try await bundledServerController.restart(enableTailscale: true)
        } catch {
            connectPhoneSetupRequested = false
            NSLog("Failed to complete Tailscale setup for phone connection: %@", error.localizedDescription)
        }
    }

    private func handleConnectPhoneDisableRequest() async {
        connectPhoneSetupRequested = false
        tailscaleController.stopMonitoring(clearStatus: true)
        guard serverSettings.shouldUseBundledServer else {
            return
        }

        do {
            if serverSettings.connectPhoneEnabled {
                serverSettings.setConnectPhoneEnabled(false)
            }
            try await bundledServerController.restart(enableTailscale: false)
        } catch {
            NSLog("Failed to disable Tailscale phone connection: %@", error.localizedDescription)
        }
    }
#endif
}
