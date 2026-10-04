import SwiftUI

/// Whether the app is in the foreground. The periodic refresh loops check this and skip their fetch
/// while it is false: with the audio background mode, a playing podcast or stream keeps the process
/// running after the screen locks, and the loops would otherwise keep polling for UI nobody can see.
/// `AppOrchestration` keeps it current from the scene phase.
@MainActor
final class AppActivity {
    static let shared = AppActivity()
    private(set) var isActive = true

    func update(_ phase: ScenePhase) {
        isActive = phase == .active
    }
}
