import Foundation
import Compression
import Combine

// MARK: - Gzip helper

private extension Data {
    /// Attempts to decompress gzip data. Returns self unchanged if not gzip or decompression fails.
    func tryGunzip() -> Data {
        guard count > 10, self[0] == 0x1f, self[1] == 0x8b else { return self }

        var offset = 10
        if count > 3 {
            let flags = self[3]
            if flags & 0x04 != 0, count > offset + 1 {
                let xLen = Int(self[offset]) | (Int(self[offset + 1]) << 8)
                offset += 2 + xLen
            }
            if flags & 0x08 != 0 { while offset < count && self[offset] != 0 { offset += 1 }; offset += 1 }
            if flags & 0x10 != 0 { while offset < count && self[offset] != 0 { offset += 1 }; offset += 1 }
            if flags & 0x02 != 0 { offset += 2 }
        }
        guard offset < count - 8 else { return self }

        // Extract raw DEFLATE bytes and prepend minimal zlib header for the Compression framework
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(self[offset..<(count - 8)])

        let destCapacity = Swift.max(count * 10, 8 * 1024 * 1024)
        var dest = Data(repeating: 0, count: destCapacity)
        let written = dest.withUnsafeMutableBytes { dPtr in
            wrapped.withUnsafeBytes { sPtr in
                guard let d = dPtr.baseAddress, let s = sPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    d.assumingMemoryBound(to: UInt8.self), destCapacity,
                    s.assumingMemoryBound(to: UInt8.self), wrapped.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return self }
        dest.count = written
        return dest
    }
}

// MARK: - EPG Repository

/// Central manager for all EPG data. Downloads, parses, matches, and caches guide data.
@MainActor
final class EPGRepository: ObservableObject {

    @Published private(set) var canonicalChannels: [CanonicalChannel] = []
    @Published private(set) var refreshState: EPGRefreshState = .idle
    @Published private(set) var lastUpdated: Date?

    // Programme index: canonicalChannelId -> [EPGProgramme] sorted by start
    private var programmeIndex: [String: [EPGProgramme]] = [:]
    // EPG channel id -> canonical channel id
    private var epgToCanonical: [String: String] = [:]

    private var config: CuratedGuideConfig?
    private var normalizer: ChannelNormalizer?
    private var matcher: CanonicalChannelMatcher?
    private var currentIPTVChannels: [Channel] = []
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    // Cache keys
    private let channelCacheKey = "epg.canonical.channels.v1"
    private let programmeCacheKey = "epg.programmes.v1"
    private let lastUpdatedKey = "epg.lastUpdated.v1"

    private let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StadiaTV_EPG", isDirectory: true)
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadCachedState()
        loadCuratedConfig()
    }

    // MARK: - Setup

    private func loadCuratedConfig() {
        guard let cfg = CuratedGuideConfig.load() else { return }
        config = cfg
        normalizer = ChannelNormalizer(config: cfg)
        matcher = CanonicalChannelMatcher(config: cfg, normalizer: normalizer!)
    }

