import Foundation
import Compression
import Combine
import OSLog

// MARK: - Gzip helper

nonisolated private extension Data {
    /// Decompresses gzip data. Returns self unchanged if not gzip or decompression fails.
    /// Uses the gzip ISIZE footer field to allocate an exact-size destination buffer,
    /// avoiding the silent truncation that a fixed 10× heuristic can cause for large files.
    func tryGunzip() -> Data {
        guard count > 10, self[0] == 0x1f, self[1] == 0x8b else { return self }

        // Walk the variable-length gzip header to find the DEFLATE payload start.
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

        // ISIZE: last 4 bytes of the gzip file are the original size mod 2^32 (little-endian).
        // Accurate for files < 4 GB; EPG XML is always < 4 GB.
        let isize = Int(self[count - 4]) | (Int(self[count - 3]) << 8)
                  | (Int(self[count - 2]) << 16) | (Int(self[count - 1]) << 24)
        let destCapacity = isize > 0 ? isize + 512 : Swift.max(count * 20, 32 * 1024 * 1024)

        // COMPRESSION_ZLIB expects a 2-byte zlib header before the raw DEFLATE payload.
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(self[offset..<(count - 8)])

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
    /// Flat map from `providerChannelId` → canonical channel ID, rebuilt whenever `canonicalChannels` changes.
    /// Used by MatchDetailView and TVMatchDetailView so they don't rebuild the map on every ranking call.
    private(set) var channelToCanonicalMap: [String: String] = [:]
    /// Canonical channels keyed by ID, rebuilt alongside `channelToCanonicalMap`.
    private(set) var canonicalChannelsByID: [String: CanonicalChannel] = [:]
    private var fingerprintTask: Task<Void, Never>?
    /// Streams that passed the hide filter but matched no curated channel.
    /// Available for global event-to-stream matching so uncatalogued feeds are not silently dropped.
    @Published private(set) var unresolvedStreams: [ChannelStream] = []
    @Published private(set) var refreshState: EPGRefreshState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var importProgress = LiveTVImportProgress()
    @Published private(set) var importDiagnostics = LiveTVImportDiagnostics()

    // Programme index: canonicalChannelId -> [EPGProgramme] sorted by start
    private var programmeIndex: [String: [EPGProgramme]] = [:] {
        didSet { programmeRevision &+= 1 }
    }
    /// Bumped whenever guide data changes; lets views cache per-row layout.
    private(set) var programmeRevision = 0
    // EPG channel id -> canonical channel id
    private var epgToCanonical: [String: String] = [:]
    // Coverage range per canonical channel, rebuilt on every finalizeProgrammeIndex call
    private var coverageIndex: [String: ProgrammeCoverage] = [:]
    /// Guide ID (lowercased tvg-id) -> every raw provider channel ID that declares it.
    /// Replaces the old single-stream `EPGProgramme.scopedProviderChannelId`: a canonical
    /// channel can merge several mirrors, and a programme should confirm every one of
    /// them that actually shares its guide ID, not just whichever one a 1:1 map kept.
    private(set) var guideIdToProviderChannelIds: [String: Set<String>] = [:]

    private var config: CuratedGuideConfig?
    private var normalizer: ChannelNormalizer?
    private var matcher: CanonicalChannelMatcher?
    private var currentIPTVChannels: [Channel] = []
    private var refreshTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var epgpwPrefetchTasks: [String: Task<Void, Never>] = [:]
    private var customEPGURLs: [URL] = []

    /// Custom XML url provided by playlists.
    private var epgpwDiagnostics: [String: EPGPWFetchResult] = [:]
    private var isRefreshing = false
    private var importGeneration = UUID()
    private var lastChannelFingerprint: String?

    private let epgpwMappings = EPGPWMappingRepository()
    private lazy var epgpwProvider = EPGPWProvider(cacheDir: cacheDir)

    /// Fetches a provider channel's Xtream EPG data on demand — wired once at app
    /// startup (e.g. `epgRepository.xtreamEPGFetcher = playlistStore.fetchXtreamEPG`)
    /// since this repository has no direct PlaylistStore reference. `fullSchedule: true`
    /// requests the full multi-day table (`get_simple_data_table`, only for a row
    /// actually scrolled into view); `false` requests now/next only (`get_short_epg`).
    var xtreamEPGFetcher: ((_ providerChannelId: String, _ fullSchedule: Bool) async -> [EPGProgramme])?
    private var xtreamEPGTasks: Set<String> = []
    private let logger = Logger(subsystem: "BannerTV", category: "LiveTVImport")

    // Cache keys
    private let channelCacheKey = "epg.canonical.channels.v1"
    private let programmeCacheKey = "epg.programmes.v1"
    private let lastUpdatedKey = "epg.lastUpdated.v1"

    private let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BannerTV_EPG", isDirectory: true)
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
        loadCuratedConfigAsync()
    }

    // MARK: - Setup

    /// Decoding the curated channel catalog (~280KB) and building the matcher's alias/fuzzy
    /// indexes costs 139–444ms — moved off `init()` so constructing this `@StateObject`
    /// never blocks the first render. `matchEPGChannels`/`matchCustomEPGChannels` already
    /// guard on `normalizer`/`config` being non-nil, so callers that run before this
    /// completes simply no-op that pass, same as if the catalog were missing entirely.
    private func loadCuratedConfigAsync() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cfg = CuratedGuideConfig.load() else { return }
            let normalizer = ChannelNormalizer(config: cfg)
            let matcher = CanonicalChannelMatcher(config: cfg, normalizer: normalizer)
            await MainActor.run {
                guard let self else { return }
                self.config = cfg
                self.normalizer = normalizer
                self.matcher = matcher
            }
        }
    }

    /// Called when IPTV channels are available. Rebuilds canonical lineup and refreshes EPG if needed.
    func setupWithChannels(_ channels: [Channel], customEPGURLs: [URL] = []) {
        self.customEPGURLs = customEPGURLs
        guard !channels.isEmpty else { return }
        // Hashing every channel is O(n) over a potentially 50k-channel playlist, so the
        // fingerprint is computed off the main thread before deciding whether to re-import.
        let urlSuffix = customEPGURLs.map { $0.absoluteString }.joined()
        fingerprintTask?.cancel()
        fingerprintTask = Task { [weak self] in
            let hash = await Task.detached(priority: .userInitiated) { Self.channelFingerprint(channels) }.value
            guard let self, !Task.isCancelled else { return }
            self.importIfChanged(channels, fingerprint: hash + urlSuffix)
        }
    }

    private func importIfChanged(_ channels: [Channel], fingerprint: String) {
        if fingerprint == lastChannelFingerprint, setupTask != nil || !canonicalChannels.isEmpty {
            // Keep it updated if we missed it earlier.
            return
        }
        lastChannelFingerprint = fingerprint
        currentIPTVChannels = channels
        rebuildGuideIdIndex()

        setupTask?.cancel()
        let generation = UUID()
        importGeneration = generation
        importProgress = LiveTVImportProgress(state: .filtering, rawStreams: channels.count)
        logger.info("Live TV import started raw_streams=\(channels.count, privacy: .public)")

        setupTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { self.setupTask = nil }
            let iptvOrg = IPTVOrgMetadataService.shared
            let iptvIndexes = await iptvOrg.indexes

            let buildResult = await Task.detached(priority: .userInitiated) {
                Self.buildCanonicalLineup(channels: channels, iptvIndexes: iptvIndexes)
            }.value

            guard !Task.isCancelled, self.importGeneration == generation else { return }
            self.importDiagnostics = buildResult.diagnostics
            self.importProgress = LiveTVImportProgress(
                state: .resolvingLogos,
                rawStreams: channels.count,
                filteredStreams: buildResult.filteredStreams,
                matchedStreams: buildResult.matchedStreams,
                canonicalChannels: buildResult.channels.count
            )

            var canonicals = buildResult.channels

            // Enrich ChannelStream.archiveEnabled from the live-channel SQLite cache.
            // Runs once per channel load; safe to skip silently if the store is unavailable.
            let archiveIDs = Set((try? await LiveChannelStore.shared.archiveEnabledChannelIDs()) ?? [])
            if !archiveIDs.isEmpty {
                for i in canonicals.indices {
                    if var ps = canonicals[i].primaryStream,
                       archiveIDs.contains(ps.providerChannelId) {
                        ps.archiveEnabled = true
                        canonicals[i].primaryStream = ps
                    }
                    for j in canonicals[i].fallbackStreams.indices {
                        if archiveIDs.contains(canonicals[i].fallbackStreams[j].providerChannelId) {
                            canonicals[i].fallbackStreams[j].archiveEnabled = true
                        }
                    }
                }
            }

            if iptvIndexes.isLoaded, !canonicals.isEmpty {
                let started = Date()
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
                self.importDiagnostics.logoResolutionDuration = Date().timeIntervalSince(started)
            }

            guard !Task.isCancelled, self.importGeneration == generation else { return }
            self.canonicalChannels = canonicals
            self.rebuildChannelToCanonicalMap()
            self.unresolvedStreams = buildResult.unresolvedStreams
            self.importProgress.state = .loadingEPG
            self.importProgress.canonicalChannels = canonicals.count
            self.logger.info("Live TV lineup ready filtered=\(buildResult.filteredStreams, privacy: .public) matched=\(buildResult.matchedStreams, privacy: .public) canonical=\(canonicals.count, privacy: .public)")
            await self.loadInitialEPGPWProgrammes(for: canonicals)
            guard !Task.isCancelled, self.importGeneration == generation else { return }
            self.importProgress.state = .ready
            if EPGPWSourcePolicy.epgShareFallbackEnabled {
                self.refreshTask?.cancel()
                self.refreshTask = Task(priority: .utility) { [weak self] in
                    await self?.refreshIfNeeded()
                }
            }
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

    struct CanonicalLineupBuildResult {
        let channels: [CanonicalChannel]
        let filteredStreams: Int
        let matchedStreams: Int
        var diagnostics: LiveTVImportDiagnostics
        /// Streams that passed the hide filter but did not match any curated channel.
        /// Retained for global matching so uncatalogued feeds remain in the matching universe.
        let unresolvedStreams: [ChannelStream]
    }

    nonisolated private static func channelFingerprint(_ channels: [Channel]) -> String {
        var hasher = Hasher()
        hasher.combine(channels.count)
        for channel in channels {
            hasher.combine(channel.id)
            hasher.combine(channel.name)
            hasher.combine(channel.group)
        }
        return "\(channels.count)-\(hasher.finalize())"
    }

    nonisolated static func buildCanonicalLineup(
        channels: [Channel],
        iptvIndexes: IPTVOrgIndexes
    ) -> CanonicalLineupBuildResult {
        var diagnostics = LiveTVImportDiagnostics()
        guard let config = CuratedGuideConfig.load() else {
            diagnostics.unmatched = channels.count
            return CanonicalLineupBuildResult(channels: [], filteredStreams: 0, matchedStreams: 0,
                                              diagnostics: diagnostics, unresolvedStreams: [])
        }

        let normalizer = ChannelNormalizer(config: config)
        let matcher = CanonicalChannelMatcher(config: config, normalizer: normalizer, iptvOrgIndexes: iptvIndexes)

        let prefilterStart = Date()
        var visible: [ChannelStream] = []
        visible.reserveCapacity(channels.count)
        for channel in channels {
            if Task.isCancelled { break }
            let filterText = [channel.name, channel.group].compactMap { $0 }.joined(separator: " ")
            guard !normalizer.shouldHide(channelName: filterText) else { continue }
            // Extract pre-normalization metadata before stripping removes slot numbers, dates, etc.
            let metadata = normalizer.extractStreamMetadata(from: channel.name)
            let normName = normalizer.normalize(channel.name)
            var stream = ChannelStream(
                id: channel.id,
                providerChannelId: channel.id,
                originalName: channel.name,
                normalizedName: normName,
                streamURL: channel.streamURL,
                tvgId: channel.tvgId,
                tvgName: channel.name,
                tvgLogoURL: channel.logoURL,
                groupTitle: channel.group,
                resolution: StreamResolution.detect(from: channel.name),
                playlistID: channel.playlistID,
                playlistName: channel.playlistName
            )
            stream.countryHint = normalizer.extractCountryHint(from: channel.name)
            stream.streamMetadata = metadata
            stream.httpHeaders = channel.httpHeaders
            visible.append(stream)
        }
        diagnostics.prefilterDuration = Date().timeIntervalSince(prefilterStart)

        let matchStart = Date()
        var matches: [ChannelMatchResult] = []
        var unresolvedStreams: [ChannelStream] = []
        matches.reserveCapacity(min(visible.count, config.channels.count * 4))
        for stream in visible {
            if Task.isCancelled { break }
            if let result = matcher.match(stream) {
                matches.append(result)
                switch result.matchMethod {
                case .providerEpgExact, .providerEpgCaseInsensitive, .exactTvgId, .exactAlias:
                    diagnostics.exactMatches += 1
                case .normalizedExact:
                    diagnostics.normalizedMatches += 1
                case .iptvOrgExactId, .iptvOrgCaseInsensitiveId, .iptvOrgAltName, .replacementChain:
                    diagnostics.iptvOrgMatches += 1
                case .fuzzy:
                    diagnostics.fuzzyMatches += 1
                default:
                    break
                }
            } else {
                diagnostics.unmatched += 1
                unresolvedStreams.append(stream)
            }
        }
        diagnostics.canonicalMatchDuration = Date().timeIntervalSince(matchStart)

        let dedupeStart = Date()
        let canonicals = matcher.buildCanonicalChannels(from: matches)
        diagnostics.dedupeDuration = Date().timeIntervalSince(dedupeStart)

        return CanonicalLineupBuildResult(
            channels: canonicals,
            filteredStreams: visible.count,
            matchedStreams: matches.count,
            diagnostics: diagnostics,
            unresolvedStreams: unresolvedStreams
        )
    }

    // MARK: - EPG.pw Lazy Loading

    private func loadInitialEPGPWProgrammes(for channels: [CanonicalChannel]) async {
        guard EPGPWSourcePolicy.epgPWEnabled else { return }
        await PlaybackPriority.waitForIdle()
        let prioritized = channels.sorted { $0.priority > $1.priority }
        await loadEPGPWProgrammes(for: Array(prioritized.prefix(24)), forceRefresh: false)
    }

    func prefetchProgrammes(for channels: [CanonicalChannel], forceRefresh: Bool = false) {
        guard EPGPWSourcePolicy.epgPWEnabled else { return }
        let mapped = channels.filter { epgpwMappings.mapping(for: $0.id) != nil }
        guard !mapped.isEmpty else { return }
        let key = mapped.map(\.id).joined(separator: "|") + "-\(forceRefresh)"
        if epgpwPrefetchTasks[key] != nil { return }
        epgpwPrefetchTasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.loadEPGPWProgrammes(for: mapped, forceRefresh: forceRefresh)
            await MainActor.run { self.epgpwPrefetchTasks[key] = nil }
        }
    }

    private func requestEPGPWIfNeeded(channelId: String, from: Date, to: Date) {
        guard EPGPWSourcePolicy.epgPWEnabled,
              let channel = canonicalChannelsByID[channelId],
              epgpwMappings.mapping(for: channelId) != nil else { return }
        let hasCoverage = programmeIndex[channelId]?.contains { programme in
            programme.end > from && programme.start < to
        } ?? false
        guard !hasCoverage else { return }
        prefetchProgrammes(for: [channel])
    }

    /// Same idea as `requestEPGPWIfNeeded`, but against the Xtream per-channel EPG
    /// endpoints instead of epg.pw. `fullSchedule` picks `get_simple_data_table` (a full
    /// day, only for a row actually visible) vs `get_short_epg` (now/next only).
    private func requestXtreamEPGIfNeeded(channelId: String, from: Date, to: Date, fullSchedule: Bool) {
        guard let fetcher = xtreamEPGFetcher,
              let canonical = canonicalChannelsByID[channelId],
              let providerChannelId = canonical.primaryStream?.providerChannelId else { return }
        let epgId = "xtream:\(providerChannelId)"
        let hasCoverage = programmeIndex[channelId]?.contains { prog in
            prog.epgChannelId == epgId && prog.end > from && prog.start < to
        } ?? false
        guard !hasCoverage else { return }
        let taskKey = "\(providerChannelId)-\(fullSchedule)"
        guard !xtreamEPGTasks.contains(taskKey) else { return }
        xtreamEPGTasks.insert(taskKey)
        Task { [weak self] in
            defer { self?.xtreamEPGTasks.remove(taskKey) }
            guard let self else { return }
            let fetched = await fetcher(providerChannelId, fullSchedule)
            guard !fetched.isEmpty else { return }
            var merged = self.programmeIndex
            for var prog in fetched where prog.isValid {
                prog.canonicalChannelId = channelId
                merged[channelId, default: []].append(prog)
            }
            self.finalizeProgrammeIndex(merged)
        }
    }

    private func loadEPGPWProgrammes(for channels: [CanonicalChannel], forceRefresh: Bool) async {
        let mappings = channels.compactMap { epgpwMappings.mapping(for: $0.id) }
        guard !mappings.isEmpty else { return }
        importProgress.epgChannels = max(importProgress.epgChannels, mappings.count)
        await withTaskGroup(of: EPGPWFetchResult?.self) { group in
            for mapping in mappings {
                group.addTask { [epgpwProvider] in
                    do {
                        return try await epgpwProvider.programmes(for: mapping, forceRefresh: forceRefresh)
                    } catch {
                        #if DEBUG
                        print("EPG.pw failed canonical=\(mapping.canonicalChannelId) id=\(mapping.epgpwChannelId): \(error.localizedDescription)")
                        #endif
                        return nil
                    }
                }
            }

            var merged = programmeIndex
            var retained = 0
            for await result in group {
                guard let result else { continue }
                epgpwDiagnostics[result.mapping.canonicalChannelId] = result
                if !result.programmes.isEmpty {
                    mergeEPGPWProgrammes(result.programmes, into: &merged)
                    retained += result.programmes.count
                }
            }
            if retained > 0 {
                finalizeProgrammeIndex(merged)
                importProgress.programmesRetained = programmeIndex.values.reduce(0) { $0 + $1.count }
                lastUpdated = Date()
                persistState()
            }
        }
    }

    private func mergeEPGPWProgrammes(_ programmes: [EPGProgramme], into index: inout [String: [EPGProgramme]]) {
        for prog in programmes {
            guard prog.isValid, let canonId = prog.canonicalChannelId else { continue }
            index[canonId, default: []].append(prog)
        }
    }

    // MARK: - Refresh

    func refreshIfNeeded() async {
        guard EPGPWSourcePolicy.epgShareFallbackEnabled else { return }
        
        var missingCustomSource = false
        for (i, _) in customEPGURLs.enumerated() {
            let cacheFile = cacheDir.appendingPathComponent("custom-\(i).xml")
            if !FileManager.default.fileExists(atPath: cacheFile.path) {
                missingCustomSource = true
                break
            }
        }
        
        let staleness: TimeInterval = 6 * 3600
        if !missingCustomSource, let last = lastUpdated, Date().timeIntervalSince(last) < staleness,
           !programmeIndex.isEmpty { return }
        await forceRefresh()
    }

    func forceRefresh() async {
        guard EPGPWSourcePolicy.epgShareFallbackEnabled else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshState = .refreshing
        importProgress.state = .loadingEPG
        defer { isRefreshing = false }

        let activeCategoryIds = Set(canonicalChannels.map(\.categoryId))
        let sources = EPGSourceRegistry.sources(for: activeCategoryIds)

        let now = Date()
        // Keep 14h of past data so the guide shows programmes from midnight today
        let programmeWindow = now.addingTimeInterval(-14 * 3600)...now.addingTimeInterval(36 * 3600)

        var programmeIndex = self.programmeIndex

        // Custom EPG XML embedded directly in the user's own M3U/Xtream playlist is
        // matched by tvg-id against that playlist's own channel list, and doesn't
        // depend on the generic epgshare01 feeds below at all. Run and publish it
        // FIRST — a user's own playlist should confirm against live matches right
        // away, not wait behind up to 4 unrelated generic broadcaster feeds that
        // still need to download and parse.
        var customChannelMappings: [String: CustomEPGMatch] = [:]
        for (index, url) in customEPGURLs.enumerated() {
            guard !Task.isCancelled else {
                refreshState = .idle
                importProgress.state = .cancelled
                return
            }
            guard let data = await customEPGData(url: url, index: index) else { continue }
            let sourceId = "custom-\(index)"
            let started = Date()
            let parseResult = await Task.detached(priority: .utility) {
                EPGXMLParser(sourceId: sourceId, priority: 0).parse(data: data, programmeWindow: programmeWindow)
            }.value
            importDiagnostics.epgChannelParseDuration += Date().timeIntervalSince(started)
            let mapping = matchCustomEPGChannels(parseResult.channels)
            guard !mapping.isEmpty else { continue }
            customChannelMappings.merge(mapping) { _, new in new }
            epgToCanonical.merge(mapping.mapValues(\.canonicalChannelId)) { _, new in new }
            importProgress.epgChannels += mapping.count

            // Which raw stream(s) this schedule applies to is resolved by
            // `guideIdToProviderChannelIds` (built from every stream's own tvg-id) —
            // not stamped onto the programme itself. A canonical channel can merge
            // several mirrors/feeds; consumers check that index to see which of
            // them actually share this programme's guide ID.
            for var prog in parseResult.programmes {
                guard prog.isValid, let match = mapping[prog.epgChannelId] else { continue }
                prog.canonicalChannelId = match.canonicalChannelId
                programmeIndex[match.canonicalChannelId, default: []].append(prog)
            }
        }

        if !customChannelMappings.isEmpty {
            // Early partial publish: the user's own playlist EPG is ready and merged —
            // surface it now instead of waiting on the slower generic feeds below.
            finalizeProgrammeIndex(programmeIndex)
            importProgress.programmesRetained = programmeIndex.values.reduce(0) { $0 + $1.count }
            lastUpdated = Date()
            persistState()
        }

        // Generic epgshare01 broadcaster feeds — fetched and parsed in parallel since
        // each source is fully independent; this used to be a serial loop that summed
        // every source's network+parse time instead of running them concurrently.
        var allEPGChannels: [EPGChannel] = []
        await withTaskGroup(of: (source: EPGSource, channels: [EPGChannel], duration: TimeInterval)?.self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    guard let self, let data = await self.epgData(for: source) else { return nil }
                    let started = Date()
                    let result = await Task.detached(priority: .utility) {
                        EPGXMLParser(sourceId: source.id, priority: source.priority)
                            .parse(data: data, channelsOnly: true)
                    }.value
                    return (source, result.channels, Date().timeIntervalSince(started))
                }
            }
            for await result in group {
                guard let result else { continue }
                importDiagnostics.epgChannelParseDuration += result.duration
                allEPGChannels.append(contentsOf: result.channels)
            }
        }
        guard !Task.isCancelled else {
            refreshState = .idle
            importProgress.state = .cancelled
            return
        }

        // Match EPG channels to canonical channels
        matchEPGChannels(allEPGChannels)
        // matchEPGChannels replaces epgToCanonical wholesale — reapply the custom
        // playlist's mapping on top so it keeps winning ties against generic feeds.
        if !customChannelMappings.isEmpty {
            epgToCanonical.merge(customChannelMappings.mapValues(\.canonicalChannelId)) { _, new in new }
        }
        let wantedEPGIds = Set(epgToCanonical.keys)
        // epgToCanonical already includes the custom mapping merged in above, so this
        // count covers both generic and custom channels without double-counting.
        importProgress.epgChannels = wantedEPGIds.count

        if !wantedEPGIds.isEmpty {
            await withTaskGroup(of: (programmes: [EPGProgramme], duration: TimeInterval)?.self) { group in
                for source in sources {
                    group.addTask { [weak self] in
                        guard let self, let data = await self.cachedEPGData(for: source) else { return nil }
                        let started = Date()
                        let parseResult = await Task.detached(priority: .utility) {
                            EPGXMLParser(sourceId: source.id, priority: source.priority)
                                .parse(data: data, allowedChannelIds: wantedEPGIds, programmeWindow: programmeWindow)
                        }.value
                        return (parseResult.programmes, Date().timeIntervalSince(started))
                    }
                }
                for await result in group {
                    guard let result else { continue }
                    importDiagnostics.epgProgrammeParseDuration += result.duration
                    mergeProgrammes(result.programmes, into: &programmeIndex)
                }
            }
        }
        guard !Task.isCancelled else {
            refreshState = .idle
            importProgress.state = .cancelled
            return
        }

        finalizeProgrammeIndex(programmeIndex)
        importProgress.programmesRetained = programmeIndex.values.reduce(0) { $0 + $1.count }

        lastUpdated = Date()
        persistState()

        await MainActor.run {
            self.refreshState = .idle
        }
    }

    // MARK: - Download + Parse

    private func epgData(for source: EPGSource) async -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("\(source.id).xml")

        // Check disk cache freshness
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < source.cacheTTL,
           let data = try? Data(contentsOf: cacheFile) {
            return data
        }

        // Download — streamed straight to a temp file so the response body is never
        // held as a second in-memory copy on top of whatever URLSession buffers internally.
        do {
            let downloadStart = Date()
            let (tempURL, _) = try await session.download(from: source.url)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            importDiagnostics.epgDownloadDuration += Date().timeIntervalSince(downloadStart)
            let raw = try Data(contentsOf: tempURL)
            let decompressed = await Task.detached(priority: .utility) {
                raw.tryGunzip()
            }.value
            try decompressed.write(to: cacheFile)
            return decompressed
        } catch {
            // Network failure: try cached file even if stale
            return try? Data(contentsOf: cacheFile)
        }
    }

    private func cachedEPGData(for source: EPGSource) -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("\(source.id).xml")
        return try? Data(contentsOf: cacheFile)
    }

    /// Downloads (or serves from cache) the XMLTV file a playlist advertises via
    /// `x-tvg-url` (M3U) or `xmltv.php` (Xtream). Cache filename matches the
    /// `custom-N.xml` convention `refreshIfNeeded()` checks for staleness.
    private func customEPGData(url: URL, index: Int) async -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("custom-\(index).xml")
        let ttl: TimeInterval = 6 * 3600

        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < ttl,
           let data = try? Data(contentsOf: cacheFile) {
            return data
        }

        do {
            let downloadStart = Date()
            let (tempURL, _) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            importDiagnostics.epgDownloadDuration += Date().timeIntervalSince(downloadStart)
            let raw = try Data(contentsOf: tempURL)
            let decompressed = await Task.detached(priority: .utility) {
                raw.tryGunzip()
            }.value
            try decompressed.write(to: cacheFile)
            return decompressed
        } catch {
            return try? Data(contentsOf: cacheFile)
        }
    }

    /// A custom-EPG channel resolved to one exact raw stream, plus the canonical
    /// group it happens to belong to.
    private struct CustomEPGMatch {
        let canonicalChannelId: String
        let providerChannelId: String
    }

    /// Matches a playlist's own XMLTV channel entries to that same playlist's channels
    /// by tvg-id (the two are issued together by the provider, so this is exact), with
    /// a normalized display-name fallback for providers whose ids drift between files.
    /// Resolves to one specific raw stream rather than the canonical group as a whole,
    /// since a canonical channel can merge several mirrors that don't share content —
    /// the caller uses that to scope the matched schedule to just that one stream.
    private func matchCustomEPGChannels(_ epgChannels: [EPGChannel]) -> [String: CustomEPGMatch] {
        guard let normalizer else { return [:] }

        var tvgIdToProvider: [String: String] = [:]
        var nameToProvider: [String: String] = [:]
        for channel in currentIPTVChannels {
            if let tvgId = channel.tvgId, !tvgId.isEmpty {
                tvgIdToProvider[tvgId.lowercased()] = channel.id
            }
            nameToProvider[normalizer.normalize(channel.name).lowercased()] = channel.id
        }

        var mapping: [String: CustomEPGMatch] = [:]
        for epgCh in epgChannels {
            var providerId = tvgIdToProvider[epgCh.id.lowercased()]
            if providerId == nil {
                for displayName in epgCh.displayNames {
                    if let match = nameToProvider[normalizer.normalize(displayName).lowercased()] {
                        providerId = match
                        break
                    }
                }
            }
            guard let providerId, let canonId = channelToCanonicalMap[providerId] else { continue }
            mapping[epgCh.id] = CustomEPGMatch(canonicalChannelId: canonId, providerChannelId: providerId)
        }
        return mapping
    }

    // MARK: - EPG Channel Matching

    private func matchEPGChannels(_ epgChannels: [EPGChannel]) {
        guard let normalizer else { return }

        // Authoritative epg_id → canonical map. Built and checked separately from the
        // alias/name candidate pool below so a curated channel's explicit epg_id can
        // never be silently clobbered by some other channel's alias that happens to
        // normalize to the same string — that was the previous bug: both fed one flat
        // last-writer-wins dictionary, keyed purely by config iteration order.
        var epgIdToCanon: [String: String] = [:]
        if let config {
            for curatedCh in config.channels {
                guard let epgId = curatedCh.epgId, !epgId.isEmpty else { continue }
                epgIdToCanon[epgId.lowercased()] = curatedCh.key
                let normEpgId = normalizer.normalize(epgId).lowercased()
                if !normEpgId.isEmpty { epgIdToCanon[normEpgId] = curatedCh.key }
            }
        }

        // Everything else (canonical channel names/networks, curated aliases,
        // unresolved streams' own tvg-id) goes into a candidate-array pool, mirroring
        // CanonicalChannelMatcher.addCandidate/resolveFromCandidates: a key that two
        // different channels both produce is left ambiguous (unresolved) rather than
        // resolved to whichever happened to be written last.
        var candidates: [String: [String]] = [:]
        func addCandidate(_ key: String, _ canonicalId: String) {
            let normalized = key.lowercased()
            guard !normalized.isEmpty else { return }
            var list = candidates[normalized] ?? []
            if !list.contains(canonicalId) { list.append(canonicalId) }
            candidates[normalized] = list
        }

        for ch in canonicalChannels {
            addCandidate(normalizer.normalize(ch.name), ch.id)
            if let network = ch.network { addCandidate(network, ch.id) }
        }
        if let config {
            for curatedCh in config.channels {
                for alias in curatedCh.aliases {
                    addCandidate(alias, curatedCh.key)
                    addCandidate(normalizer.normalize(alias), curatedCh.key)
                }
            }
        }
        for stream in unresolvedStreams {
            guard let epgId = stream.tvgId, !epgId.isEmpty else { continue }
            addCandidate(epgId, stream.id)
        }

        func resolve(_ key: String) -> String? {
            let normalized = key.lowercased()
            guard !normalized.isEmpty else { return nil }
            if let canonical = epgIdToCanon[normalized] { return canonical }
            guard let list = candidates[normalized], list.count == 1 else { return nil }
            return list.first
        }

        var newMapping: [String: String] = [:]  // epgChannelId -> canonicalChannelId
        for epgCh in epgChannels {
            guard !epgCh.id.isEmpty else { continue }
            var matched: String?

            // 1. Try XMLTV channel id itself (catches epg_id matches)
            matched = resolve(epgCh.id) ?? resolve(normalizer.normalize(epgCh.id))

            // 2. Try each display name
            if matched == nil {
                for displayName in epgCh.displayNames where !displayName.isEmpty {
                    if let canonId = resolve(displayName) ?? resolve(normalizer.normalize(displayName)) {
                        matched = canonId
                        break
                    }
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
        Task { @MainActor in
            self.canonicalChannels = updated
            self.rebuildChannelToCanonicalMap()
        }
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
        index = index.mapValues { deduplicate($0.sorted { $0.start < $1.start }) }

        programmeIndex = index
    }

    private func mergeProgrammes(_ programmes: [EPGProgramme], into index: inout [String: [EPGProgramme]]) {
        for var prog in programmes {
            guard prog.isValid, let canonId = epgToCanonical[prog.epgChannelId] else { continue }
            prog.canonicalChannelId = canonId
            index[canonId, default: []].append(prog)
        }
    }

    private func finalizeProgrammeIndex(_ index: [String: [EPGProgramme]]) {
        var finalized: [String: [EPGProgramme]] = [:]
        finalized.reserveCapacity(index.count)
        for (key, programmes) in index {
            finalized[key] = deduplicate(programmes.sorted { $0.start < $1.start })
        }
        programmeIndex = finalized
        rebuildCoverageIndex()
        persistProgrammesToStore(finalized)
    }

    /// Durable guide storage, keyed by guide ID (`EPGProgramme.epgChannelId`/`sourceId`) —
    /// replaces the old whole-dictionary `programmeIndex.v2.json` cache, which was
    /// rewritten in full on every update with no retention policy and grew unbounded.
    /// `programmeIndex` (canonical-channel-keyed, in-memory) stays the synchronous hot-path
    /// read the rest of this file uses; this is purely the cross-launch durability layer.
    private func persistProgrammesToStore(_ index: [String: [EPGProgramme]]) {
        let bySource = Dictionary(grouping: index.values.flatMap { $0 }, by: \.sourceId)
        Task.detached(priority: .background) {
            for (sourceId, programmes) in bySource {
                try? await EPGProgrammeStore.shared.replaceProgrammes(programmes, sourceId: sourceId, retentionDays: 7)
            }
        }
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
        requestEPGPWIfNeeded(channelId: channelId, from: date.addingTimeInterval(-3600), to: date.addingTimeInterval(6 * 3600))
        requestXtreamEPGIfNeeded(channelId: channelId, from: date.addingTimeInterval(-3600), to: date.addingTimeInterval(6 * 3600), fullSchedule: false)
        return programmeIndex[channelId]?.first { $0.isOnNow(at: date) }
    }

    func nextProgramme(for channelId: String, after date: Date = Date()) -> EPGProgramme? {
        requestEPGPWIfNeeded(channelId: channelId, from: date, to: date.addingTimeInterval(12 * 3600))
        requestXtreamEPGIfNeeded(channelId: channelId, from: date, to: date.addingTimeInterval(12 * 3600), fullSchedule: false)
        return programmeIndex[channelId]?.first { $0.start > date }
    }

    func programmes(for channelId: String, from: Date, to: Date) -> [EPGProgramme] {
        requestEPGPWIfNeeded(channelId: channelId, from: from, to: to)
        // A full day, so `get_simple_data_table` — this is only reached for rows the
        // guide actually renders (TVGuideViewModel.rowLayout / the vertically- and
        // horizontally-virtualized grid), not the whole channel list.
        requestXtreamEPGIfNeeded(channelId: channelId, from: from, to: to, fullSchedule: true)
        return programmeIndex[channelId]?.filter { $0.end > from && $0.start < to } ?? []
    }

    func hasProgrammes(for channelId: String) -> Bool {
        !(programmeIndex[channelId]?.isEmpty ?? true)
    }

    // MARK: - Coverage API

    /// Returns the coverage range for a canonical channel, or nil if no programmes are indexed.
    func coverage(for channelId: String) -> ProgrammeCoverage? {
        coverageIndex[channelId]
    }

    /// All canonical channel IDs that have programmes overlapping the given window.
    func channelsWithCoverage(in window: ClosedRange<Date>) -> [String] {
        coverageIndex.values
            .filter { $0.overlaps(start: window.lowerBound, end: window.upperBound) }
            .map(\.channelId)
    }

    /// Canonical channel IDs that have an EPG.pw mapping but no current or near-future coverage.
    /// These are candidates for a background enrichment fetch.
    var channelsNeedingEnrichment: [String] {
        let soon = Date().addingTimeInterval(2 * 3600)
        return canonicalChannels.compactMap { channel -> String? in
            guard epgpwMappings.mapping(for: channel.id) != nil else { return nil }
            if let cov = coverageIndex[channel.id] { return cov.latestEnd < soon ? channel.id : nil }
            return channel.id
        }
    }

    // MARK: - Event-programme join

    /// Returns programmes that likely cover a specific sports event, ranked by evidence.
    ///
    /// Parameters are kept EPG-generic so callers don't need to import sports types.
    ///
    /// - Parameters:
    ///   - start: Scheduled event start time.
    ///   - duration: Expected event length (default 3 h); used as the matching window.
    ///   - titleHints: Event name variants (e.g. game name and short name). Used for title similarity.
    ///   - broadcastNetworks: Known rights-holder network names from the event's broadcast record.
    func programmesNear(
        start: Date,
        duration: TimeInterval = 3 * 3600,
        titleHints: [String],
        broadcastNetworks: [String]
    ) -> [ProgrammeEventJoin] {
        let searchEnd   = start.addingTimeInterval(duration)
        // Include pre-show (30 min before) and post-show (30 min after) programmes.
        let windowStart = start.addingTimeInterval(-1800)
        let windowEnd   = searchEnd.addingTimeInterval(1800)

        let networkSet    = Set(broadcastNetworks.map { $0.lowercased() })
        let hintTokenSets = titleHints.map { epgTokenize($0) }.filter { !$0.isEmpty }

        // Build O(1) channel-network lookup for this call.
        var channelNetworks: [String: String] = [:]
        for ch in canonicalChannels {
            if let net = ch.network { channelNetworks[ch.id] = net.lowercased() }
        }

        var joins: [ProgrammeEventJoin] = []
        for (channelId, programmes) in programmeIndex {
            let channelNet    = channelNetworks[channelId]
            let networkMatches = channelNet.map { networkSet.contains($0) } ?? false

            for programme in programmes {
                guard programme.end > windowStart && programme.start < windowEnd else { continue }
                let overlapStart = max(programme.start, start)
                let overlapEnd   = min(programme.end, searchEnd)
                let overlap      = max(0, overlapEnd.timeIntervalSince(overlapStart))

                let progTokens   = epgTokenize(programme.title)
                let similarity   = hintTokenSets.map { epgJaccard(progTokens, $0) }.max() ?? 0

                guard similarity >= 0.10 || networkMatches else { continue }

                joins.append(ProgrammeEventJoin(
                    programme: programme,
                    canonicalChannelId: channelId,
                    titleSimilarity: similarity,
                    timeOverlap: overlap,
                    networkMatches: networkMatches
                ))
            }
        }

        return joins.sorted { $0.score > $1.score }
    }

    // MARK: - Coverage rebuild

    private func rebuildChannelToCanonicalMap() {
        var map: [String: String] = [:]
        map.reserveCapacity(canonicalChannels.count * 2)
        for canonical in canonicalChannels {
            for stream in canonical.allStreams {
                map[stream.providerChannelId] = canonical.id
            }
        }
        for stream in unresolvedStreams {
            if stream.tvgId?.isEmpty == false {
                map[stream.providerChannelId] = stream.id
            }
        }
        channelToCanonicalMap = map
        canonicalChannelsByID = Dictionary(canonicalChannels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Guide ID -> every raw provider channel that declares it, built from the full
    /// unfiltered input list so unresolved streams are covered, not just matched ones.
    /// Empty/missing tvg-ids are skipped — an empty guide ID can't identify anything.
    private func rebuildGuideIdIndex() {
        var index: [String: Set<String>] = [:]
        for channel in currentIPTVChannels {
            guard let guideId = channel.tvgId?.lowercased(), !guideId.isEmpty else { continue }
            index[guideId, default: []].insert(channel.id)
        }
        guideIdToProviderChannelIds = index
    }

    /// Every raw provider channel ID that declares the given guide ID, or nil if none do
    /// (e.g. the provider never sent tvg-ids at all — callers should treat that as
    /// "no restriction" rather than "confirmed for nobody").
    func providerChannelIds(forGuideId guideId: String) -> Set<String>? {
        guideIdToProviderChannelIds[guideId.lowercased()]
    }

    /// The canonical channel a provider channel was matched to, via the prebuilt maps (no scans).
    func canonicalChannel(forProviderChannelID id: String) -> CanonicalChannel? {
        channelToCanonicalMap[id].flatMap { canonicalChannelsByID[$0] }
    }

    private func rebuildCoverageIndex() {
        var index: [String: ProgrammeCoverage] = [:]
        index.reserveCapacity(programmeIndex.count)
        for (channelId, programmes) in programmeIndex where !programmes.isEmpty {
            index[channelId] = ProgrammeCoverage(
                channelId: channelId,
                earliestStart: programmes[0].start,
                latestEnd: programmes[programmes.count - 1].end,
                programmeCount: programmes.count
            )
        }
        coverageIndex = index
    }

    // MARK: - Event-join helpers

    private func epgTokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    private func epgJaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let unionCount = a.union(b).count
        guard unionCount > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(unionCount)
    }

    // MARK: - Persistence

    private func loadCachedState() {
        if let ts = UserDefaults.standard.object(forKey: lastUpdatedKey) as? Date {
            lastUpdated = ts
        }
        // `programmeIndex` starts empty on cold launch and is repopulated once the
        // first import/refresh cycle completes (triggered automatically by
        // `importIfChanged`) — the old JSON blob that used to rehydrate it eagerly
        // had no retention policy and grew unbounded; guide data now lives in
        // `EPGProgrammeStore` (SQLite, 7-day retention) instead.
    }

    private func persistState() {
        UserDefaults.standard.set(lastUpdated, forKey: lastUpdatedKey)
    }

    // MARK: - Debug info

    func epgpwDiagnostics(for channelId: String) -> EPGPWChannelDiagnostics? {
        guard let mapping = epgpwMappings.mapping(for: channelId) else { return nil }
        let result = epgpwDiagnostics[channelId]
        let programmes = programmeIndex[channelId] ?? []
        let now = Date()
        return EPGPWChannelDiagnostics(
            canonicalName: mapping.canonicalName,
            canonicalChannelId: mapping.canonicalChannelId,
            epgpwChannelId: mapping.epgpwChannelId,
            epgpwName: mapping.epgpwName,
            country: mapping.country,
            matchMethod: mapping.matchMethod,
            confidence: mapping.confidence,
            verified: mapping.verified,
            lastFetch: result?.lastFetch,
            lastSuccessfulFetch: result?.lastSuccessfulFetch,
            coverageStart: result?.coverageStart,
            coverageEnd: result?.coverageEnd,
            programmeCount: programmes.count,
            current: programmes.first { $0.isOnNow(at: now) }?.title,
            next: programmes.first { $0.start > now }?.title,
            cacheState: result?.cacheState.rawValue ?? "missing",
            requestState: epgpwPrefetchTasks.values.contains { !$0.isCancelled } ? "fetching" : "idle"
        )
    }

    var diagnostics: String {
        """
        Canonical channels: \(canonicalChannels.count)
        With XMLTV EPG mapping: \(canonicalChannels.filter { $0.epgChannelId != nil }.count)
        With EPG.pw mapping: \(canonicalChannels.filter { epgpwMappings.mapping(for: $0.id) != nil }.count)
        XMLTV EPG channel mappings: \(epgToCanonical.count)
        Indexed channel schedules: \(programmeIndex.count)
        Last updated: \(lastUpdated?.formatted() ?? "never")
        """
    }
}
