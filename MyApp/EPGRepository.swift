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
    @Published private(set) var refreshState: EPGRefreshState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var importProgress = LiveTVImportProgress()
    @Published private(set) var importDiagnostics = LiveTVImportDiagnostics()

    // Programme index: canonicalChannelId -> [EPGProgramme] sorted by start
    private var programmeIndex: [String: [EPGProgramme]] = [:]
    // EPG channel id -> canonical channel id
    private var epgToCanonical: [String: String] = [:]

    private var config: CuratedGuideConfig?
    private var normalizer: ChannelNormalizer?
    private var matcher: CanonicalChannelMatcher?
    private var currentIPTVChannels: [Channel] = []
    private var refreshTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var epgpwPrefetchTasks: [String: Task<Void, Never>] = [:]
    private var epgpwDiagnostics: [String: EPGPWFetchResult] = [:]
    private var isRefreshing = false
    private var importGeneration = UUID()
    private var lastChannelFingerprint: String?

    private let epgpwMappings = EPGPWMappingRepository()
    private lazy var epgpwProvider = EPGPWProvider(cacheDir: cacheDir)
    private let logger = Logger(subsystem: "StadiaTV", category: "LiveTVImport")

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
        let fingerprint = Self.channelFingerprint(channels)
        if fingerprint == lastChannelFingerprint, setupTask != nil || !canonicalChannels.isEmpty {
            return
        }
        lastChannelFingerprint = fingerprint
        currentIPTVChannels = channels

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
            return CanonicalLineupBuildResult(channels: [], filteredStreams: 0, matchedStreams: 0, diagnostics: diagnostics)
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
            let normName = normalizer.normalize(channel.name)
            var stream = ChannelStream(
                id: channel.id,
                providerChannelId: channel.id,
                originalName: channel.name,
                normalizedName: normName,
                streamURL: channel.streamURL,
                tvgId: nil,
                tvgName: channel.name,
                tvgLogoURL: channel.logoURL,
                groupTitle: channel.group,
                resolution: StreamResolution.detect(from: channel.name),
                playlistID: channel.playlistID,
                playlistName: channel.playlistName
            )
            stream.countryHint = normalizer.extractCountryHint(from: channel.name)
            visible.append(stream)
        }
        diagnostics.prefilterDuration = Date().timeIntervalSince(prefilterStart)

        let matchStart = Date()
        var matches: [ChannelMatchResult] = []
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
            diagnostics: diagnostics
        )
    }

    // MARK: - EPG.pw Lazy Loading

    private func loadInitialEPGPWProgrammes(for channels: [CanonicalChannel]) async {
        guard EPGPWSourcePolicy.epgPWEnabled else { return }
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
              let channel = canonicalChannels.first(where: { $0.id == channelId }),
              epgpwMappings.mapping(for: channelId) != nil else { return }
        let hasCoverage = programmeIndex[channelId]?.contains { programme in
            programme.end > from && programme.start < to
        } ?? false
        guard !hasCoverage else { return }
        prefetchProgrammes(for: [channel])
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
                objectWillChange.send()
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
        let staleness: TimeInterval = 6 * 3600
        // Skip download if the cache is fresh AND the cache file exists on disk.
        // lastUpdated is loaded synchronously from UserDefaults at init time so this
        // check is valid even before the async disk-load of programmeIndex completes.
        if let last = lastUpdated, Date().timeIntervalSince(last) < staleness,
           FileManager.default.fileExists(atPath: programmeCacheURL.path) { return }
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

        var allEPGChannels: [EPGChannel] = []
        let now = Date()
        // Keep 14h of past data so the guide shows programmes from midnight today
        let programmeWindow = now.addingTimeInterval(-14 * 3600)...now.addingTimeInterval(36 * 3600)

        for source in sources {
            guard !Task.isCancelled else {
                refreshState = .idle
                importProgress.state = .cancelled
                return
            }
            guard let data = await epgData(for: source) else { continue }
            let started = Date()
            let result = await Task.detached(priority: .utility) {
                EPGXMLParser(sourceId: source.id, priority: source.priority)
                    .parse(data: data, channelsOnly: true)
            }.value
            importDiagnostics.epgChannelParseDuration += Date().timeIntervalSince(started)
            allEPGChannels.append(contentsOf: result.channels)
        }

        // Match EPG channels to canonical channels
        matchEPGChannels(allEPGChannels)
        let wantedEPGIds = Set(epgToCanonical.keys)
        importProgress.epgChannels = wantedEPGIds.count

        var programmeIndex = self.programmeIndex
        for source in sources {
            guard !Task.isCancelled else {
                refreshState = .idle
                importProgress.state = .cancelled
                return
            }
            guard let data = cachedEPGData(for: source), !wantedEPGIds.isEmpty else { continue }
            let started = Date()
            let parseResult = await Task.detached(priority: .utility) {
                EPGXMLParser(sourceId: source.id, priority: source.priority)
                    .parse(data: data, allowedChannelIds: wantedEPGIds, programmeWindow: programmeWindow)
            }.value
            importDiagnostics.epgProgrammeParseDuration += Date().timeIntervalSince(started)
            mergeProgrammes(parseResult.programmes, into: &programmeIndex)
        }
        finalizeProgrammeIndex(programmeIndex)
        importProgress.programmesRetained = programmeIndex.values.reduce(0) { $0 + $1.count }

        lastUpdated = Date()
        persistState()

        await MainActor.run {
            self.refreshState = .idle
            self.objectWillChange.send()
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

        // Download
        do {
            let downloadStart = Date()
            let (data, _) = try await session.data(from: source.url)
            importDiagnostics.epgDownloadDuration += Date().timeIntervalSince(downloadStart)
            let decompressed = await Task.detached(priority: .utility) {
                data.tryGunzip()
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

        // Also build a lookup from the curated config's aliases and explicit epg_id fields
        if let config {
            for curatedCh in config.channels {
                // Direct epg_id match: XMLTV channel id → canonical key
                if let epgId = curatedCh.epgId {
                    aliasToCanon[epgId.lowercased()] = curatedCh.key
                    let normEpgId = normalizer.normalize(epgId).lowercased()
                    if !normEpgId.isEmpty { aliasToCanon[normEpgId] = curatedCh.key }
                }
                for alias in curatedCh.aliases {
                    let norm = normalizer.normalize(alias).lowercased()
                    aliasToCanon[norm] = curatedCh.key
                    aliasToCanon[alias.lowercased()] = curatedCh.key
                }
            }
        }

        for epgCh in epgChannels {
            var matched: String?

            // 1. Try XMLTV channel id itself against the alias table (catches epg_id matches)
            let xmltvIdLow = epgCh.id.lowercased()
            matched = aliasToCanon[xmltvIdLow]
                ?? aliasToCanon[normalizer.normalize(epgCh.id).lowercased()]

            // 2. Try each display name
            if matched == nil {
                for displayName in epgCh.displayNames {
                    let norm = normalizer.normalize(displayName).lowercased()
                    if let canonId = aliasToCanon[norm] ?? aliasToCanon[displayName.lowercased()] {
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
        saveProgrammeIndex()
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
        return programmeIndex[channelId]?.first { $0.isOnNow(at: date) }
    }

    func nextProgramme(for channelId: String, after date: Date = Date()) -> EPGProgramme? {
        requestEPGPWIfNeeded(channelId: channelId, from: date, to: date.addingTimeInterval(12 * 3600))
        return programmeIndex[channelId]?.first { $0.start > date }
    }

    func programmes(for channelId: String, from: Date, to: Date) -> [EPGProgramme] {
        requestEPGPWIfNeeded(channelId: channelId, from: from, to: to)
        return programmeIndex[channelId]?.filter { $0.end > from && $0.start < to } ?? []
    }

    func hasProgrammes(for channelId: String) -> Bool {
        !(programmeIndex[channelId]?.isEmpty ?? true)
    }

    // MARK: - Persistence

    private var programmeCacheURL: URL {
        cacheDir.appendingPathComponent("programmeIndex.v2.json")
    }

    private func loadCachedState() {
        if let ts = UserDefaults.standard.object(forKey: lastUpdatedKey) as? Date {
            lastUpdated = ts
        }
        // Load persisted programme index from disk in the background so the guide
        // can show cached data immediately without blocking the main thread.
        let url = programmeCacheURL
        Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                Self.loadIndexFromDisk(url: url)
            }.value
            guard let self, !index.isEmpty else { return }
            self.programmeIndex = index
            self.objectWillChange.send()
        }
    }

    private func persistState() {
        UserDefaults.standard.set(lastUpdated, forKey: lastUpdatedKey)
    }

    nonisolated private static func loadIndexFromDisk(url: URL) -> [String: [EPGProgramme]] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: [EPGProgramme]].self, from: data) else {
            return [:]
        }
        // Discard programmes from more than 14 hours in the past.
        let cutoff = Date().addingTimeInterval(-14 * 3600)
        var result: [String: [EPGProgramme]] = [:]
        for (key, progs) in index {
            let valid = progs.filter { $0.end > cutoff }
            if !valid.isEmpty { result[key] = valid }
        }
        return result
    }

    private func saveProgrammeIndex() {
        let index = programmeIndex
        let url = programmeCacheURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(index) else { return }
            try? data.write(to: url, options: .atomic)
        }
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
