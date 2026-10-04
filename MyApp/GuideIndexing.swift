import Foundation

// Pure pieces of the guide pipeline, kept apart from `EPGRepository` (which is main-actor
// bound) so they can run on a background task and be tested without the rest of the pipeline.

// MARK: - Custom (playlist-supplied) guide matching

/// How a playlist's own XMLTV channel ids are matched to its streams. Built once per lineup
/// import, off the main actor, from the streams that import already normalised.
nonisolated struct CustomEPGLookup: Sendable {
    /// Lowercased tvg-id → provider channel id.
    var tvgIdToProvider: [String: String] = [:]
    /// Lowercased normalised channel name → provider channel id.
    var nameToProvider: [String: String] = [:]
}

/// A custom-EPG channel resolved to one exact raw stream, plus the canonical group it belongs to.
nonisolated struct CustomEPGMatch: Sendable, Equatable {
    let canonicalChannelId: String
    let providerChannelId: String
}

nonisolated enum CustomEPGMatcher {
    /// Matches a playlist's own XMLTV channel entries to that same playlist's channels by tvg-id
    /// (the two are issued together by the provider, so this is exact), with a normalised
    /// display-name fallback for providers whose ids drift between files. Resolves to one specific
    /// raw stream rather than the canonical group as a whole, since a canonical channel can merge
    /// several mirrors that don't share content.
    static func match(
        _ epgChannels: [EPGChannel],
        lookup: CustomEPGLookup,
        channelToCanonical: [String: String],
        normalize: (String) -> String
    ) -> [String: CustomEPGMatch] {
        // IPTV names repeat heavily, and each normalisation is a dozen regex passes.
        var normalized: [String: String] = [:]
        func normalizedKey(_ name: String) -> String {
            if let cached = normalized[name] { return cached }
            let key = normalize(name).lowercased()
            normalized[name] = key
            return key
        }

        var mapping: [String: CustomEPGMatch] = [:]
        for epgCh in epgChannels {
            var providerId = lookup.tvgIdToProvider[epgCh.id.lowercased()]
            if providerId == nil {
                for displayName in epgCh.displayNames {
                    if let match = lookup.nameToProvider[normalizedKey(displayName)] {
                        providerId = match
                        break
                    }
                }
            }
            guard let providerId, let canonicalId = channelToCanonical[providerId] else { continue }
            mapping[epgCh.id] = CustomEPGMatch(canonicalChannelId: canonicalId, providerChannelId: providerId)
        }
        return mapping
    }
}

// MARK: - Per-channel schedules

nonisolated enum GuideProgrammeIndexing {

    /// Orders by start time and drops overlaps, preferring the lower `sourcePriority`.
    static func deduplicated(_ sorted: [EPGProgramme]) -> [EPGProgramme] {
        var result: [EPGProgramme] = []
        var cursor = Date.distantPast
        for prog in sorted {
            if prog.start >= cursor {
                result.append(prog)
                cursor = prog.end
            } else if prog.sourcePriority < (result.last?.sourcePriority ?? Int.max) {
                result[result.count - 1] = prog
                cursor = prog.end
            }
        }
        return result
    }

    /// One channel's schedule with `programmes` folded in: sorted by start and de-overlapped.
    static func merged(_ existing: [EPGProgramme], adding programmes: [EPGProgramme]) -> [EPGProgramme] {
        deduplicated((existing + programmes).sorted { $0.start < $1.start })
    }

    /// `index` without any programme that came from `sourceId`. A source that has just been
    /// downloaded again is the whole truth about itself, so what was indexed from it before
    /// (a previous refresh, or the durable store at launch) must not survive alongside it:
    /// where old and new overlap, `deduplicated` keeps whichever sorts first.
    static func removing(sourceId: String, from index: [String: [EPGProgramme]]) -> [String: [EPGProgramme]] {
        var result = index
        for (channelId, programmes) in index where programmes.contains(where: { $0.sourceId == sourceId }) {
            let kept = programmes.filter { $0.sourceId != sourceId }
            result[channelId] = kept.isEmpty ? nil : kept
        }
        return result
    }

    static func coverage(of programmes: [EPGProgramme], channelId: String) -> ProgrammeCoverage? {
        guard let first = programmes.first, let last = programmes.last else { return nil }
        return ProgrammeCoverage(channelId: channelId, earliestStart: first.start, latestEnd: last.end, programmeCount: programmes.count)
    }

    /// Rebuilds canonical-channel schedules from programmes read back from the durable store
    /// (which is keyed by guide id). `canonicalId` resolves a guide id; programmes it can't
    /// resolve are dropped.
    static func hydrated(from stored: [EPGProgramme], canonicalId: (String) -> String?) -> [String: [EPGProgramme]] {
        var resolved: [String: String?] = [:]
        var index: [String: [EPGProgramme]] = [:]
        for var prog in stored where prog.isValid {
            let canonical: String?
            if let cached = resolved[prog.epgChannelId] {
                canonical = cached
            } else {
                canonical = canonicalId(prog.epgChannelId)
                resolved[prog.epgChannelId] = canonical
            }
            guard let canonical else { continue }
            prog.canonicalChannelId = canonical
            index[canonical, default: []].append(prog)
        }
        return index.mapValues { deduplicated($0.sorted { $0.start < $1.start }) }
    }
}
