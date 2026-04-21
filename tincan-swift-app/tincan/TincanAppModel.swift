import Combine
import Foundation

@MainActor
final class TincanAppModel: ObservableObject {
#if os(iOS)
    let callSession = CallSessionViewModel()
#endif

#if os(macOS)
    let macOnboarding = MacOnboardingViewModel()
    let macCallSession = MacCallSessionViewModel()
#endif
}
