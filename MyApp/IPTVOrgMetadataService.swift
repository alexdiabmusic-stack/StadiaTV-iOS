import Foundation

// MARK: - Pre-built index snapshot (value type, safe to share across threads)

struct IPTVOrgIndexes {
    let channelByExactId: [String: IPTVOrgChannel]
    let channelByCaseFoldedId: [String: IPTVOrgChannel]
    let channelsByNormalizedName: [String: [IPTVOrgChannel]]
    let channelsByAltName: [String: [IPTVOrgChannel]]
    let channelsByCountry: [String: [IPTVOrgChannel]]
    let channelsByNetwork: [String: [IPTVOrgChannel]]
    let logosByExactChannelId: [String: [IPTVOrgLogo]]
    let logosByCaseFoldedChannelId: [String: [IPTVOrgLogo]]

    nonisolated var isLoaded: Bool { !channelByExactId.isEmpty }
    nonisolated var channelCount: Int { channelByExactId.count }
    nonisolated var logoCount: Int { logosByExactChannelId.values.reduce(0) { $0 + $1.count } }

    nonisolated static let empty = IPTVOrgIndexes(
        channelByExactId: [:], channelByCaseFoldedId: [:],
        channelsByNormalizedName: [:], channelsByAltName: [:],
        channelsByCountry: [:], channelsByNetwork: [:],
        logosByExactChannelId: [:], logosByCaseFoldedChannelId: [:]
    )
}

// MARK: - IPTV-org Metadata Service

