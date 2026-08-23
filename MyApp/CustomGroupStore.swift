import Foundation
import SwiftUI
import Combine

/// Manages user-created channel groups that can contain channels from any provider.
/// Groups and their channel-ID lists are persisted to UserDefaults.
@MainActor
final class CustomGroupStore: ObservableObject {

    @Published private(set) var groups: [CustomGroup] = []

    private let defaultsKey = "stadiatv.customgroups.v1"

    init() { load() }

    // MARK: - Group CRUD

    @discardableResult
    func createGroup(named name: String) -> String {
        var group = CustomGroup(name: name)
        group.sortOrder = groups.count
        groups.append(group)
        persist()
        return group.id
    }

    func renameGroup(_ id: String, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        persist()
    }

    func deleteGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        persist()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        for i in groups.indices { groups[i].sortOrder = i }
        persist()
    }

    // MARK: - Channel membership

    func addChannel(_ channelID: String, to groupID: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }),
              !groups[idx].channelIDs.contains(channelID) else { return }
        groups[idx].channelIDs.append(channelID)
        persist()
    }

    func removeChannel(_ channelID: String, from groupID: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].channelIDs.removeAll { $0 == channelID }
        persist()
    }

    func moveChannels(in groupID: String, from source: IndexSet, to destination: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].channelIDs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func groupsContaining(_ channelID: String) -> [CustomGroup] {
        groups.filter { $0.channelIDs.contains(channelID) }
    }

    func contains(channelID: String, in groupID: String) -> Bool {
        groups.first(where: { $0.id == groupID })?.channelIDs.contains(channelID) == true
    }

    // MARK: - Persistence

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomGroup].self, from: data)
        else { return }
        groups = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
