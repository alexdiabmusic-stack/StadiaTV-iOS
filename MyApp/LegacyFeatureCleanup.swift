import Foundation
import UserNotifications

/// One-time removal of on-device data left behind by features that no longer exist:
/// scheduled recordings (DVR) and the parental-controls PIN.
///
/// Without this, devices that used those features would keep firing "Recording starting
/// soon" local notifications that lead nowhere, and keep recorded `.ts` files that nothing
/// in the app can play or delete any more. Guarded by a UserDefaults flag so it runs once
/// per install and never touches anything created afterwards.
enum LegacyFeatureCleanup {
    private static let completedKey = "bannertv.legacyCleanup.dvrAndParentalControls.v1"

    private static let parentalControlKeys = [
        "bannertv.pc.pinHash.v1",
        "bannertv.pc.enabled.v1",
        "bannertv.pc.blockedChannels.v1",
        "bannertv.pc.blockedGroups.v1",
        "bannertv.pc.pinForSettings.v1",
    ]

    private static let recordingNotificationPrefix = "bannertv.rec."

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return }
        // Mark done first: a crash part-way must not turn into a retry loop on every launch.
        defaults.set(true, forKey: completedKey)

        parentalControlKeys.forEach { defaults.removeObject(forKey: $0) }

        #if !os(tvOS)
        // Scheduling was iOS-only, so there is nothing pending to cancel on tvOS.
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(recordingNotificationPrefix) }
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        #endif

        Task.detached(priority: .utility) { removeRecordingFiles() }
    }

    /// Deletes the job list and the recorded media. Both lived under
    /// `Application Support/BannerTV/` and were never exposed through the Files app.
    private nonisolated static func removeRecordingFiles() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let root = support.appendingPathComponent("BannerTV", isDirectory: true)
        try? fileManager.removeItem(at: root.appendingPathComponent("recordings.json"))
        try? fileManager.removeItem(at: root.appendingPathComponent("Recordings", isDirectory: true))
    }
}
