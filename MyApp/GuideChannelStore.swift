import Foundation
import SwiftUI
import Combine

// MARK: - Guide Mode

enum GuideMode: String, Equatable {
    case myGuide = "myGuide"
    case allChannels = "allChannels"
}

// MARK: - Guide Channel Store

/// Persists the user's "My Guide" channel selections, display mode, and per-channel EPG offsets.
@MainActor
final class GuideChannelStore: ObservableObject {
    @Published private(set) var selectedChannelIDs: Set<String> = []
    @Published private(set) var hasConfigured: Bool = false
    @Published private(set) var guideMode: GuideMode = .myGuide
    /// Per-canonical-channel EPG offset in minutes. Positive = EPG is behind (stream is ahead).
    @Published private(set) var epgOffsets: [String: Int] = [:]

    private let selectedKey = "guide.myChannels.v2"
    private let configuredKey = "guide.hasConfigured.v1"
    private let modeKey = "guide.mode.v1"
    private let epgOffsetsKey = "guide.epgoffsets.v1"

    init() { load() }

    var selectedCount: Int { selectedChannelIDs.count }

    func isSelected(_ channelId: String) -> Bool {
        selectedChannelIDs.contains(channelId)
    }

    func toggle(_ channelId: String) {
        if selectedChannelIDs.contains(channelId) {
            selectedChannelIDs.remove(channelId)
        } else {
            selectedChannelIDs.insert(channelId)
        }
        persist()
    }

    func selectAll(from channelIds: [String]) {
        channelIds.forEach { selectedChannelIDs.insert($0) }
        persist()
    }

    func deselectAll(from channelIds: [String]) {
        channelIds.forEach { selectedChannelIDs.remove($0) }
        persist()
    }

    func setChannels(_ ids: Set<String>) {
        selectedChannelIDs = ids
        persist()
    }

    func markConfigured() {
        hasConfigured = true
        UserDefaults.standard.set(true, forKey: configuredKey)
    }

    func setGuideMode(_ mode: GuideMode) {
        guideMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    func resetConfiguration() {
        hasConfigured = false
        selectedChannelIDs = []
        UserDefaults.standard.removeObject(forKey: selectedKey)
        UserDefaults.standard.set(false, forKey: configuredKey)
    }

    // MARK: - EPG Offsets

    func epgOffset(for channelId: String) -> Int {
        epgOffsets[channelId] ?? 0
    }

    func setEPGOffset(_ offset: Int, for channelId: String) {
        if offset == 0 {
            epgOffsets.removeValue(forKey: channelId)
        } else {
            epgOffsets[channelId] = offset
        }
        persistOffsets()
    }

    // MARK: - Persistence

    private func load() {
        hasConfigured = UserDefaults.standard.bool(forKey: configuredKey)
        if let raw = UserDefaults.standard.string(forKey: modeKey),
           let mode = GuideMode(rawValue: raw) {
            guideMode = mode
        }
        if let data = UserDefaults.standard.data(forKey: selectedKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            selectedChannelIDs = ids
        }
        if let data = UserDefaults.standard.data(forKey: epgOffsetsKey),
           let offsets = try? JSONDecoder().decode([String: Int].self, from: data) {
            epgOffsets = offsets
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(selectedChannelIDs) else { return }
        UserDefaults.standard.set(data, forKey: selectedKey)
    }

    private func persistOffsets() {
        guard let data = try? JSONEncoder().encode(epgOffsets) else { return }
        UserDefaults.standard.set(data, forKey: epgOffsetsKey)
    }
}
