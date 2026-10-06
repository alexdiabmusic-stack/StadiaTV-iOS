import Foundation

/// Identifies playlist channels that are sports channels, for CarPlay's Listen tab and
/// Siri/App Intents channel suggestions. Reuses `StreamLinker`'s curated sports-network
/// name table and `League.keywords` instead of building a separate classifier — the same
/// vocabulary the broadcast matcher already uses.
nonisolated enum BannerSportsChannelClassifier {
    static func isSportsChannel(_ channel: Channel) -> Bool {
        if let group = channel.group, group.localizedCaseInsensitiveContains("sport") { return true }
        let normalized = channel.name.lowercased().filter(\.isLetter)
        if StreamLinker.networkKeys.contains(where: { normalized.contains($0) }) { return true }
        return League.all.contains { league in league.keywords.contains { normalized.contains($0.filter(\.isLetter)) } }
    }
}
