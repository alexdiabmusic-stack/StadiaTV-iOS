import Foundation

/// Browsing classification only. Event playback still requires StreamAvailabilityStore verification.
nonisolated enum BannerSportsChannelClassifier {
    static func isSportsChannel(_ channel: Channel) -> Bool {
        isSportsChannel(name: channel.name, group: channel.group)
    }

    static func isSportsChannel(name: String, group: String?) -> Bool {
        let tokens = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let excluded: Set<String> = ["news", "cnn", "cnbc", "msnbc", "parliament", "government",
                                     "cpac", "kids", "junior", "nickelodeon", "disney", "cartoon",
                                     "movies", "cinema", "hgtv", "food", "weather"]
        guard excluded.isDisjoint(with: tokens) else { return false }
        // General networks carry occasional games but are not dedicated sports channels.
        let general: Set<String> = ["abc", "cbs", "nbc", "fox", "tnt", "trutv", "cnbc",
                                    "usanetwork", "universo", "nbcuniverso", "univision", "telemundo"]
        let dedicated = StreamLinker.networkKeys.subtracting(general)
        let compact = tokens.joined()
        if tokens.contains(where: { dedicated.contains($0) }) { return true }
        if dedicated.contains(compact) { return true }
        if tokens.contains("sports") || tokens.contains("sport") { return true }
        // Categories are supporting evidence, never proof that a game is being broadcast.
        let categories = (group ?? "").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return categories.contains("sports") || categories.contains("sport")
    }
}
