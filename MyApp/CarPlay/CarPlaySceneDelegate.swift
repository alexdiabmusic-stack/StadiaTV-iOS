#if canImport(CarPlay)
import CarPlay
import UIKit

/// Entry point CarPlay calls when it connects/disconnects our app's CarPlay scene.
/// Registered by class name in Info.plist's `UIApplicationSceneManifest` —
/// see `CPTemplateApplicationSceneSessionRoleApplication`. No AppDelegate/SceneDelegate
/// exists elsewhere in this SwiftUI-lifecycle app; this is the one UIKit-shaped entry point
/// CarPlay's template framework requires.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coordinator
        coordinator.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}
#endif
