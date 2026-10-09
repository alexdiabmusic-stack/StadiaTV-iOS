import Foundation
import Combine
import OSLog

// MARK: - Gzip helper

nonisolated private extension Data {
    /// Decompresses gzip data. Data that isn't gzip is returned unchanged. Returns nil when it is
    /// gzip but can't be inflated (truncated, corrupt, or expanding past
    /// `GzipInflate.maxInflatedBytes`), so a caller can keep its previous good copy instead of
    /// caching junk.
    func gunzippedIfNeeded() -> Data? {
        switch GzipInflate.decompress(self) {
        case .notGzip: return self
        case .inflated(let data): return data
        case .failed: return nil
        }
    }
}

/// Why a guide download wasn't used; the caller falls back to its cached copy.
private enum GuideDownloadError: Error {
    case badStatus
    case undecodable
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
    /// Lowercased broadcast network per canonical channel ID, for `programmesNear`.
    private var channelNetworkByID: [String: String] = [:]
    private var fingerprintTask: Task<Void, Never>?
    /// Streams that passed the hide filter but matched no curated channel.
    /// Available for global event-to-stream matching so uncatalogued feeds are not silently dropped.
    @Published private(set) var unresolvedStreams: [ChannelStream] = []
    @Published private(set) var refreshState: EPGRefreshState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var importProgress = LiveTVImportProgress()
    @Published private(set) var importDiagnostics = LiveTVImportDiagnostics()

    // Programme index: canonicalChannelId -> [EPGProgramme] sorted by start
    private var programmeIndex: [String: [EPGProgramme]] = [:]
    /// Bumped whenever the guide is replaced wholesale (an import, a refresh, a hydration from the
    /// store). Stream matching and match-detail ranking key off this, so it deliberately does NOT
    /// move for the on-demand top-up of a single row; see `guideRevision(for:)`.
    private(set) var programmeRevision = 0
    /// Per-channel count of on-demand top-ups (a row scrolled into view fetching its own schedule).
    private var channelTopUpRevisions: [String: Int] = [:]
    private var persistDebounceTask: Task<Void, Never>?

    /// Changes whenever anything shown for `channelId` could have: a wholesale replace, or that
    /// channel's own top-up. Guide rows key their cached layout on this, so one row arriving
    /// doesn't invalidate every other row.
    func guideRevision(for channelId: String) -> Int {
        programmeRevision &+ (channelTopUpRevisions[channelId] ?? 0)
    }
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
    private var curatedConfigTask: Task<Void, Never>?
    /// From the latest lineup import; see `CustomEPGLookup`.
    private var customEPGLookup = CustomEPGLookup()

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
    /// Last successful fetch per (providerChannelId, fullSchedule) key — see
    /// `requestXtreamEPGIfNeeded`'s 6-hour freshness window.
    private var xtreamEPGFetchedAt: [String: Date] = [:]
    /// Shared across every `EPGRepository` instance (there's normally one): caps concurrent
    /// Xtream per-channel EPG fetches at 2.
    private static let xtreamEPGGate = AsyncGate(limit: 2)
    private let logger = Logger(subsystem: "BannerTV", category: "LiveTVImport")

    // Cache keys
    private let channelCacheKey = "epg.canonical.channels.v1"
    private let programmeCacheKey = "epg.programmes.v1"
    private let lastUpdatedKey = "epg.lastUpdated.v1"

