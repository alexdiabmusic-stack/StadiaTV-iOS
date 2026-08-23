import Foundation
import CryptoKit
import Combine

/// Manages parental controls: PIN verification (SHA-256 hash — never plaintext),
/// blocked channel and group lists, and a timed temporary-unlock bypass.
///
/// Security contract:
/// - The PIN is stored only as a SHA-256 hex digest in UserDefaults.
/// - Blocked IDs and the enabled flag are persisted to UserDefaults (local device only).
/// - Temporary unlock is held in memory only and does not survive an app restart.
@MainActor
final class ParentalControlStore: ObservableObject {
    static let shared = ParentalControlStore()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var blockedChannelIDs: Set<String> = []
    @Published private(set) var blockedGroupTitles: Set<String> = []
    @Published private(set) var requirePINForSettings: Bool = false
    /// Non-nil while a temporary unlock is active; nil otherwise.
    @Published private(set) var temporaryUnlockExpiry: Date?

    private enum Keys {
        static let pinHash          = "stadiatv.pc.pinHash.v1"
        static let enabled          = "stadiatv.pc.enabled.v1"
        static let blockedChannels  = "stadiatv.pc.blockedChannels.v1"
        static let blockedGroups    = "stadiatv.pc.blockedGroups.v1"
        static let pinForSettings   = "stadiatv.pc.pinForSettings.v1"
    }

    private init() {
        let d = UserDefaults.standard
        isEnabled             = d.bool(forKey: Keys.enabled)
        blockedChannelIDs     = Set(d.stringArray(forKey: Keys.blockedChannels) ?? [])
        blockedGroupTitles    = Set(d.stringArray(forKey: Keys.blockedGroups) ?? [])
        requirePINForSettings = d.bool(forKey: Keys.pinForSettings)
    }

    // MARK: - PIN management

    var hasPIN: Bool { UserDefaults.standard.string(forKey: Keys.pinHash) != nil }

    /// Stores a SHA-256 digest of `pin`. The raw PIN is never persisted.
    func setPIN(_ pin: String) {
        UserDefaults.standard.set(sha256(pin), forKey: Keys.pinHash)
    }

    func verifyPIN(_ pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: Keys.pinHash) else { return false }
        return sha256(pin) == stored
    }

    /// Removes the PIN hash and disables parental controls entirely.
    func clearPIN() {
        UserDefaults.standard.removeObject(forKey: Keys.pinHash)
        isEnabled = false
        persist()
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Enable / disable

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        persist()
    }

    func setRequirePINForSettings(_ required: Bool) {
        requirePINForSettings = required
        persist()
    }

    // MARK: - Restriction checks

    /// Returns true when the channel should be blocked for the current session.
    /// A temporary unlock bypasses this check entirely.
    func isRestricted(_ channel: Channel) -> Bool {
        guard isEnabled, !isTemporarilyUnlocked else { return false }
        if blockedChannelIDs.contains(channel.id) { return true }
        if let group = channel.group, blockedGroupTitles.contains(group) { return true }
        return false
    }

    func isChannelBlocked(id: String) -> Bool { blockedChannelIDs.contains(id) }
    func isGroupBlocked(title: String) -> Bool { blockedGroupTitles.contains(title) }

    // MARK: - Block list management

    func toggleBlockChannel(id: String) {
        if blockedChannelIDs.contains(id) { blockedChannelIDs.remove(id) }
        else { blockedChannelIDs.insert(id) }
        persist()
    }

    func toggleBlockGroup(title: String) {
        if blockedGroupTitles.contains(title) { blockedGroupTitles.remove(title) }
        else { blockedGroupTitles.insert(title) }
        persist()
    }

    // MARK: - Temporary unlock

    var isTemporarilyUnlocked: Bool {
        guard let expiry = temporaryUnlockExpiry else { return false }
        if expiry > Date() { return true }
        temporaryUnlockExpiry = nil
        return false
    }

    var temporaryUnlockRemainingMinutes: Int? {
        guard let expiry = temporaryUnlockExpiry, expiry > Date() else { return nil }
        return max(1, Int(ceil(expiry.timeIntervalSinceNow / 60)))
    }

    func grantTemporaryUnlock(minutes: Int = 30) {
        temporaryUnlockExpiry = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func revokeTemporaryUnlock() {
        temporaryUnlockExpiry = nil
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(isEnabled,                 forKey: Keys.enabled)
        d.set(Array(blockedChannelIDs),  forKey: Keys.blockedChannels)
        d.set(Array(blockedGroupTitles), forKey: Keys.blockedGroups)
        d.set(requirePINForSettings,     forKey: Keys.pinForSettings)
    }
}
