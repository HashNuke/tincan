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
    }
}
