import Foundation

// MARK: - Filter model

/// User-selectable filters for the Live TV channel list.
struct ChannelFilter: Equatable {
    var favoritesOnly = false
    var playlistIDs: Set<UUID> = []
    var groups: Set<String> = []
    var languages: Set<String> = []      // StreamLanguage.code values
    var categories: Set<ChannelCategory> = []
    var qualities: Set<StreamQuality> = []

    var isActive: Bool { activeCount > 0 }

    /// Number of filter dimensions currently constraining the list.
    var activeCount: Int {
        var count = 0
        if favoritesOnly { count += 1 }
        if !playlistIDs.isEmpty { count += 1 }
        if !groups.isEmpty { count += 1 }
        if !languages.isEmpty { count += 1 }
        if !categories.isEmpty { count += 1 }
        if !qualities.isEmpty { count += 1 }
        return count
    }
}

/// Stream quality detected from tags in a channel name ("4K", "FHD", "HD", "SD").
enum StreamQuality: String, CaseIterable, Identifiable {
    case uhd = "4K"
    case fhd = "FHD"
    case hd = "HD"
    case sd = "SD"

    var id: String { rawValue }

    /// Whole-word tokens that mark this quality in a channel name.
    nonisolated var tokens: Set<String> {
        switch self {
        case .uhd: return ["4k", "uhd", "2160p"]
        case .fhd: return ["fhd", "1080p", "1080"]
        case .hd: return ["hd", "720p", "720"]
        case .sd: return ["sd", "480p", "576p"]
        }
    }
}

