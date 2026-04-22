import SwiftUI

#if os(macOS)
import AppKit
#endif

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
                .background(MacTransparentTitlebarConfigurator())
                .task {
                    await appModel.ensureMacServerStarted()
                }
#endif
        }
    }
}

#if os(macOS)
private struct MacTransparentTitlebarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
    }
}
#endif
