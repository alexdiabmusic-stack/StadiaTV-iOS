import Foundation

// Adapters from the app's own types to StreamLinker's input model (see MatchLinker/README.md,
// "Integration checklist"). Every declaration here is `nonisolated`, like StreamLinker.swift
// itself, so building the linker never has to hop onto the main actor.

nonisolated enum StreamLinkerAdapters {

    /// `false` for every league the app carries today (all club competitions). Flip this
    /// per-league when a national-team competition (e.g. UEFA Nations League) is added —
    /// see MatchLinker/PROMPTS.md, Prompt 7.
    static func isNational(_ league: League) -> Bool { false }

    static func team(_ side: TeamSide) -> LinkerTeam {
        // `short`/`nick` must be real nicknames ("Panthers", "Red Sox"), never bare
        // abbreviations — abbreviation-only aliases are exactly what produced junk
        // candidates like "CAR" matching "CAR CHASE" in the old matcher. TeamSide has no
        // separate nickname/city field yet, so only pass `short` when it reads like a
        // nickname (multi-word, or a single word clearly longer than an abbreviation).
        let short = side.shortName
        let looksLikeNickname = short.contains(" ") || short.count > 5
        return LinkerTeam(
            name: side.displayName,
            short: looksLikeNickname ? short : nil,
            nick: nil,
            city: nil,
            abbr: side.abbreviation
        )
    }

    static func event(_ match: Match) -> LinkerEvent {
        LinkerEvent(
            id: match.id,
            league: match.league.path,
            kickoff: match.date,
            home: team(match.home),
            away: team(match.away),
            broadcasts: match.broadcasts,
            isNational: isNational(match.league)
        )
    }

    /// `Channel.id` is only unique within one playlist — two playlists can legitimately reuse
    /// the same provider stream number. Scope it by playlist before handing it to the linker,
    /// which treats stream ids as opaque, so results always map back to the right `Channel`.
    static func streamID(_ channel: Channel) -> String { "\(channel.playlistID.uuidString)|\(channel.id)" }

    /// Repairs the provider's mid-word "US ★" badge corruption (e.g. "MUS ★kingum" ->
    /// "Muskingum") before the name reaches the linker — see MatchLinker/PROMPTS.md, Prompt 2
    /// step 7. Every other consumer already runs channel names through this same repair.
    static func stream(_ channel: Channel) -> LinkerStream {
        LinkerStream(
            id: streamID(channel),
            name: EventChannelNameParser.repairBadgeCorruption(channel.name),
            category: channel.group ?? "",
            guideID: channel.tvgId
        )
    }

    /// Maps a `LinkTier` to the closest existing `StreamEvidenceCategory` so the linker's
    /// output can drive the app's existing evidence badges without every consumer needing to
    /// learn a second vocabulary. `RankedSource.isConfirmed` uses `linkerConfidence` (the
    /// tier's real threshold) rather than this mapping to decide confirmed vs. possible.
    static func evidenceCategory(for tier: LinkTier) -> StreamEvidenceCategory? {
        switch tier {
        case .liveListing, .listingByDescription: return .guideListsMatch
        case .teamChannel: return .teamNameMatch
        case .eventChannel: return .eventTitleMatch
        case .likelyRights: return .broadcastRightsMatch
        case .coverage: return .networkNameMatch
        }
    }

    /// Expands one `LinkedFeed` into one `RankedSource` per mirror (best quality first, per
    /// `feed.streamIDs`), all sharing the feed's tier/confidence/evidence. `channelByID` must be
    /// keyed by `streamID(_:)`; mirrors whose channel isn't present (stale lookup) are skipped.
    static func rankedSources(for feed: LinkedFeed, channelByID: [String: Channel]) -> [RankedSource] {
        var out: [RankedSource] = []
        out.reserveCapacity(feed.streamIDs.count)
        for (offset, streamID) in feed.streamIDs.enumerated() {
            guard let channel = channelByID[streamID] else { continue }
            var source = RankedSource(channel: channel, score: Int(feed.confidence * 100) - offset)
            if let category = evidenceCategory(for: feed.tier) { source.evidenceCategories = [category] }
            source.linkerTierRaw = feed.tier.rawValue
            source.linkerConfidence = feed.confidence
            source.linkerLabel = feed.label
            source.linkerEvidence = feed.evidence
            source.linkerFamily = feed.family
            out.append(source)
        }
        return out
    }

    /// All mirrors of every family in `families`, families ordered best-confidence-first
    /// (as returned by `StreamLinker.link` / `groupedByFamily`), mirrors within a family
    /// ordered best-quality-first.
    static func rankedSources(for families: [LinkedFamily], channelByID: [String: Channel]) -> [RankedSource] {
        families.flatMap { family in family.members.flatMap { rankedSources(for: $0, channelByID: channelByID) } }
    }

    static func programme(_ epg: EPGProgramme) -> LinkerProgramme {
        LinkerProgramme(
            guideID: epg.epgChannelId,
            start: epg.start,
            end: epg.end,
            title: epg.title,
            desc: epg.description.map { String($0.prefix(300)) }
        )
    }
}
