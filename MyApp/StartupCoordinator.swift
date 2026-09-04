import SwiftUI
import Combine

// MARK: - Launch Phase

enum LaunchPhase: Equatable {
    /// All-white logo centered. iOS launch screen hands off here seamlessly.
    case brandWhite
    /// "TV" animating from white → Stadia blue (0.20–0.65 s).
    case colorizingTV
    /// Fully branded wordmark resting while the startup pipeline runs.
    case brandComplete
    /// Minimum brand duration met; waiting for the Home shell to report ready.
    case waitingForShell
    /// Logo travelling from center to the Home navigation-bar header position.
    case transitioningToHome
    /// Overlay gone; normal app in full control.
    case home
}

// MARK: - StartupCoordinator

/// Owns the cold-launch state machine and orchestrates timing between the
/// brand animation and the async startup pipeline.
///
/// Lifecycle:
///   1. Call `startBrandSequence()` as early as the WindowGroup appears.
///   2. Call `markAppShellReady()` once the Home view has data to show.
///   3. The coordinator fires the home transition when *both* conditions are met.
@MainActor
final class StartupCoordinator: ObservableObject {

    @Published private(set) var phase: LaunchPhase = .brandWhite
    /// True once the logo-to-header animation has begun. Drives SwiftUI
    /// `.animation(value:)` modifiers in `LaunchAnimationView`.
    @Published private(set) var isTransitioningToHome = false

    // MARK: Internal timing flags

    private var minimumBrandMet = false
    private var shellReady = false
    private var transitionFired = false

    // MARK: DEBUG instrumentation

    #if DEBUG
    private let t0 = Date()
    private var marks: [(String, Int)] = []

    private func mark(_ label: String) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        marks.append((label, ms))
    }

    private func printReport() {
        print("\n━━━ STADIA STARTUP ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for (label, ms) in marks {
            let padding = String(repeating: " ", count: max(1, 34 - label.count))
            print("  \(label)\(padding)\(ms) ms")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }
    #endif

    // MARK: - Public API

    /// Begin the brand animation timeline. Safe to call multiple times (no-op after first).
    func startBrandSequence() {
        guard phase == .brandWhite else { return }
        #if DEBUG
        mark("process / brand start")
        #endif

        Task { @MainActor in
            // ── t = 0.20 s ────────────────────────────────────────────────
            // Begin animating "TV" from white to Stadia blue.
            // The withAnimation here propagates into BrandMark(tvColor:) via
            // SwiftUI's animation transaction so Color interpolates smoothly.
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeInOut(duration: 0.45)) {
                self.phase = .colorizingTV
            }

            // ── t = 0.65 s ────────────────────────────────────────────────
            // TV colourisation complete; brand rests.
            try? await Task.sleep(for: .milliseconds(450))
            self.phase = .brandComplete
            #if DEBUG
            self.mark("brand complete  (0.65 s)")
            #endif

            // ── t = 1.10 s ────────────────────────────────────────────────
            // Minimum brand presentation met.
            try? await Task.sleep(for: .milliseconds(450))
            self.minimumBrandMet = true
            #if DEBUG
            self.mark("minimum brand met  (1.10 s)")
            #endif

            if self.shellReady {
                // Home was already ready — brief intentional rest before moving.
                try? await Task.sleep(for: .milliseconds(150))
                self.fireTransition()
            } else {
                self.phase = .waitingForShell
                // Graceful degradation: never wait more than 1.5 s beyond
                // minimum brand duration, even if the shell never reports ready.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !self.transitionFired else { return }
                    #if DEBUG
                    self.mark("graceful timeout fired")
                    #endif
                    self.fireTransition()
                }
            }
        }
    }

    /// Call this when the Home view first has content to display.
    /// Idempotent — safe to call more than once.
    func markAppShellReady() {
        guard !shellReady else { return }
        shellReady = true
        #if DEBUG
        mark("app shell ready")
        #endif
        guard minimumBrandMet else { return }
        // Minimum brand time already elapsed — short rest then transition.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.fireTransition()
        }
    }

    // MARK: - Private

    private func fireTransition() {
        guard !transitionFired else { return }
        transitionFired = true
        #if DEBUG
        mark("home transition fired")
        #endif

        // Setting isTransitioningToHome to true triggers the `.animation(value:)`
        // modifiers in LaunchAnimationView — background fades out, logo flies up.
        isTransitioningToHome = true

        Task { @MainActor in
            // Wait for the logo animation to fully complete before removing the overlay.
            // 750 ms matches the 0.65 s logo travel + ~100 ms buffer for the
            // tab-bar cover strip, which fades out over 0.35 s starting at T+400 ms.
            try? await Task.sleep(for: .milliseconds(750))
            self.phase = .home
            #if DEBUG
            self.mark("home phase active — overlay removed")
            self.printReport()
            #endif
        }
    }
}