    private let cacheDir: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BannerTV_EPG", isDirectory: true)
    }()

    private static func makeSession(allowsConstrainedAccess: Bool) -> URLSession {
        // A guide can be tens of megabytes; on a slow link two minutes aborted the download and
        // silently fell back to stale data (`NetworkPolicy` sets the longer timeout).
        let cfg = NetworkPolicy.bulkConfiguration(allowsConstrainedAccess: allowsConstrainedAccess)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }
    private let session = EPGRepository.makeSession(allowsConstrainedAccess: true)
    /// Refused by the system while Low Data Mode is on; see `downloadSession(hasCachedCopy:)`.
    private let deferrableSession = EPGRepository.makeSession(allowsConstrainedAccess: false)
    private var refreshOrigin: RefreshOrigin = .userInitiated

    /// An automatic refresh with a cached guide to fall back on doesn't download in Low Data Mode;
    /// it keeps the cached guide. Anything the user asked for, and a first download, always may.
    private func downloadSession(hasCachedCopy: Bool) -> URLSession {
        NetworkPolicy.defersInLowDataMode(refreshOrigin, hasCachedCopy: hasCachedCopy) ? deferrableSession : session
    }

    init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadCachedState()
        loadCuratedConfigAsync()
    }

    // MARK: - Setup

    /// Decoding the curated channel catalog (~280KB) and building the matcher's alias/fuzzy
    /// indexes costs 139–444ms — moved off `init()` so constructing this `@StateObject`
    /// never blocks the first render. A guide refresh waits for it (`curatedConfigTask`): its
    /// channel matching guards on `normalizer`/`config` being non-nil, so a refresh that
    /// raced ahead of the load would match nothing and still mark the guide as fresh.
    private func loadCuratedConfigAsync() {
        curatedConfigTask = Task.detached(priority: .userInitiated) { [weak self] in
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
    /// - Parameter customEPGURLs: the playlists' own XMLTV guides. `nil` keeps the URLs from the
    ///   previous call, so a caller that only has channels can't wipe them.
    func setupWithChannels(_ channels: [Channel], customEPGURLs: [URL]? = nil) {
        if let customEPGURLs { self.customEPGURLs = customEPGURLs }
        guard !channels.isEmpty else { return }
        // Hashing every channel is O(n) over a potentially 50k-channel playlist, so the
        // fingerprint is computed off the main thread before deciding whether to re-import.
        let urlSuffix = self.customEPGURLs.map { $0.absoluteString }.joined()
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
            // unresolvedStreams must be set before rebuildChannelToCanonicalMap() runs — it
            // reads unresolvedStreams to map those streams' own guide ids too, not just
            // matched/canonical ones. Getting this backwards (as a prior version of this
            // method did) meant every "unresolved" stream kept a stale or empty mapping for an
            // entire import cycle. See MatchLinker/PROMPTS.md, Prompt 3.
            self.unresolvedStreams = buildResult.unresolvedStreams
            self.customEPGLookup = buildResult.customEPGLookup
            self.rebuildChannelToCanonicalMap()
            self.importProgress.state = .loadingEPG
            self.importProgress.canonicalChannels = canonicals.count
            await self.hydrateProgrammesFromStore(generation: generation)
            guard !Task.isCancelled, self.importGeneration == generation else { return }
            self.logger.info("Live TV lineup ready filtered=\(buildResult.filteredStreams, privacy: .public) matched=\(buildResult.matchedStreams, privacy: .public) canonical=\(canonicals.count, privacy: .public)")
            await self.loadInitialEPGPWProgrammes(for: canonicals)
            guard !Task.isCancelled, self.importGeneration == generation else { return }
            self.importProgress.state = .ready
            // Always scheduled: this is what (re-)parses the playlist's own custom EPG
            // (customEPGURLs) on a 6-hour cadence, independent of whether the generic
            // epgshare01 fallback feeds (gated inside forceRefresh) are enabled.
            self.refreshTask?.cancel()
            self.refreshTask = Task(priority: .utility) { [weak self] in
                await self?.refreshIfNeeded()
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
        /// How the playlists' own XMLTV channel ids map to these streams, from the names this
        /// import already normalised.
        var customEPGLookup = CustomEPGLookup()
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

        // Later streams win a shared key, as they did when this was built from the raw channel list.
        var customLookup = CustomEPGLookup()
        for stream in visible {
            if let tvgId = stream.tvgId, !tvgId.isEmpty {
                customLookup.tvgIdToProvider[tvgId.lowercased()] = stream.providerChannelId
            }
            customLookup.nameToProvider[stream.normalizedName.lowercased()] = stream.providerChannelId
        }

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
            unresolvedStreams: unresolvedStreams,
            customEPGLookup: customLookup
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
    ///
    /// A fetch is only trusted for 6 hours (`xtreamEPGFetchedAt`) — after that it's refetched
    /// even if the stored programmes still nominally cover `[from, to]`, since the provider's
    /// own schedule can change. Concurrency across all channels is capped at 2
    /// (`xtreamEPGGate`): these fire from scrolling, and an unbounded burst of newly-visible
    /// rows would hammer the provider for no benefit. See MatchLinker/PROMPTS.md, Prompt 4 step 5.
    private func requestXtreamEPGIfNeeded(channelId: String, from: Date, to: Date, fullSchedule: Bool) {
        guard let fetcher = xtreamEPGFetcher,
              let canonical = canonicalChannelsByID[channelId],
              let providerChannelId = canonical.primaryStream?.providerChannelId else { return }
        let epgId = "xtream:\(providerChannelId)"
        let taskKey = "\(providerChannelId)-\(fullSchedule)"
        let fetchedRecently = xtreamEPGFetchedAt[taskKey].map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        let hasCoverage = fetchedRecently && (programmeIndex[channelId]?.contains { prog in
            prog.epgChannelId == epgId && prog.end > from && prog.start < to
        } ?? false)
        guard !hasCoverage else { return }
        guard !xtreamEPGTasks.contains(taskKey) else { return }
        xtreamEPGTasks.insert(taskKey)
        Task { [weak self] in
            defer { self?.xtreamEPGTasks.remove(taskKey) }
            await Self.xtreamEPGGate.acquire()
            defer { Task { await Self.xtreamEPGGate.release() } }
            guard let self else { return }
            let fetched = await fetcher(providerChannelId, fullSchedule)
            self.xtreamEPGFetchedAt[taskKey] = Date()
            guard !fetched.isEmpty else { return }
            var topUp: [EPGProgramme] = []
            for var prog in fetched where prog.isValid {
                prog.canonicalChannelId = channelId
                topUp.append(prog)
            }
            self.mergeTopUp(topUp, channelId: channelId)
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

    /// How long a guide refresh is trusted before the next one.
    private static let guideStaleness: TimeInterval = 6 * 3600

    /// True when a playlist's guide has never been downloaded (no `custom-N.xml` cache yet).
    private func hasMissingCustomSource() -> Bool {
        customEPGURLs.indices.contains { index in
            !FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("custom-\(index).xml").path)
        }
    }

    func refreshIfNeeded() async {
        if !hasMissingCustomSource(), let last = lastUpdated, Date().timeIntervalSince(last) < Self.guideStaleness,
           !programmeIndex.isEmpty { return }
        await forceRefresh(origin: .automatic)
    }

    // MARK: - Cold start

    private var customMappingFile: URL { cacheDir.appendingPathComponent("custom-epg-mapping.json") }

    /// Remembers which guide channel went to which canonical channel (including name-matched ones
    /// that a tvg-id lookup can't reproduce) so the next cold launch can rebuild the guide.
    private func saveCustomEPGMapping(_ mapping: [String: String]) {
        let file = customMappingFile
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(mapping) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    /// On a cold launch whose last refresh is still fresh, rebuilds the guide from the durable
    /// store instead of re-parsing the cached XML (tens of megabytes) before the guide has
    /// anything to show. `refreshIfNeeded` then finds a populated index and leaves it alone until
    /// it goes stale. Skipped when anything needed is missing; the normal refresh then runs.
    private func hydrateProgrammesFromStore(generation: UUID) async {
        guard programmeIndex.isEmpty,
              !customEPGURLs.isEmpty,
              !hasMissingCustomSource(),
              let last = lastUpdated, Date().timeIntervalSince(last) < Self.guideStaleness else { return }

        let now = Date()
        let stored = (try? await EPGProgrammeStore.shared.snapshot(
            from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(72 * 3600)
        )) ?? []
        guard !stored.isEmpty else { return }

        let lookup = customEPGLookup
        let channelToCanonical = channelToCanonicalMap
        let mappingFile = customMappingFile
        let hydrated = await Task.detached(priority: .utility) { () -> [String: [EPGProgramme]] in
            let saved = (try? Data(contentsOf: mappingFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            let currentCanonicalIds = Set(channelToCanonical.values)
            let customProgrammes = stored.filter { $0.sourceId.hasPrefix("custom-") }
            return GuideProgrammeIndexing.hydrated(from: customProgrammes) { guideId in
                if let canonicalId = saved[guideId], currentCanonicalIds.contains(canonicalId) { return canonicalId }
                return lookup.tvgIdToProvider[guideId.lowercased()].flatMap { channelToCanonical[$0] }
            }
        }.value

        // A newer import, or a refresh that got there first, owns the index now.
        guard !Task.isCancelled, importGeneration == generation, programmeIndex.isEmpty, !hydrated.isEmpty else { return }
        programmeIndex = hydrated
        programmeRevision &+= 1
        rebuildCoverageIndex()
        let programmeCount = hydrated.values.reduce(0) { $0 + $1.count }
        importProgress.programmesRetained = programmeCount
        logger.info("Guide restored from store channels=\(hydrated.count, privacy: .public) programmes=\(programmeCount, privacy: .public)")
    }

    func forceRefresh(origin: RefreshOrigin = .userInitiated) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshOrigin = origin
        refreshState = .refreshing
        importProgress.state = .loadingEPG
        defer { isRefreshing = false }
        await curatedConfigTask?.value

        let activeCategoryIds = Set(canonicalChannels.map(\.categoryId))
        // Off by default — see EPGPWSourcePolicy. `sources` empty makes both task groups
        // below no-ops without touching their control flow.
        let sources = EPGPWSourcePolicy.epgShareFallbackEnabled ? EPGSourceRegistry.sources(for: activeCategoryIds) : []

        let now = Date()
        // -6h/+72h per MatchLinker/PROMPTS.md, Prompt 3 step 2 — the old -14h/+36h window is
        // exactly what Prompt 2's "Why" calls out as a bug: most guide ids in a real Xtream
        // playlist reach 12-72h ahead, and a game starting later than +36h had its own listing
        // silently discarded even when the provider's guide carried it.
        let programmeWindow = now.addingTimeInterval(-6 * 3600)...now.addingTimeInterval(72 * 3600)

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
            // Parsing and channel matching both run off the main actor: matching normalises
            // names (a dozen regex passes each) for every guide channel that has no tvg-id hit.
            let lookup = customEPGLookup
            let channelToCanonical = channelToCanonicalMap
            let normalizer = self.normalizer
            let outcome = await Task.detached(priority: .utility) { () -> (result: EPGParseResult, mapping: [String: CustomEPGMatch]) in
                let result = EPGXMLParser(sourceId: sourceId, priority: 0).parse(data: data, programmeWindow: programmeWindow)
                guard let normalizer else { return (result, [:]) }
                let mapping = CustomEPGMatcher.match(
                    result.channels, lookup: lookup, channelToCanonical: channelToCanonical, normalize: normalizer.normalize
                )
                return (result, mapping)
            }.value
            importDiagnostics.epgChannelParseDuration += Date().timeIntervalSince(started)
            let parseResult = outcome.result
            let mapping = outcome.mapping
            guard !mapping.isEmpty else { continue }
            programmeIndex = GuideProgrammeIndexing.removing(sourceId: sourceId, from: programmeIndex)
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
            saveCustomEPGMapping(customChannelMappings.mapValues(\.canonicalChannelId))
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
            // forceRefresh() sets .loadingEPG at the top and, before this fix, never set
            // anything but .cancelled afterward — every UI gated on importProgress.state
            // == .ready got stuck showing "loading" after the first scheduled refresh fired
            // (which happens automatically moments after the initial import; see
            // setupWithChannels). See MatchLinker/PROMPTS.md, Prompt 3 step 5.
            self.importProgress.state = .ready
        }
    }

    // MARK: - Download + Parse

    private func epgData(for source: EPGSource) async -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("\(source.id).xml")

        // Check disk cache freshness
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < source.cacheTTL,
           let data = try? Data(contentsOf: cacheFile, options: .mappedIfSafe) {
            return data
        }

        // Download — streamed straight to a temp file so the response body is never
        // held as a second in-memory copy on top of whatever URLSession buffers internally.
        do {
            let downloadStart = Date()
            let signpost = GuideMatchingSignposts.beginGuideDownload()
            defer { GuideMatchingSignposts.endGuideDownload(signpost) }
            let (tempURL, response) = try await downloadSession(
                hasCachedCopy: FileManager.default.fileExists(atPath: cacheFile.path)
            ).download(from: source.url)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            importDiagnostics.epgDownloadDuration += Date().timeIntervalSince(downloadStart)
            // An error page (403/500...) is not a guide: don't let it replace the good cache
            // and restart its freshness clock. A file URL has no status to check.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GuideDownloadError.badStatus
            }
            let raw = try Data(contentsOf: tempURL, options: .mappedIfSafe)
            guard let decompressed = await Task.detached(priority: .utility, operation: { raw.gunzippedIfNeeded() }).value else {
                throw GuideDownloadError.undecodable
            }
            // Atomic, so a kill mid-write can't leave a truncated file with a fresh timestamp.
            try decompressed.write(to: cacheFile, options: .atomic)
            return decompressed
        } catch {
            // Network failure or unusable response: use the cached file even if stale
            return try? Data(contentsOf: cacheFile, options: .mappedIfSafe)
        }
    }

    private func cachedEPGData(for source: EPGSource) -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("\(source.id).xml")
        return try? Data(contentsOf: cacheFile, options: .mappedIfSafe)
    }

    /// Downloads (or serves from cache) the XMLTV file a playlist advertises via
    /// `x-tvg-url` (M3U) or `xmltv.php` (Xtream). Cache filename matches the
    /// `custom-N.xml` convention `refreshIfNeeded()` checks for staleness.
    ///
    /// Once the TTL expires, still sends `If-None-Match`/`If-Modified-Since` from the last
    /// response (sidecar `custom-N.etag.json`) — an 86 MB+ guide that hasn't actually changed
    /// costs a 304 instead of a full re-download. See MatchLinker/PROMPTS.md, Prompt 3 step 2.
    private func customEPGData(url: URL, index: Int) async -> Data? {
        let cacheFile = cacheDir.appendingPathComponent("custom-\(index).xml")
        let metaFile = cacheDir.appendingPathComponent("custom-\(index).etag.json")
        let ttl: TimeInterval = 6 * 3600

        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < ttl,
           let data = try? Data(contentsOf: cacheFile, options: .mappedIfSafe) {
            return data
        }

        struct CacheValidators: Codable { var etag: String?; var lastModified: String? }
        // A 304 is only useful with a cached copy to fall back on; without one, ask for the whole file.
        let hasCachedCopy = FileManager.default.fileExists(atPath: cacheFile.path)
        let validators = hasCachedCopy
            ? (try? Data(contentsOf: metaFile)).flatMap { try? JSONDecoder().decode(CacheValidators.self, from: $0) }
            : nil

        var request = URLRequest(url: url)
        if let etag = validators?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = validators?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let downloadStart = Date()
            let signpost = GuideMatchingSignposts.beginGuideDownload()
            defer { GuideMatchingSignposts.endGuideDownload(signpost) }
            let (tempURL, response) = try await downloadSession(hasCachedCopy: hasCachedCopy).download(for: request)
            importDiagnostics.epgDownloadDuration += Date().timeIntervalSince(downloadStart)

            if let http = response as? HTTPURLResponse, http.statusCode == 304 {
                try? FileManager.default.removeItem(at: tempURL)
                // Reset the TTL clock without touching the (unchanged) cached content.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheFile.path)
                return try? Data(contentsOf: cacheFile, options: .mappedIfSafe)
            }

            defer { try? FileManager.default.removeItem(at: tempURL) }
            // An error page (403/500...) is not a guide: keep the good cache and its clock.
            let http = response as? HTTPURLResponse
            if let http, !(200..<300).contains(http.statusCode) {
                throw GuideDownloadError.badStatus
            }
            let raw = try Data(contentsOf: tempURL, options: .mappedIfSafe)
            guard let decompressed = await Task.detached(priority: .utility, operation: { raw.gunzippedIfNeeded() }).value else {
                throw GuideDownloadError.undecodable
            }
            try decompressed.write(to: cacheFile, options: .atomic)
            let newValidators = CacheValidators(
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
            )
            try? JSONEncoder().encode(newValidators).write(to: metaFile, options: .atomic)
            return decompressed
        } catch {
            return try? Data(contentsOf: cacheFile, options: .mappedIfSafe)
        }
    }

    // MARK: - EPG Channel Matching

    private func matchEPGChannels(_ epgChannels: [EPGChannel]) {
        // Nothing to match (the generic broadcaster feeds are off in release builds): don't
        // renormalise every canonical name and curated alias just to reach the same empty result.
        guard !epgChannels.isEmpty else {
            epgToCanonical = [:]
            return
        }
        guard let channelNormalizer = normalizer else { return }
        // The same names recur across the canonical channels, aliases and EPG entries below.
        var normalizedNames: [String: String] = [:]
        func normalize(_ name: String) -> String {
            if let cached = normalizedNames[name] { return cached }
            let result = channelNormalizer.normalize(name)
            normalizedNames[name] = result
            return result
        }

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
                let normEpgId = normalize(epgId).lowercased()
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
            addCandidate(normalize(ch.name), ch.id)
            if let network = ch.network { addCandidate(network, ch.id) }
        }
        if let config {
            for curatedCh in config.channels {
                for alias in curatedCh.aliases {
                    addCandidate(alias, curatedCh.key)
                    addCandidate(normalize(alias), curatedCh.key)
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
            matched = resolve(epgCh.id) ?? resolve(normalize(epgCh.id))

            // 2. Try each display name
            if matched == nil {
                for displayName in epgCh.displayNames where !displayName.isEmpty {
                    if let canonId = resolve(displayName) ?? resolve(normalize(displayName)) {
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

        // Update canonical channels with their EPG ids. Invert the mapping once rather than
        // scanning it for every channel; the lowest id wins when several map to one channel.
        var epgIdForCanonical: [String: String] = [:]
        for epgId in newMapping.keys.sorted() {
            if let canonicalId = newMapping[epgId], epgIdForCanonical[canonicalId] == nil {
                epgIdForCanonical[canonicalId] = epgId
            }
        }
        var updated = canonicalChannels
        var changed = false
        for i in updated.indices {
            if let epgId = epgIdForCanonical[updated[i].id], updated[i].epgChannelId != epgId {
                updated[i].epgChannelId = epgId
                changed = true
            }
        }
        // Published here, not from an unstructured Task: that could land after a newer lineup
        // and overwrite it, and republishing an unchanged lineup only churns observers.
        if changed {
            canonicalChannels = updated
            rebuildChannelToCanonicalMap()
        }
    }

    // MARK: - Programme Index

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
            finalized[key] = GuideProgrammeIndexing.deduplicated(programmes.sorted { $0.start < $1.start })
        }
        programmeIndex = finalized
        programmeRevision &+= 1
        rebuildCoverageIndex()
        persistDebounceTask?.cancel()
        persistProgrammesToStore(finalized)
    }

    /// Folds one channel's on-demand programmes into its schedule. Unlike `finalizeProgrammeIndex`
    /// this touches only that channel: it doesn't re-sort every schedule, rebuild every coverage
    /// entry, bump the global revision (which would invalidate every cached guide row and rebuild
    /// stream links) or rewrite every source in SQLite per row fetched while scrolling.
    private func mergeTopUp(_ programmes: [EPGProgramme], channelId: String) {
        guard !programmes.isEmpty else { return }
        let merged = GuideProgrammeIndexing.merged(programmeIndex[channelId] ?? [], adding: programmes)
        programmeIndex[channelId] = merged
        coverageIndex[channelId] = GuideProgrammeIndexing.coverage(of: merged, channelId: channelId)
        channelTopUpRevisions[channelId, default: 0] &+= 1
        schedulePersist()
    }

    /// One write of the whole index once top-ups stop arriving, instead of one per row.
    private func schedulePersist() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistProgrammesToStore(self.programmeIndex)
        }
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

    // MARK: - Coverage API

    /// Returns the coverage range for a canonical channel, or nil if no programmes are indexed.
    func coverage(for channelId: String) -> ProgrammeCoverage? {
        coverageIndex[channelId]
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

        var joins: [ProgrammeEventJoin] = []
        for (channelId, schedule) in programmeIndex {
            let channelNet    = channelNetworkByID[channelId]
            let networkMatches = channelNet.map { networkSet.contains($0) } ?? false

            // Schedules are sorted, so only the window's slice of each is visited.
            for programme in GuideProgrammeIndexing.overlapping(schedule, from: windowStart, to: windowEnd) {
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
        var networks: [String: String] = [:]
        for channel in canonicalChannels {
            if let network = channel.network { networks[channel.id] = network.lowercased() }
        }
        channelNetworkByID = networks
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
    func canonicalChannel(forProviderChannelID id: String, playlistID: UUID? = nil) -> CanonicalChannel? {
        guard let canonical = channelToCanonicalMap[id].flatMap({ canonicalChannelsByID[$0] }) else { return nil }
        if let playlistID {
            // Provider IDs can be reused by another account. Ambiguous mappings must not
            // give playback the wrong feed's mirrors or programme information.
            guard canonical.allStreams.contains(where: { $0.providerChannelId == id && $0.playlistID == playlistID }) else { return nil }
        }
        return canonical
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
