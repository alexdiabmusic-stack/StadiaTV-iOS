import Foundation

// MARK: - Match result

struct ChannelMatchResult {
    let stream: ChannelStream
    let canonicalChannelKey: String
    let matchMethod: EPGMatchMethod
    let confidence: Double
    let iptvOrgChannelId: String?
    let conflicts: [IdentityConflict]

    var isHighConfidence: Bool { confidence >= 0.85 }
}

// MARK: - Matcher

/// Matches raw IPTV ChannelStreams to canonical channels defined in the curated JSON,
/// optionally enriched with IPTV-org identity metadata.
nonisolated final class CanonicalChannelMatcher {

    private let config: CuratedGuideConfig
    private let normalizer: ChannelNormalizer
    private let fuzzyThreshold: Double

    // Curated fast lookup tables (built at init)
    private var aliasToCandidateKey: [String: String] = [:]
    private var normalizedNameToKey: [String: String] = [:]
    private var networkMarketToKey: [String: String] = [:]
    private var epgIdToKey: [String: String] = [:]
    private var curatedByKey: [String: CuratedChannel] = [:]
    private var fuzzyCandidates: [FuzzyCandidate] = []
    private let maxFuzzyCandidatesPerStream = 100

    // Optional IPTV-org indexes for extended matching
    private var iptvOrgIndexes: IPTVOrgIndexes = .empty

    private struct FuzzyCandidate {
        let name: String
        let key: String
        let firstToken: String
        let bigrams: Set<String>
    }

    init(config: CuratedGuideConfig, normalizer: ChannelNormalizer, iptvOrgIndexes: IPTVOrgIndexes = .empty) {
        self.config = config
        self.normalizer = normalizer
        self.fuzzyThreshold = config.deduplication.fuzzyThreshold
        self.iptvOrgIndexes = iptvOrgIndexes
        buildLookups()
    }

    func updateIPTVOrgIndexes(_ indexes: IPTVOrgIndexes) {
        iptvOrgIndexes = indexes
    }

    private func buildLookups() {
        for channel in config.channels {
            curatedByKey[channel.key] = channel
            let normName = normalizer.normalize(channel.name).lowercased()
            normalizedNameToKey[normName] = channel.key
            // Also index the space-augmented variant (e.g. "RDS2" ↔ "RDS 2")
            for variant in alphaNumericVariants(of: normName) {
                normalizedNameToKey[variant] = channel.key
            }

            for alias in channel.aliases {
                let aliasLow = alias.lowercased()
                aliasToCandidateKey[aliasLow] = channel.key
                let normAlias = normalizer.normalize(alias).lowercased()
                aliasToCandidateKey[normAlias] = channel.key
                for variant in alphaNumericVariants(of: aliasLow) {
                    aliasToCandidateKey[variant] = channel.key
                }
            }

            if let network = channel.network, let market = channel.market {
                networkMarketToKey["\(network.lowercased())|\(market.lowercased())"] = channel.key
            }

            if let epgId = channel.epgId {
                epgIdToKey[epgId.lowercased()] = channel.key
            }
        }
        let candidates = normalizedNameToKey.merging(aliasToCandidateKey) { first, _ in first }
        fuzzyCandidates = candidates.map { name, key in
            FuzzyCandidate(
                name: name,
                key: key,
                firstToken: name.split(separator: " ").first.map(String.init) ?? name,
                bigrams: bigrams(name)
            )
        }
    }

    /// Generates space-toggled variants for alpha+digit boundaries.
    /// "rds2" → ["rds 2"] and "rds 2" → ["rds2"]
    private func alphaNumericVariants(of s: String) -> [String] {
        // Insert space before a digit that follows a letter
        let withSpace = s.replacingOccurrences(of: #"([a-z])(\d)"#, with: "$1 $2",
            options: .regularExpression)
        // Remove space between letter and digit
        let withoutSpace = s.replacingOccurrences(of: #"([a-z]) (\d)"#, with: "$1$2",
            options: .regularExpression)
        var variants: [String] = []
        if withSpace != s { variants.append(withSpace) }
        if withoutSpace != s { variants.append(withoutSpace) }
        return variants
    }

    // MARK: - Primary match entry point

    func match(_ stream: ChannelStream) -> ChannelMatchResult? {
        let countryHint = stream.countryHint ?? normalizer.extractCountryHint(from: stream.originalName)
        let normOrig = normalizer.normalize(stream.originalName).lowercased()
        let normStream = stream.normalizedName.lowercased()
        let effectiveNorm = normOrig.isEmpty ? normStream : normOrig

        // 1. Manual override (future: check UserDefaults override table)

        // 2. Provider EPG ID / tvg-id  → curated epg_id lookup (exact)
        if let tvgId = stream.tvgId, !tvgId.isEmpty {
            if let key = epgIdToKey[tvgId.lowercased()] {
                return ChannelMatchResult(stream: stream, canonicalChannelKey: key,
                                          matchMethod: .providerEpgExact, confidence: 0.95,
                                          iptvOrgChannelId: nil, conflicts: [])
            }
            // 2b. Provider EPG ID → IPTV-org → curated
            if let result = matchViaIPTVOrg(epgId: tvgId, stream: stream,
                                             effectiveNorm: effectiveNorm, countryHint: countryHint) {
                return result
            }
        }

        // 3. Exact alias (original name)
        let origLower = stream.originalName.lowercased().trimmingCharacters(in: .whitespaces)
        if let key = aliasToCandidateKey[origLower] {
            return ChannelMatchResult(stream: stream, canonicalChannelKey: key,
                                      matchMethod: .exactAlias, confidence: 1.0,
                                      iptvOrgChannelId: nil, conflicts: [])
        }

        // 4. Normalized alias
        if let key = aliasToCandidateKey[effectiveNorm] {
            return ChannelMatchResult(stream: stream, canonicalChannelKey: key,
                                      matchMethod: .exactAlias, confidence: 0.95,
                                      iptvOrgChannelId: nil, conflicts: [])
        }

        // 5. Normalized name exact
        if let key = normalizedNameToKey[effectiveNorm] ?? normalizedNameToKey[normStream] {
            let conf = countryConfidence(forKey: key, countryHint: countryHint, base: 0.90)
            return ChannelMatchResult(stream: stream, canonicalChannelKey: key,
                                      matchMethod: .normalizedExact, confidence: conf,
                                      iptvOrgChannelId: nil, conflicts: [])
        }

        // 6. IPTV-org normalized name → curated lookup (country-filtered)
        if iptvOrgIndexes.isLoaded,
           let result = matchViaIPTVOrgName(effectiveNorm: effectiveNorm, stream: stream, countryHint: countryHint) {
            return result
        }

        // 7. Network + market
        if let network = stream.groupTitle, !network.isEmpty {
            let netLower = network.lowercased()
            for (nmKey, canonKey) in networkMarketToKey {
                if nmKey.hasPrefix(netLower + "|") {
                    return ChannelMatchResult(stream: stream, canonicalChannelKey: canonKey,
                                              matchMethod: .networkMarket, confidence: 0.80,
                                              iptvOrgChannelId: nil, conflicts: [])
                }
            }
        }

        // 8. Fuzzy bigram match (last resort)
        if let result = fuzzyMatch(effectiveNorm) {
            return ChannelMatchResult(stream: stream, canonicalChannelKey: result.key,
                                      matchMethod: .fuzzy, confidence: result.score,
                                      iptvOrgChannelId: nil, conflicts: [])
        }

        return nil
    }

    // MARK: - IPTV-org EPG ID bridge

    private func matchViaIPTVOrg(
        epgId: String, stream: ChannelStream,
        effectiveNorm: String, countryHint: String?
    ) -> ChannelMatchResult? {
        guard iptvOrgIndexes.isLoaded else { return nil }

        let isExact = iptvOrgIndexes.channelByExactId[epgId] != nil
        let iptvCh = iptvOrgIndexes.channelByExactId[epgId]
            ?? iptvOrgIndexes.channelByCaseFoldedId[epgId.lowercased()]

        guard var iptvChannel = iptvCh else {
            // Try following replacement chain
            if let replaced = followReplacementChain(from: epgId) {
                return matchIPTVChannelToCurated(
                    iptvChannel: replaced, stream: stream,
                    effectiveNorm: effectiveNorm, countryHint: countryHint,
                    method: .replacementChain, baseConfidence: 0.70
                )
            }
            return nil
        }

        // If IPTV-org channel is closed and has replacement, prefer the replacement
        if iptvChannel.isClosed, let replaced = followReplacementChain(from: iptvChannel.replacedBy ?? "") {
            iptvChannel = replaced
        }

        let method: EPGMatchMethod = isExact ? .providerEpgExact : .providerEpgCaseInsensitive
        let baseConf: Double = isExact ? 0.90 : 0.85

        return matchIPTVChannelToCurated(
            iptvChannel: iptvChannel, stream: stream,
            effectiveNorm: effectiveNorm, countryHint: countryHint,
            method: method, baseConfidence: baseConf
        )
    }

    private func matchIPTVChannelToCurated(
        iptvChannel: IPTVOrgChannel, stream: ChannelStream,
        effectiveNorm: String, countryHint: String?,
        method: EPGMatchMethod, baseConfidence: Double
    ) -> ChannelMatchResult? {
        // Find curated canonical from IPTV-org channel name
        let normIPTVName = normalizer.normalize(iptvChannel.name).lowercased()
        var key = normalizedNameToKey[normIPTVName]
            ?? aliasToCandidateKey[normIPTVName]
            ?? aliasToCandidateKey[iptvChannel.name.lowercased()]

        // Try alt names as fallback
        if key == nil {
            for alt in iptvChannel.altNames {
                let normAlt = normalizer.normalize(alt).lowercased()
                if let k = aliasToCandidateKey[normAlt] ?? normalizedNameToKey[normAlt] {
                    key = k; break
                }
            }
        }

        guard let canonKey = key else { return nil }

        var confidence = baseConfidence
        var conflicts: [IdentityConflict] = []

        // Country agreement check
        let curatedChannel = curatedByKey[canonKey]
        if let curated = curatedChannel {
            let iptvCountry = iptvChannel.country.uppercased()
            let curatedCountry = curated.country.uppercased()
            if iptvCountry != curatedCountry {
                confidence -= 0.15
                conflicts.append(IdentityConflict(field: "country",
                                                   expected: curatedCountry, actual: iptvCountry))
            }
        }

        // Name agreement between provider stream and IPTV-org name
        let normIPTV = normIPTVName
        if !effectiveNorm.isEmpty && !normIPTV.isEmpty && normIPTV != effectiveNorm {
            let similarity = jaccard(bigrams(normIPTV), bigrams(effectiveNorm))
            if similarity < 0.4 {
                confidence -= 0.10
                conflicts.append(IdentityConflict(field: "name",
                                                   expected: iptvChannel.name, actual: stream.originalName))
            }
        }

        // Apply country hint penalty
        if let hint = countryHint, let curated = curatedChannel {
            if hint.uppercased() != curated.country.uppercased() {
                confidence -= 0.10
            }
        }

        guard confidence > 0.3 else { return nil }

        return ChannelMatchResult(
            stream: stream, canonicalChannelKey: canonKey,
            matchMethod: method, confidence: confidence,
            iptvOrgChannelId: iptvChannel.id, conflicts: conflicts
        )
    }

    private func matchViaIPTVOrgName(
        effectiveNorm: String, stream: ChannelStream, countryHint: String?
    ) -> ChannelMatchResult? {
        // Check IPTV-org normalized name index, country-filtered when available
        let candidates = iptvOrgIndexes.channelsByNormalizedName[effectiveNorm] ?? []
        let filtered = countryHint != nil
            ? candidates.filter { $0.country.uppercased() == countryHint!.uppercased() }
            : candidates
        let pool = filtered.isEmpty ? candidates : filtered

        guard let iptvCh = pool.first else { return nil }

        return matchIPTVChannelToCurated(
            iptvChannel: iptvCh, stream: stream,
            effectiveNorm: effectiveNorm, countryHint: countryHint,
            method: .iptvOrgExactId, baseConfidence: 0.82
        )
    }

    private func followReplacementChain(from id: String, maxDepth: Int = 3) -> IPTVOrgChannel? {
        var currentId = id
        var seen = Set<String>([id])
        var depth = 0
        while depth < maxDepth {
            guard let ch = iptvOrgIndexes.channelByExactId[currentId]
                    ?? iptvOrgIndexes.channelByCaseFoldedId[currentId.lowercased()] else { break }
            guard let replId = ch.replacedBy, !replId.isEmpty, !seen.contains(replId) else {
                return ch
            }
            seen.insert(replId)
            currentId = replId
            depth += 1
        }
        return iptvOrgIndexes.channelByExactId[currentId]
            ?? iptvOrgIndexes.channelByCaseFoldedId[currentId.lowercased()]
    }

    // MARK: - Country-aware confidence

    private func countryConfidence(forKey key: String, countryHint: String?, base: Double) -> Double {
        guard let hint = countryHint,
              let curated = curatedByKey[key] else { return base }
        return hint.uppercased() == curated.country.uppercased() ? base : base - 0.10
    }

    // MARK: - Fuzzy bigram matching

    private struct FuzzyResult { let key: String; let score: Double }

    private func fuzzyMatch(_ input: String) -> FuzzyResult? {
        guard !input.isEmpty else { return nil }
        let inputBigrams = bigrams(input)
        let inputFirstToken = input.split(separator: " ").first.map(String.init) ?? input
        let narrowed = fuzzyCandidates.filter {
            $0.firstToken == inputFirstToken ||
            $0.name.hasPrefix(inputFirstToken) ||
            input.hasPrefix($0.firstToken)
        }
        let candidates: [FuzzyCandidate]
        if narrowed.isEmpty {
            guard fuzzyCandidates.count <= maxFuzzyCandidatesPerStream else { return nil }
            candidates = fuzzyCandidates
        } else {
            candidates = Array(narrowed.prefix(maxFuzzyCandidatesPerStream))
        }
        var best = fuzzyThreshold
        var bestKey: String?
        for candidate in candidates {
            let score = jaccard(inputBigrams, candidate.bigrams)
            if score > best { best = score; bestKey = candidate.key }
        }
        return bestKey.map { FuzzyResult(key: $0, score: best) }
    }

    private func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.unicodeScalars)
        guard chars.count >= 2 else { return [] }
        var result = Set<String>()
        for i in 0..<(chars.count - 1) {
            result.insert(String(chars[i].value) + String(chars[i+1].value))
        }
        return result
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    // MARK: - Build canonical channels from matched streams

    func buildCanonicalChannels(
        from matches: [ChannelMatchResult],
        profile: String = "expanded"
    ) -> [CanonicalChannel] {

        let profileDef = config.profiles[profile] ?? config.profiles["expanded"]!
        let allowedTiers = Set(profileDef.includeTiers)

        var grouped: [String: [ChannelMatchResult]] = [:]
        for match in matches {
            grouped[match.canonicalChannelKey, default: []].append(match)
        }

        var result: [CanonicalChannel] = []
        for channel in config.channels {
            guard allowedTiers.contains(channel.tier) else { continue }
            guard !(channel.optional && !profileDef.includeOptional) else { continue }
            guard let streamMatches = grouped[channel.key], !streamMatches.isEmpty else { continue }

            let sortedStreams = streamMatches
                .map(\.stream)
                .sorted { $0.resolution > $1.resolution }

            let best = sortedStreams.first!
            let bestMatch = streamMatches.max(by: { $0.confidence < $1.confidence })!
            let allConflicts = streamMatches.flatMap(\.conflicts)

            let canonical = CanonicalChannel(
                id: channel.key,
                name: channel.name,
                categoryId: channel.category,
                country: channel.country,
                languages: channel.languages,
                market: channel.market,
                network: channel.network,
                priority: channel.priority,
                isOptional: channel.optional,
                tier: channel.tier,
                logoURL: best.tvgLogoURL,
                primaryStream: best,
                fallbackStreams: Array(sortedStreams.dropFirst()),
                epgChannelId: nil,
                epgSourceId: nil,
                matchMethod: bestMatch.matchMethod,
                iptvOrgChannelId: bestMatch.iptvOrgChannelId,
                resolvedLogo: nil,
                identityConfidence: bestMatch.confidence,
                identityConflicts: Array(Set(allConflicts))
            )
            result.append(canonical)
        }

        return result.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.name < $1.name
        }
    }
}
