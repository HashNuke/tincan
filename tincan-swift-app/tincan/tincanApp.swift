import SwiftUI

@main
struct tincanApp: App {
    @StateObject private var appModel = TincanAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}
