import Foundation
import Observation

/// Local rollout switches shared by the phone and CarPlay. Disabling presentation
/// features leaves the current audio session and saved listening library intact.
@MainActor
@Observable
final class CarPlayRollout {
    static let shared = CarPlayRollout()
    var personalizedHome: Bool { didSet { save(personalizedHome, "home") } }
    var sportsMode: Bool { didSet { save(sportsMode, "sports") } }
    var sportsDrive: Bool { didSet { save(sportsDrive, "drive") } }
    var offlineLibrary: Bool { didSet { save(offlineLibrary, "offline") } }
    var miniPlayer: Bool { didSet { save(miniPlayer, "mini") } }

    private init() {
        let defaults = UserDefaults.standard
        func enabled(_ name: String) -> Bool {
            defaults.object(forKey: "bannertv.carplay.rollout." + name) as? Bool ?? true
        }
        personalizedHome = enabled("home")
        sportsMode = enabled("sports")
        sportsDrive = enabled("drive")
        offlineLibrary = enabled("offline")
        miniPlayer = enabled("mini")
    }

    private func save(_ value: Bool, _ name: String) {
        UserDefaults.standard.set(value, forKey: "bannertv.carplay.rollout." + name)
        CarPlayPlaybackCoordinator.shared.refreshPresentationPreferences()
        NotificationCenter.default.post(name: .bannerPreferencesChanged, object: nil)
    }

    func useBasicExperience() {
        personalizedHome = false
        sportsMode = false
        sportsDrive = false
        offlineLibrary = false
        miniPlayer = false
    }

    func enableAdvancedExperience() {
        personalizedHome = true
        sportsMode = true
        sportsDrive = true
        offlineLibrary = true
        miniPlayer = true
    }
}
