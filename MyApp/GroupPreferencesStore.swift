import Foundation
import Combine

/// Persists per-provider-group user preferences: hide, rename, custom sort order.
/// Group ID format: "\(providerUUID)|\(groupTitle)"
@MainActor
final class GroupPreferencesStore: ObservableObject {

    @Published private(set) var preferences: [String: GroupPreferences] = [:]

    private let defaultsKey = "stadiatv.groupprefs.v1"

    init() { load() }

    // MARK: - Read

    func prefs(for groupID: String) -> GroupPreferences {
        preferences[groupID] ?? GroupPreferences(groupID: groupID)
    }

    func isHidden(_ groupID: String) -> Bool {
        preferences[groupID]?.isHidden == true
    }

    func customName(for groupID: String) -> String? {
        preferences[groupID]?.customName
    }

    func sortOrder(for groupID: String) -> Int? {
        preferences[groupID]?.sortOrder
    }

    // MARK: - Write

    func setHidden(_ hidden: Bool, for groupID: String) {
        var p = prefs(for: groupID)
        p.isHidden = hidden
        save(p)
    }

    func setCustomName(_ name: String?, for groupID: String) {
        var p = prefs(for: groupID)
        p.customName = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty()
        save(p)
    }

    func setSortOrder(_ order: Int?, for groupID: String) {
        var p = prefs(for: groupID)
        p.sortOrder = order
        save(p)
    }

    // MARK: - Persistence

    private func save(_ p: GroupPreferences) {
        preferences[p.groupID] = p
        persist()
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: GroupPreferences].self, from: data)
        else { return }
        preferences = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
