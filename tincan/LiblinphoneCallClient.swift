#if os(macOS) || os(iOS)
import Foundation
import linphonesw

protocol LiblinphoneCallClientDelegate: AnyObject {
    func liblinphoneCallClient(_ client: LiblinphoneCallClient, didLog message: String)
}

@MainActor
final class LiblinphoneCallClient {
    weak var delegate: LiblinphoneCallClientDelegate?

    private var core: Core?

    func start() throws {
        if core != nil {
            log("Liblinphone core already running")
            return
        }

        let factory = Factory.Instance
        let core = try factory.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
        core.start()
        self.core = core
        log("Started Liblinphone core")
    }

    func stop() {
        core?.stop()
        core = nil
        log("Stopped Liblinphone core")
    }

    private func log(_ message: String) {
        delegate?.liblinphoneCallClient(self, didLog: message)
    }
}
#endif