    /// Called when IPTV channels are available. Rebuilds canonical lineup and refreshes EPG if needed.
    func setupWithChannels(_ channels: [Channel]) {
        guard !channels.isEmpty else { return }
        currentIPTVChannels = channels

        guard let matcher, let normalizer else { return }

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Load IPTV-org indexes if not yet loaded, and pass them to the matcher
            let iptvOrg = IPTVOrgMetadataService.shared
            let iptvIndexes = await iptvOrg.indexes
            if iptvIndexes.isLoaded {
                matcher.updateIPTVOrgIndexes(iptvIndexes)
            }

            let streams = channels.map { ch -> ChannelStream in
                let normName = normalizer.normalize(ch.name)
                let countryHint = normalizer.extractCountryHint(from: ch.name)
                var stream = ChannelStream(
                    id: ch.id,
                    providerChannelId: ch.id,
                    originalName: ch.name,
                    normalizedName: normName,
                    streamURL: ch.streamURL,
                    tvgId: nil,
                    tvgName: ch.name,
                    tvgLogoURL: ch.logoURL,
                    groupTitle: ch.group,
                    resolution: StreamResolution.detect(from: ch.name),
                    playlistID: ch.playlistID,
                    playlistName: ch.playlistName
                )
                stream.countryHint = countryHint
                return stream
            }

            // Filter hidden channels
            let visible = streams.filter { !normalizer.shouldHide(channelName: $0.originalName) }

            // Match to canonical
            let matchResults = visible.compactMap { matcher.match($0) }
            var canonicals = matcher.buildCanonicalChannels(from: matchResults)

            // Resolve logos using available metadata
            if iptvIndexes.isLoaded {
                let resolver = ChannelLogoResolver(iptvOrg: iptvOrg)
                let logos = await resolver.resolveAll(channels: canonicals)
                for i in canonicals.indices {
                    if let resolved = logos[canonicals[i].id] {
                        canonicals[i].resolvedLogo = resolved
                        if let url = resolved.url {
                            canonicals[i].logoURL = url
                        }
                    }
                }
            }

            self.canonicalChannels = canonicals
            await self.refreshIfNeeded()
        }
    }

    /// Load IPTV-org metadata and rebuild the canonical lineup with enriched logos.
    func loadIPTVOrgMetadata(channelsURL: URL, logosURL: URL) async {
        guard let normalizer else { return }
        let iptvOrg = IPTVOrgMetadataService.shared
        do {
            try await iptvOrg.loadFromFiles(channelsURL: channelsURL, logosURL: logosURL,
                                             normalizer: normalizer)
            // Re-run matching with enriched indexes if we already have channels
            if !currentIPTVChannels.isEmpty {
                setupWithChannels(currentIPTVChannels)
            }
        } catch {
            // Non-fatal: guide continues without IPTV-org enrichment
        }
    }

    // MARK: - Refresh

    func refreshIfNeeded() async {
        let staleness: TimeInterval = 6 * 3600
        if let last = lastUpdated, Date().timeIntervalSince(last) < staleness { return }
        await forceRefresh()
    }

    func forceRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshState = .refreshing
        defer { isRefreshing = false }

        let activeCategoryIds = Set(canonicalChannels.map(\.categoryId))
        let sources = EPGSourceRegistry.sources(for: activeCategoryIds)

        var allEPGChannels: [EPGChannel] = []
        var allProgrammes: [EPGProgramme] = []

        await withTaskGroup(of: EPGParseResult?.self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    await self?.downloadAndParse(source: source)
                }
            }
            for await result in group {
                guard let result else { continue }
                allEPGChannels.append(contentsOf: result.channels)
                allProgrammes.append(contentsOf: result.programmes)
            }
        }

        // Match EPG channels to canonical channels
        matchEPGChannels(allEPGChannels)

        // Build programme index
        buildProgrammeIndex(from: allProgrammes)

        lastUpdated = Date()
        persistState()

        await MainActor.run {
            self.refreshState = .idle
            self.objectWillChange.send()
        }
    }

    // MARK: - Download + Parse

    private func downloadAndParse(source: EPGSource) async -> EPGParseResult? {
        let cacheFile = cacheDir.appendingPathComponent("\(source.id).xml")

        // Check disk cache freshness
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < source.cacheTTL,
           let data = try? Data(contentsOf: cacheFile) {
            return parseXML(data: data, source: source)
        }

        // Download
        do {
            let (data, _) = try await session.data(from: source.url)
            let decompressed = data.tryGunzip()
            try decompressed.write(to: cacheFile)
            return parseXML(data: decompressed, source: source)
        } catch {
            // Network failure: try cached file even if stale
            if let data = try? Data(contentsOf: cacheFile) {
                return parseXML(data: data, source: source)
            }
            return nil
        }
    }

    private func parseXML(data: Data, source: EPGSource) -> EPGParseResult {
        let parser = EPGXMLParser(sourceId: source.id, priority: source.priority)
        return parser.parse(data: data)
    }

    // MARK: - EPG Channel Matching

    private func matchEPGChannels(_ epgChannels: [EPGChannel]) {
        guard let normalizer else { return }
        var newMapping: [String: String] = [:]  // epgChannelId -> canonicalChannelId

        // Build lookup from canonical channel's epg_id, aliases, normalized names
        var aliasToCanon: [String: String] = [:]
        for ch in canonicalChannels {
            let normName = normalizer.normalize(ch.name).lowercased()
            aliasToCanon[normName] = ch.id
            if let network = ch.network {
                aliasToCanon[network.lowercased()] = ch.id
            }
        }

        // Also build a lookup from the curated config's aliases
        if let config {
            for curatedCh in config.channels {
                for alias in curatedCh.aliases {
                    let norm = normalizer.normalize(alias).lowercased()
                    aliasToCanon[norm] = curatedCh.key
                }
            }
        }

        for epgCh in epgChannels {
            // Try each display name to find a canonical match
            var matched: String?
            for displayName in epgCh.displayNames {
                let norm = normalizer.normalize(displayName).lowercased()
                if let canonId = aliasToCanon[norm] {
                    matched = canonId
                    break
                }
            }
            if let canonId = matched {
                newMapping[epgCh.id] = canonId
            }
        }

        epgToCanonical = newMapping

        // Update canonical channels with their EPG ids
        var updated = canonicalChannels
        for i in updated.indices {
            // Find the first EPG channel that maps to this canonical channel
            if let epgId = newMapping.first(where: { $0.value == updated[i].id })?.key {
                updated[i].epgChannelId = epgId
            }
        }
        Task { @MainActor in self.canonicalChannels = updated }
    }

    // MARK: - Programme Index

    private func buildProgrammeIndex(from programmes: [EPGProgramme]) {
        let now = Date()
        let futureLimit = now.addingTimeInterval(48 * 3600)  // keep 48h of future data
        let pastLimit = now.addingTimeInterval(-2 * 3600)    // keep 2h of past data

        var index: [String: [EPGProgramme]] = [:]

        for var prog in programmes {
            guard prog.isValid, prog.start >= pastLimit, prog.end <= futureLimit else { continue }

            // Map EPG channel to canonical
            if let canonId = epgToCanonical[prog.epgChannelId] {
                prog.canonicalChannelId = canonId
                index[canonId, default: []].append(prog)
            }
        }

        // Sort each channel's programmes by start time, deduplicate overlaps
        for key in index.keys {
            index[key] = deduplicate(index[key]!.sorted { $0.start < $1.start })
        }

        programmeIndex = index
    }

    private func deduplicate(_ sorted: [EPGProgramme]) -> [EPGProgramme] {
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

    // MARK: - Query Interface

    func currentProgramme(for channelId: String, at date: Date = Date()) -> EPGProgramme? {
        programmeIndex[channelId]?.first { $0.isOnNow(at: date) }
    }

    func nextProgramme(for channelId: String, after date: Date = Date()) -> EPGProgramme? {
        programmeIndex[channelId]?.first { $0.start > date }
    }

    func programmes(for channelId: String, from: Date, to: Date) -> [EPGProgramme] {
        programmeIndex[channelId]?.filter { $0.end > from && $0.start < to } ?? []
    }

    func hasProgrammes(for channelId: String) -> Bool {
        !(programmeIndex[channelId]?.isEmpty ?? true)
    }

    // MARK: - Persistence

    private func loadCachedState() {
        if let ts = UserDefaults.standard.object(forKey: lastUpdatedKey) as? Date {
            lastUpdated = ts
        }
    }

    private func persistState() {
        UserDefaults.standard.set(lastUpdated, forKey: lastUpdatedKey)
    }

    // MARK: - Debug info

    var diagnostics: String {
        """
        Canonical channels: \(canonicalChannels.count)
        With EPG mapping: \(canonicalChannels.filter { $0.epgChannelId != nil }.count)
        EPG channel mappings: \(epgToCanonical.count)
        Indexed channel schedules: \(programmeIndex.count)
        Last updated: \(lastUpdated?.formatted() ?? "never")
        """
    }
}
