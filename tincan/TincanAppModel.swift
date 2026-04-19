import Combine
import Foundation

@MainActor
final class TincanAppModel: ObservableObject {
#if os(iOS)
    let callSession = CallSessionViewModel()
#endif

#if os(macOS)
    let backendHost = BackendServerController()
    let macCallSession = MacCallSessionViewModel()
#endif
}
