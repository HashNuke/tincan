import SwiftUI

@main
struct tincanApp: App {
    @StateObject private var appModel = TincanAppModel()

    init() {
        AppPaths.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
#if os(macOS)
                .task {
                    await appModel.ensureMacServerStarted()
                }
#endif
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
#endif

#if os(macOS)
        Settings {
            TincanMacSettingsWindow(
                callSession: appModel.macCallSession,
                speechSettings: appModel.macSpeechSettings,
                workspace: appModel.workspace,
                serverSettings: appModel.serverSettings
            )
            .environmentObject(appModel)
        }
#endif
    }
}
