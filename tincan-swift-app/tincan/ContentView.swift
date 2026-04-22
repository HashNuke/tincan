import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: TincanAppModel

    var body: some View {
#if os(iOS)
        TincanIOSRootView(
            callSession: appModel.callSession,
            workspace: appModel.workspace,
            serverSettings: appModel.serverSettings
        )
#elseif os(macOS)
        if appModel.macOnboarding.isCompleted {
            TincanMacRootView(
                ensureServerStarted: {
                    await appModel.ensureMacServerStarted()
                },
                callSession: appModel.macCallSession,
                workspace: appModel.workspace,
                serverSettings: appModel.serverSettings
            )
        } else {
            MacOnboardingView(viewModel: appModel.macOnboarding)
        }
#else
        Text("tincan is currently configured for iOS and macOS.")
            .padding()
#endif
    }
}
