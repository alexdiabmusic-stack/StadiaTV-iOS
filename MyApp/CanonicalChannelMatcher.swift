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
///
/// Alias dictionaries store candidate sets ([String: [String]]) rather than single values.
/// When multiple canonical channels share a normalized alias, the matcher uses country hint,
/// language and priority to resolve; genuinely ambiguous cases are flagged as conflicts rather
/// than silently picking the last-inserted entry.
nonisolated final class CanonicalChannelMatcher {

    private let config: CuratedGuideConfig
    private let normalizer: ChannelNormalizer
    private let fuzzyThreshold: Double

    // Curated fast lookup tables — each key maps to one or more candidate channel keys.
    private var aliasToCandidateKeys: [String: [String]] = [:]
    private var normalizedNameToKeys: [String: [String]] = [:]
    // Network+market index: "network|market" -> [channelKey]. Exact market required at resolution.
    private var networkMarketToKeys: [String: [String]] = [:]
    // EPG ID index. Same XMLTV ID from different guide sources can be different channels;
    // resolution relies on source-qualified lookup from the caller when possible.
    private var epgIdToKeys: [String: [String]] = [:]
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
            addCandidate(channel.key, toIndex: &normalizedNameToKeys, forKey: normName)
            for variant in alphaNumericVariants(of: normName) {
                addCandidate(channel.key, toIndex: &normalizedNameToKeys, forKey: variant)
            }

            for alias in channel.aliases {
                let aliasLow = alias.lowercased()
                addCandidate(channel.key, toIndex: &aliasToCandidateKeys, forKey: aliasLow)
                let normAlias = normalizer.normalize(alias).lowercased()
                addCandidate(channel.key, toIndex: &aliasToCandidateKeys, forKey: normAlias)
                for variant in alphaNumericVariants(of: aliasLow) {
                    addCandidate(channel.key, toIndex: &aliasToCandidateKeys, forKey: variant)
                }
            }

            if let network = channel.network, let market = channel.market {
                addCandidate(channel.key, toIndex: &networkMarketToKeys,
                             forKey: "\(network.lowercased())|\(market.lowercased())")
            }

            if let epgId = channel.epgId {
                addCandidate(channel.key, toIndex: &epgIdToKeys, forKey: epgId.lowercased())
            }
        }

        // Build fuzzy candidate list from union of name and alias indexes.
        var seen = Set<String>()
        var candidates: [FuzzyCandidate] = []
        for (name, keys) in normalizedNameToKeys {
            if let key = keys.first, seen.insert(name).inserted {
                candidates.append(FuzzyCandidate(
                    name: name, key: key,
                    firstToken: name.split(separator: " ").first.map(String.init) ?? name,
                    bigrams: bigrams(name)
                ))
            }
        }
        for (name, keys) in aliasToCandidateKeys where !normalizedNameToKeys.keys.contains(name) {
            if let key = keys.first, seen.insert(name).inserted {
                candidates.append(FuzzyCandidate(
                    name: name, key: key,
                    firstToken: name.split(separator: " ").first.map(String.init) ?? name,
                    bigrams: bigrams(name)
                ))
            }
        }
        fuzzyCandidates = candidates
    }

    private func addCandidate(_ key: String, toIndex index: inout [String: [String]], forKey dictKey: String) {
        if !dictKey.isEmpty, !index[dictKey, default: []].contains(key) {
            index[dictKey, default: []].append(key)
        }
    }

    // MARK: - Collision resolution

    /// Resolves a candidate set to a single canonical channel key using stream metadata.
    /// Returns the best key plus any ambiguity conflicts. Returns nil if the set is empty.
    private func resolveFromCandidates(
        _ keys: [String],
        stream: ChannelStream,
        baseConfidence: Double,
        method: EPGMatchMethod,
        iptvOrgChannelId: String? = nil
    ) -> ChannelMatchResult? {
        guard !keys.isEmpty else { return nil }
        guard keys.count > 1 else {
            return ChannelMatchResult(stream: stream, canonicalChannelKey: keys[0],
                                      matchMethod: method, confidence: baseConfidence,
                                      iptvOrgChannelId: iptvOrgChannelId, conflicts: [])
        }

        // Step 1: filter by country hint
        var narrowed = keys
        let countryHint = stream.countryHint?.uppercased()
        if let hint = countryHint {
            let byCountry = keys.filter { curatedByKey[$0]?.country.uppercased() == hint }
            if !byCountry.isEmpty { narrowed = byCountry }
        }

        // Step 2: filter by language hint
        if narrowed.count > 1, let lang = stream.streamMetadata.languageHint?.uppercased() {
            let byLang = narrowed.filter {
                curatedByKey[$0]?.languages.contains(where: { $0.uppercased() == lang }) == true
            }
            if !byLang.isEmpty { narrowed = byLang }
        }

        // Step 3: pick highest-priority candidate from remaining set
        let sorted = narrowed.sorted {
            (curatedByKey[$0]?.priority ?? 0) > (curatedByKey[$1]?.priority ?? 0)
        }
        let best = sorted[0]

        var confidence = baseConfidence
        var conflicts: [IdentityConflict] = []
        if sorted.count > 1 {
            // Still ambiguous after metadata filtering — penalise confidence and note conflict
            confidence = max(0.3, baseConfidence - 0.15)
            let otherNames = sorted.dropFirst()
                .compactMap { curatedByKey[$0]?.name }
                .joined(separator: ", ")
            conflicts.append(IdentityConflict(
                field: "alias_collision",
                expected: curatedByKey[best]?.name ?? best,
                actual: otherNames
            ))
        }

        return ChannelMatchResult(stream: stream, canonicalChannelKey: best,
                                  matchMethod: method, confidence: confidence,
                                  iptvOrgChannelId: iptvOrgChannelId, conflicts: conflicts)
    }

    // MARK: - Generates space-toggled variants for alpha+digit boundaries.
    // "rds2" → ["rds 2"] and "rds 2" → ["rds2"]
    private func alphaNumericVariants(of s: String) -> [String] {
        let withSpace = s.replacingOccurrences(of: #"([a-z])(\d)"#, with: "$1 $2",
            options: .regularExpression)
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

        // 2. Provider EPG ID / tvg-id → curated epg_id lookup (exact)
        if let tvgId = stream.tvgId, !tvgId.isEmpty {
            if let keys = epgIdToKeys[tvgId.lowercased()], !keys.isEmpty {
                return resolveFromCandidates(keys, stream: stream,
                                             baseConfidence: 0.95, method: .providerEpgExact)
            }
            // 2b. Provider EPG ID → IPTV-org → curated
            if let result = matchViaIPTVOrg(epgId: tvgId, stream: stream,
                                             effectiveNorm: effectiveNorm, countryHint: countryHint) {
                return result
            }
        }

        // 3. Exact alias (original name)
        let origLower = stream.originalName.lowercased().trimmingCharacters(in: .whitespaces)
        if let keys = aliasToCandidateKeys[origLower], !keys.isEmpty {
            return resolveFromCandidates(keys, stream: stream,
                                         baseConfidence: 1.0, method: .exactAlias)
        }

        // 4. Normalized alias
        if let keys = aliasToCandidateKeys[effectiveNorm], !keys.isEmpty {
            return resolveFromCandidates(keys, stream: stream,
                                         baseConfidence: 0.95, method: .exactAlias)
        }

        // 5. Normalized name exact
        let nameKeys = (normalizedNameToKeys[effectiveNorm] ?? []) +
                       (effectiveNorm != normStream ? (normalizedNameToKeys[normStream] ?? []) : [])
        let uniqueNameKeys = Array(OrderedSet(nameKeys))
        if !uniqueNameKeys.isEmpty {
            let base = countryConfidence(forKeys: uniqueNameKeys, countryHint: countryHint, base: 0.90)
            return resolveFromCandidates(uniqueNameKeys, stream: stream,
                                         baseConfidence: base, method: .normalizedExact)
        }

        // 6. IPTV-org normalized name → curated lookup (country-filtered)
        if iptvOrgIndexes.isLoaded,
           let result = matchViaIPTVOrgName(effectiveNorm: effectiveNorm, stream: stream,
                                            countryHint: countryHint) {
            return result
        }

        // 7. Network + market — requires country agreement between stream and curated channel.
        // The stream's group title is used as a network hint, but only matched when the stream's
        // country hint agrees with the curated channel's country to prevent cross-market merges.
        if let network = stream.groupTitle, !network.isEmpty {
            let netLower = network.lowercased()
            var bestKeys: [String] = []
            let streamCountry = (stream.countryHint ?? countryHint)?.uppercased()
            for (nmKey, keys) in networkMarketToKeys {
                guard nmKey.hasPrefix(netLower + "|") else { continue }
                if let hint = streamCountry, !hint.isEmpty {
                    // The key suffix is a market/city name, not a country code (e.g. "cbc|toronto").
                    // Compare against the curated channel's actual country property instead.
                    let matching = keys.filter { curatedByKey[$0]?.country.uppercased() == hint }
                    guard !matching.isEmpty else { continue }
                    for k in matching where !bestKeys.contains(k) { bestKeys.append(k) }
                } else {
                    for k in keys where !bestKeys.contains(k) { bestKeys.append(k) }
                }
            }
            if !bestKeys.isEmpty {
                return resolveFromCandidates(bestKeys, stream: stream,
                                             baseConfidence: 0.80, method: .networkMarket)
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
            if let replaced = followReplacementChain(from: epgId) {
                return matchIPTVChannelToCurated(
                    iptvChannel: replaced, stream: stream,
                    effectiveNorm: effectiveNorm, countryHint: countryHint,
                    method: .replacementChain, baseConfidence: 0.70
                )
            }
            return nil
        }

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
        let normIPTVName = normalizer.normalize(iptvChannel.name).lowercased()
        var candidateKeys: [String] = []

        for k in normalizedNameToKeys[normIPTVName] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }
        for k in aliasToCandidateKeys[normIPTVName] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }
        for k in aliasToCandidateKeys[iptvChannel.name.lowercased()] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }

        if candidateKeys.isEmpty {
            for alt in iptvChannel.altNames {
                let normAlt = normalizer.normalize(alt).lowercased()
                for k in (aliasToCandidateKeys[normAlt] ?? []) + (normalizedNameToKeys[normAlt] ?? []) {
                    if !candidateKeys.contains(k) { candidateKeys.append(k) }
                }
            }
        }

        guard !candidateKeys.isEmpty else { return nil }

        // Country agreement check
        var confidence = baseConfidence
        var conflicts: [IdentityConflict] = []
        let iptvCountry = iptvChannel.country.uppercased()
        for key in candidateKeys {
            if let curated = curatedByKey[key] {
                let curatedCountry = curated.country.uppercased()
                if iptvCountry != curatedCountry {
                    confidence -= 0.15
                    conflicts.append(IdentityConflict(field: "country",
                                                      expected: curatedCountry, actual: iptvCountry))
                    break
                }
            }
        }

        // Name agreement between provider stream and IPTV-org name
        if !effectiveNorm.isEmpty && !normIPTVName.isEmpty && normIPTVName != effectiveNorm {
            let similarity = jaccard(bigrams(normIPTVName), bigrams(effectiveNorm))
            if similarity < 0.4 {
                confidence -= 0.10
                conflicts.append(IdentityConflict(field: "name",
                                                  expected: iptvChannel.name, actual: stream.originalName))
            }
        }

        if let hint = countryHint, let curated = curatedByKey[candidateKeys[0]] {
            if hint.uppercased() != curated.country.uppercased() {
                confidence -= 0.10
            }
        }

        guard confidence > 0.3 else { return nil }

        guard let result = resolveFromCandidates(candidateKeys, stream: stream,
                                                  baseConfidence: confidence, method: method,
                                                  iptvOrgChannelId: iptvChannel.id) else { return nil }
        if conflicts.isEmpty { return result }
        return ChannelMatchResult(stream: result.stream, canonicalChannelKey: result.canonicalChannelKey,
                                  matchMethod: result.matchMethod, confidence: result.confidence,
                                  iptvOrgChannelId: result.iptvOrgChannelId,
                                  conflicts: result.conflicts + conflicts)
    }

    private func matchViaIPTVOrgName(
        effectiveNorm: String, stream: ChannelStream, countryHint: String?
    ) -> ChannelMatchResult? {
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

    private func countryConfidence(forKeys keys: [String], countryHint: String?, base: Double) -> Double {
        guard let hint = countryHint else { return base }
        let anyMatch = keys.contains { curatedByKey[$0]?.country.uppercased() == hint.uppercased() }
        return anyMatch ? base : base - 0.10
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

// MARK: - OrderedSet helper (insertion-order deduplication)

private struct OrderedSet<T: Hashable>: Sequence {
    private var set = Set<T>()
    private var array: [T] = []

    init(_ elements: [T]) {
        for e in elements { insert(e) }
    }

    mutating func insert(_ value: T) {
        if set.insert(value).inserted { array.append(value) }
    }

    func makeIterator() -> IndexingIterator<[T]> { array.makeIterator() }
}