enum ChannelCategory: String, CaseIterable, Identifiable {
    case sports = "Sports"
    case news = "News"
    case entertainment = "Entertainment"
    case movies = "Movies"
    case series = "Series"
    case kids = "Kids"
    case gameShows = "Game Shows"
    case music = "Music"
    case documentary = "Documentary"
    case lifestyle = "Lifestyle"
    case international = "International"
    case radio = "Radio"
    case adult = "Adult"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sports: return "sportscourt.fill"
        case .news: return "newspaper.fill"
        case .entertainment: return "sparkles.tv.fill"
        case .movies: return "movieclapper.fill"
        case .series: return "rectangle.stack.fill"
        case .kids: return "figure.and.child.holdinghands"
        case .gameShows: return "questionmark.bubble.fill"
        case .music: return "music.note.tv.fill"
        case .documentary: return "doc.text.image.fill"
        case .lifestyle: return "house.fill"
        case .international: return "globe"
        case .radio: return "radio.fill"
        case .adult: return "exclamationmark.shield.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Filtering algorithm

/// Filters playlist channels by search text plus the AND-combination of the
/// selected filter dimensions; within one dimension, selections are OR-ed
/// (e.g. picking English and Spanish keeps channels tagged with either).
nonisolated enum ChannelFilterEngine {

    static func apply(_ filter: ChannelFilter,
                      query: String,
                      to channels: [Channel],
                      favoriteChannelIDs: Set<String>) -> [Channel] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channel in
            if filter.favoritesOnly && !favoriteChannelIDs.contains(channel.id) {
                return false
            }
            if !filter.playlistIDs.isEmpty && !filter.playlistIDs.contains(channel.playlistID) {
                return false
            }
            if !filter.groups.isEmpty && !filter.groups.contains(groupName(for: channel)) {
                return false
            }
            if !filter.languages.isEmpty,
               SourceMatcher.languageTags(in: channel.name).isDisjoint(with: filter.languages) {
                return false
            }
            if !filter.categories.isEmpty && filter.categories.isDisjoint(with: categories(for: channel)) {
                return false
            }
            if !filter.qualities.isEmpty {
                guard let quality = quality(of: channel), filter.qualities.contains(quality) else {
                    return false
                }
            }
            if !trimmedQuery.isEmpty,
               !(channel.name + " " + (channel.group ?? "") + " " + channel.playlistName)
                    .localizedCaseInsensitiveContains(trimmedQuery) {
                return false
            }
            return true
        }
    }

    /// The section/category a channel belongs to (playlist group with fallback).
    static func groupName(for channel: Channel) -> String {
        channel.group?.isEmpty == false ? channel.group! : channel.playlistName
    }

    static func categories(for channel: Channel) -> Set<ChannelCategory> {
        let text = normalized([channel.group ?? "", channel.name, channel.playlistName].joined(separator: " "))
        let tokens = Set(text.split(separator: " ").map(String.init))
        var matches: Set<ChannelCategory> = []
        for category in ChannelCategory.allCases where category != .other {
            if categoryKeywords[category]?.contains(where: { keyword in
                keyword.contains(" ") ? text.contains(keyword) : tokens.contains(keyword)
            }) == true {
                matches.insert(category)
            }
        }
        return matches.isEmpty ? [.other] : matches
    }

    /// Detects the stream quality from whole-word tokens in the channel name.
    /// Checked sharpest-first so a "UHD 4K HD" channel counts as 4K.
    static func quality(of channel: Channel) -> StreamQuality? {
        let cleaned = String(channel.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        let tokens = Set(cleaned.split(separator: " ").map(String.init))
        return StreamQuality.allCases.first { !$0.tokens.isDisjoint(with: tokens) }
    }

    private static func normalized(_ input: String) -> String {
        String(input.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ").joined(separator: " "))
    }

    private static let categoryKeywords: [ChannelCategory: Set<String>] = [
        .sports: ["sports", "sport", "espn", "fox sports", "fs1", "fs2", "nba", "nfl", "mlb", "nhl", "pga", "golf", "soccer", "football", "tennis", "racing", "f1"],
        .news: ["news", "cnn", "msnbc", "fox news", "bbc", "sky news", "cnbc", "bloomberg", "al jazeera", "cbc news", "ctv news", "global news", "weather"],
        .entertainment: ["entertainment", "general", "variety", "comedy", "drama", "bravo", "e", "tbs", "tnt", "usa", "fx", "amc", "paramount"],
        .movies: ["movie", "movies", "cinema", "film", "films", "hbo", "showtime", "starz", "cinemax", "mgm", "hallmark"],
        .series: ["series", "shows", "episodes", "box sets", "vod series", "tv series"],
        .kids: ["kids", "children", "cartoon", "disney", "nick", "nickelodeon", "boomerang", "pbs kids", "baby"],
        .gameShows: ["game show", "game shows", "gameshow", "gameshows", "gsn", "family feud", "price is right", "jeopardy", "wheel of fortune", "deal or no deal"],
        .music: ["music", "mtv", "vh1", "vevo", "cmc", "cmt", "radio music"],
        .documentary: ["documentary", "docs", "history", "discovery", "national geographic", "nat geo", "science", "smithsonian", "animal planet"],
        .lifestyle: ["lifestyle", "food", "cooking", "travel", "home", "hgtv", "tlc", "diy", "fashion", "health", "fitness"],
        .international: ["international", "world", "latino", "arabic", "asian", "europe", "uk", "canada", "france", "germany", "italy", "spain", "portugal", "india"],
        .radio: ["radio", "fm", "am radio", "audio"],
        .adult: ["adult", "xxx", "18", "playboy"]
    ]

    /// The filter options actually present in a channel list, so the filter
    /// sheet only offers choices that do something.
    static func availableOptions(in channels: [Channel]) -> ChannelFilterOptions {
        var groups: Set<String> = []
        var languages: Set<String> = []
        var detectedCategories: Set<ChannelCategory> = []
        var qualities: Set<StreamQuality> = []
        for channel in channels {
            groups.insert(groupName(for: channel))
            languages.formUnion(SourceMatcher.languageTags(in: channel.name))
            detectedCategories.formUnion(categories(for: channel))
            if let quality = quality(of: channel) { qualities.insert(quality) }
        }
        return ChannelFilterOptions(
            groups: groups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            languages: StreamLanguage.all.filter { languages.contains($0.code) },
            categories: ChannelCategory.allCases.filter { detectedCategories.contains($0) },
            qualities: StreamQuality.allCases.filter { qualities.contains($0) }
        )
    }
}

/// Distinct values offered by the filter sheet, derived from the loaded channels.
struct ChannelFilterOptions: Equatable {
    var groups: [String] = []
    var languages: [StreamLanguage] = []
    var categories: [ChannelCategory] = []
    var qualities: [StreamQuality] = []
}