actor IPTVOrgMetadataService {

    private(set) var indexes: IPTVOrgIndexes = .empty
    private var loadError: String?
    private let cacheDir: URL
    private let session: URLSession

    static let shared = IPTVOrgMetadataService()

    init() {
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StadiaTV_Metadata", isDirectory: true)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    /// Load from pre-decoded Data (e.g. local fixture files or cached data).
    func loadFromData(channelsData: Data, logosData: Data, normalizer: ChannelNormalizer? = nil) throws {
        let decoder = JSONDecoder()
        let channels = try decoder.decode([IPTVOrgChannel].self, from: channelsData)
        let logos = try decoder.decode([IPTVOrgLogo].self, from: logosData)
        indexes = buildIndexes(channels: channels, logos: logos, normalizer: normalizer)
    }

    /// Load from local file URLs (development fixtures).
    func loadFromFiles(channelsURL: URL, logosURL: URL, normalizer: ChannelNormalizer? = nil) async throws {
        let channelsData = try Data(contentsOf: channelsURL)
        let logosData = try Data(contentsOf: logosURL)
        try loadFromData(channelsData: channelsData, logosData: logosData, normalizer: normalizer)
    }

    /// Load from remote URLs with disk cache (production path). 7-day TTL.
    func loadFromRemoteIfNeeded(normalizer: ChannelNormalizer? = nil) async {
        guard !indexes.isLoaded else { return }

        let channelsCacheFile = cacheDir.appendingPathComponent("iptv_org_channels.json")
        let logosCacheFile = cacheDir.appendingPathComponent("iptv_org_logos.json")

        let channelsData = await cachedOrFetch(
            url: MetadataSourceRegistry.iptvOrgChannels.remoteURL,
            cacheFile: channelsCacheFile,
            ttl: MetadataSourceRegistry.iptvOrgChannels.cacheTTL
        )
        let logosData = await cachedOrFetch(
            url: MetadataSourceRegistry.iptvOrgLogos.remoteURL,
            cacheFile: logosCacheFile,
            ttl: MetadataSourceRegistry.iptvOrgLogos.cacheTTL
        )

        guard let cd = channelsData, let ld = logosData else {
            loadError = "Failed to load IPTV-org metadata"
            return
        }

        do {
            try loadFromData(channelsData: cd, logosData: ld, normalizer: normalizer)
        } catch {
            loadError = "Parse error: \(error.localizedDescription)"
        }
    }

    // MARK: - Channel Lookup (O(1))

    func channel(forId id: String) -> IPTVOrgChannel? {
        indexes.channelByExactId[id] ?? indexes.channelByCaseFoldedId[id.lowercased()]
    }

    func channel(forEpgId epgId: String) -> IPTVOrgChannel? {
        indexes.channelByExactId[epgId] ?? indexes.channelByCaseFoldedId[epgId.lowercased()]
    }

    func channels(forNormalizedName name: String, country: String? = nil) -> [IPTVOrgChannel] {
        let candidates = indexes.channelsByNormalizedName[name.lowercased()] ?? []
        guard let country, !country.isEmpty else { return candidates }
        return candidates.filter { $0.country.uppercased() == country.uppercased() }
    }

    func channels(forAltName altName: String, country: String? = nil) -> [IPTVOrgChannel] {
        let candidates = indexes.channelsByAltName[altName.lowercased()] ?? []
        guard let country, !country.isEmpty else { return candidates }
        return candidates.filter { $0.country.uppercased() == country.uppercased() }
    }

    /// Follow the replacement chain (closed → replaced_by) up to maxDepth hops.
    func followReplacementChain(from id: String, maxDepth: Int = 3) -> IPTVOrgChannel? {
        var current = channel(forId: id)
        var seen = Set<String>([id])
        var depth = 0
        while let ch = current, let replId = ch.replacedBy, !replId.isEmpty, depth < maxDepth {
            guard !seen.contains(replId) else { break }
            seen.insert(replId)
            current = channel(forId: replId)
            depth += 1
        }
        return current
    }

    // MARK: - Logo Resolution

    func bestLogo(forChannelId channelId: String, preferredFeed: String? = nil) -> IPTVOrgLogo? {
        let raw = indexes.logosByExactChannelId[channelId]
            ?? indexes.logosByCaseFoldedChannelId[channelId.lowercased()]
            ?? []
        let candidates = raw.filter { $0.isSupported }
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { a, b in rankLogo(a, vs: b, preferredFeed: preferredFeed) }.first
    }

    private func rankLogo(_ a: IPTVOrgLogo, vs b: IPTVOrgLogo, preferredFeed: String?) -> Bool {
        // 1. in_use wins
        if a.inUse != b.inUse { return a.inUse }
        // 2. preferred feed exact match wins
        if let pf = preferredFeed {
            let am = a.feed == pf; let bm = b.feed == pf
            if am != bm { return am }
        }
        // 3. null feed (generic) preferred when no specific feed known
        if preferredFeed == nil {
            let aNil = a.feed == nil; let bNil = b.feed == nil
            if aNil != bNil { return aNil }
        }
        // 4. Format preference: PNG > WEBP > JPEG > SVG
        func rank(_ f: String?) -> Int {
            switch f?.uppercased() {
            case "PNG": return 4; case "WEBP": return 3
            case "JPEG", "JPG": return 2; case "SVG": return 1; default: return 0
            }
        }
        if rank(a.format) != rank(b.format) { return rank(a.format) > rank(b.format) }
        // 5. Non-zero dimensions preferred (but zero is not a disqualifier)
        let aHasDim = a.width > 0 && a.height > 0
        let bHasDim = b.width > 0 && b.height > 0
        if aHasDim != bHasDim { return aHasDim }
        return false
    }

    // MARK: - O(n) index building

    private func buildIndexes(
        channels: [IPTVOrgChannel],
        logos: [IPTVOrgLogo],
        normalizer: ChannelNormalizer?
    ) -> IPTVOrgIndexes {

        var byExact: [String: IPTVOrgChannel] = [:]
        var byLower: [String: IPTVOrgChannel] = [:]
        var byNormName: [String: [IPTVOrgChannel]] = [:]
        var byAlt: [String: [IPTVOrgChannel]] = [:]
        var byCountry: [String: [IPTVOrgChannel]] = [:]
        var byNetwork: [String: [IPTVOrgChannel]] = [:]

        byExact.reserveCapacity(channels.count)
        byLower.reserveCapacity(channels.count)

        for ch in channels {
            byExact[ch.id] = ch
            byLower[ch.id.lowercased()] = ch

            let normName = normalizer?.normalize(ch.name).lowercased() ?? ch.name.lowercased()
            byNormName[normName, default: []].append(ch)

            for alt in ch.altNames {
                let altLow = alt.lowercased()
                byAlt[altLow, default: []].append(ch)
                let normAlt = normalizer?.normalize(alt).lowercased() ?? altLow
                if normAlt != altLow { byAlt[normAlt, default: []].append(ch) }
            }

            byCountry[ch.country.uppercased(), default: []].append(ch)

            if let net = ch.network {
                byNetwork[net.lowercased(), default: []].append(ch)
            }
        }

        var byLogoExact: [String: [IPTVOrgLogo]] = [:]
        var byLogoLower: [String: [IPTVOrgLogo]] = [:]
        byLogoExact.reserveCapacity(logos.count)

        for logo in logos {
            byLogoExact[logo.channel, default: []].append(logo)
            byLogoLower[logo.channel.lowercased(), default: []].append(logo)
        }

        return IPTVOrgIndexes(
            channelByExactId: byExact,
            channelByCaseFoldedId: byLower,
            channelsByNormalizedName: byNormName,
            channelsByAltName: byAlt,
            channelsByCountry: byCountry,
            channelsByNetwork: byNetwork,
            logosByExactChannelId: byLogoExact,
            logosByCaseFoldedChannelId: byLogoLower
        )
    }

    // MARK: - HTTP cache helper

    private func cachedOrFetch(url: URL, cacheFile: URL, ttl: TimeInterval) async -> Data? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < ttl,
           let data = try? Data(contentsOf: cacheFile) {
            return data
        }
        do {
            let (data, _) = try await session.data(from: url)
            try? data.write(to: cacheFile)
            return data
        } catch {
            return try? Data(contentsOf: cacheFile)  // stale fallback
        }
    }
}
