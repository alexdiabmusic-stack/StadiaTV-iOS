import Foundation

// MARK: - Match result

nonisolated struct ChannelMatchResult {
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
/// and language to resolve. Contradictory or ambiguous identities remain unresolved;
/// quality and editorial priority never resolve a channel identity collision.
nonisolated final class CanonicalChannelMatcher {

    private let config: CuratedGuideConfig
    private let normalizer: ChannelNormalizer
    private let fuzzyThreshold: Double

    // Curated fast lookup tables — each key maps to one or more candidate channel keys.
    private var aliasToCandidateKeys: [String: [String]] = [:]
    private var normalizedNameToKeys: [String: [String]] = [:]
    // EPG ID index. Same XMLTV ID from different guide sources can be different channels;
    // resolution relies on source-qualified lookup from the caller when possible.
    private var epgIdToKeys: [String: [String]] = [:]
    private var curatedByKey: [String: CuratedChannel] = [:]
    private var fuzzyCandidates: [FuzzyCandidate] = []
    private var fuzzyPostings: [String: Set<Int>] = [:]
    private var protectedRegions: Set<String> = []

    // Optional IPTV-org indexes for extended matching
    private var iptvOrgIndexes: IPTVOrgIndexes = .empty

    private struct FuzzyCandidate {
        let name: String
        let key: String
        let numbers: Set<String>
        let modifiers: Set<String>
        let regions: Set<String>
        let bigrams: Set<String>
    }

    init(config: CuratedGuideConfig, normalizer: ChannelNormalizer, iptvOrgIndexes: IPTVOrgIndexes = .empty) {
        self.config = config
        self.normalizer = normalizer
        self.fuzzyThreshold = min(1, max(0.85, config.deduplication.fuzzyThreshold))
        self.iptvOrgIndexes = iptvOrgIndexes
        buildLookups()
    }

    func updateIPTVOrgIndexes(_ indexes: IPTVOrgIndexes) {
        iptvOrgIndexes = indexes
    }

    private func buildLookups() {
        for channel in config.channels {
            curatedByKey[channel.key] = channel
            let normName = identityName(channel.name)
            addCandidate(channel.key, toIndex: &normalizedNameToKeys, forKey: normName)

            for alias in channel.aliases {
                addCandidate(channel.key, toIndex: &aliasToCandidateKeys, forKey: identityName(alias))
            }

            if let epgId = channel.epgId {
                addCandidate(channel.key, toIndex: &epgIdToKeys, forKey: epgId.lowercased())
            }
        }

        protectedRegions = Set(config.normalization.preserveTokens.map(identityName))
        protectedRegions.formUnion(config.channels.compactMap(\.market).map(identityName))

        // Retain every alias collision. Stable sorting and a bigram posting index make
        // candidate retrieval independent of Dictionary iteration and provider row order.
        var entries: [String: Set<String>] = [:]
        for (name, keys) in normalizedNameToKeys { entries[name, default: []].formUnion(keys) }
        for (name, keys) in aliasToCandidateKeys { entries[name, default: []].formUnion(keys) }
        for name in entries.keys.sorted() {
            for key in (entries[name] ?? []).sorted() {
                let candidate = FuzzyCandidate(name: name, key: key,
                    numbers: numbers(in: name), modifiers: modifiers(in: name),
                    regions: regions(in: name), bigrams: bigrams(name))
                let index = fuzzyCandidates.count
                fuzzyCandidates.append(candidate)
                for bigram in candidate.bigrams { fuzzyPostings[bigram, default: []].insert(index) }
            }
        }
    }

    private func addCandidate(_ key: String, toIndex index: inout [String: [String]], forKey dictKey: String) {
        if !dictKey.isEmpty, !index[dictKey, default: []].contains(key) {
            index[dictKey, default: []].append(key)
        }
    }

    // MARK: - Collision resolution

    /// Resolves a candidate set to a single canonical channel key using stream metadata.
    /// Returns nil for contradictory metadata or more than one plausible identity.
    private func resolveFromCandidates(
        _ keys: [String],
        stream: ChannelStream,
        baseConfidence: Double,
        method: EPGMatchMethod,
        iptvOrgChannelId: String? = nil
    ) -> ChannelMatchResult? {
        guard baseConfidence >= 0.85 else { return nil }
        let hint = countryCode(normalizer.extractCountryHint(from: stream.originalName) ?? stream.countryHint)
        var narrowed = Array(Set(keys)).filter { key in
            guard let channel = curatedByKey[key] else { return false }
            return countryAgrees(hint, channel.country) && identityAgrees(stream.originalName, with: channel)
        }.sorted()
        if let hint {
            let local = narrowed.filter { countryCode(curatedByKey[$0]?.country) == hint }
            if !local.isEmpty { narrowed = local }
        }
        if narrowed.count > 1,
           let language = stream.streamMetadata.languageHint ?? normalizer.extractStreamMetadata(from: stream.originalName).languageHint {
            let normalizedLanguage = languageCode(language)
            let byLanguage = narrowed.filter {
                curatedByKey[$0]?.languages.contains(where: { languageCode($0) == normalizedLanguage }) == true
            }
            if !byLanguage.isEmpty { narrowed = byLanguage }
        }
        // Editorial priority is not identity evidence. Ambiguous names stay unresolved.
        guard narrowed.count == 1 else { return nil }
        return ChannelMatchResult(stream: stream, canonicalChannelKey: narrowed[0],
                                  matchMethod: method, confidence: baseConfidence,
                                  iptvOrgChannelId: iptvOrgChannelId, conflicts: [])
    }

    private func countryCode(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let upper = value.uppercased()
        return ["UK": "GB", "CAF": "CA", "USA": "US" ][upper] ?? upper
    }

    private func countryAgrees(_ hint: String?, _ country: String) -> Bool {
        guard let hint, hint != "INTL" else { return true }
        let candidate = countryCode(country)
        return candidate == hint || candidate == "INTL"
    }

    private func languageCode(_ language: String) -> String {
        let lower = language.lowercased()
        return ["eng": "en", "esp": "es", "fra": "fr", "ger": "de", "ita": "it", "por": "pt",
                "ara": "ar", "tur": "tr", "pol": "pl", "nld": "nl", "zho": "zh", "jpn": "ja",
                "kor": "ko", "hin": "hi", "rus": "ru"][lower] ?? lower
    }

    private func identityName(_ name: String) -> String {
        let clean = normalizer.normalize(name).lowercased()
            .replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: #"([a-z])(\d)"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)([a-z])"#, with: "$1 $2", options: .regularExpression)
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                       "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        return clean.split(separator: " ").map { token in
            let word = String(token)
            return numbers[word] ?? Int(word).map(String.init) ?? (word == "alt" ? "alternate" : word)
        }.joined(separator: " ")
    }

    private func numbers(in name: String) -> Set<String> {
        Set(name.split(separator: " ").filter { $0.allSatisfy(\.isNumber) }.map(String.init))
    }

    private func compatibleNames(_ lhs: String, _ rhs: String) -> Bool {
        guard numbers(in: lhs) == numbers(in: rhs) else { return false }
        guard modifiers(in: lhs) == modifiers(in: rhs) else { return false }
        // Market and regional-feed qualifiers cannot be guessed away by edit distance.
        return regions(in: lhs) == regions(in: rhs)
    }

    private func modifiers(in name: String) -> Set<String> {
        Set(name.split(separator: " ").map(String.init)).intersection(["plus", "premium", "main", "alternate"])
    }

    private func regions(in name: String) -> Set<String> {
        let padded = " " + name + " "
        return protectedRegions.filter { padded.contains(" " + $0 + " ") }
    }

    private func identityAgrees(_ name: String, with channel: CuratedChannel) -> Bool {
        let input = identityName(name)
        guard !input.isEmpty else { return false }
        return ([channel.name] + channel.aliases).contains { compatibleNames(input, identityName($0)) }
    }

    private func nameSupports(_ name: String, key: String) -> Bool {
        guard let channel = curatedByKey[key] else { return false }
        let input = identityName(name)
        return ([channel.name] + channel.aliases).contains { alias in
            let candidate = identityName(alias)
            return compatibleNames(input, candidate) && (input == candidate || similarity(input, candidate) >= fuzzyThreshold)
        }
    }

    // MARK: - Primary match entry point

    func match(_ stream: ChannelStream) -> ChannelMatchResult? {
        let namedCountry = countryCode(normalizer.extractCountryHint(from: stream.originalName))
        let suppliedCountry = countryCode(stream.countryHint)
        if let namedCountry, let suppliedCountry,
           namedCountry != "INTL", suppliedCountry != "INTL", namedCountry != suppliedCountry { return nil }
        let countryHint = namedCountry ?? suppliedCountry
        // Never reuse stale/destructive cached normalization for identity.
        let effectiveNorm = identityName(stream.originalName)
        guard !effectiveNorm.isEmpty else { return nil }

        // Explicit provider names beat incorrect tvg-ids (the sample contains both
        // Eurosport -> BBCOne and Sky Sports Premier League -> SkySportsGolf IDs).
        let exactKeys = Array(Set((aliasToCandidateKeys[effectiveNorm] ?? []) +
                                 (normalizedNameToKeys[effectiveNorm] ?? [])))
        if let result = resolveFromCandidates(exactKeys, stream: stream,
                                              baseConfidence: 0.98, method: .normalizedExact) { return result }
        if let tvgId = stream.tvgId, !tvgId.isEmpty {
            let supportedKeys = (epgIdToKeys[tvgId.lowercased()] ?? []).filter {
                (exactKeys.isEmpty || exactKeys.contains($0)) && nameSupports(stream.originalName, key: $0)
            }
            if let result = resolveFromCandidates(supportedKeys, stream: stream,
                                                 baseConfidence: 0.95, method: .providerEpgExact) { return result }
            if let result = matchViaIPTVOrg(epgId: tvgId, stream: stream,
                                           effectiveNorm: effectiveNorm, countryHint: countryHint),
               exactKeys.isEmpty || exactKeys.contains(result.canonicalChannelKey) { return result }
        }
        if iptvOrgIndexes.isLoaded,
           let result = matchViaIPTVOrgName(effectiveNorm: effectiveNorm, stream: stream,
                                           countryHint: countryHint),
           exactKeys.isEmpty || exactKeys.contains(result.canonicalChannelKey) { return result }
        // A known but unresolved exact identity cannot be rescued by a weaker typo match.
        guard exactKeys.isEmpty else { return nil }

        // Group titles describe a collection, not a channel's market. They cannot
        // independently map an unknown CBC feed to Toronto (or any other city).
        return fuzzyMatch(effectiveNorm, stream: stream)
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

        if iptvChannel.closed != nil, let replaced = followReplacementChain(from: iptvChannel.replacedBy ?? "") {
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
        let normIPTVName = identityName(iptvChannel.name)
        var candidateKeys: [String] = []

        for k in normalizedNameToKeys[normIPTVName] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }
        for k in aliasToCandidateKeys[normIPTVName] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }
        for k in aliasToCandidateKeys[iptvChannel.name.lowercased()] ?? [] where !candidateKeys.contains(k) { candidateKeys.append(k) }

        if candidateKeys.isEmpty {
            for alt in iptvChannel.altNames {
                let normAlt = identityName(alt)
                for k in (aliasToCandidateKeys[normAlt] ?? []) + (normalizedNameToKeys[normAlt] ?? []) {
                    if !candidateKeys.contains(k) { candidateKeys.append(k) }
                }
            }
        }

        let hint = countryCode(countryHint)
        guard countryAgrees(hint, iptvChannel.country) else { return nil }
        candidateKeys = candidateKeys.filter { key in
            guard let curated = curatedByKey[key] else { return false }
            return countryAgrees(countryCode(iptvChannel.country), curated.country) &&
                   nameSupports(stream.originalName, key: key)
        }
        return resolveFromCandidates(candidateKeys, stream: stream, baseConfidence: baseConfidence,
                                     method: method, iptvOrgChannelId: iptvChannel.id)
    }

    private func matchViaIPTVOrgName(
        effectiveNorm: String, stream: ChannelStream, countryHint: String?
    ) -> ChannelMatchResult? {
        let candidates = iptvOrgIndexes.channelsByNormalizedName[normalizer.normalize(stream.originalName).lowercased()] ?? []
        let results = candidates.sorted { $0.id < $1.id }.compactMap { candidate in
            matchIPTVChannelToCurated(iptvChannel: candidate, stream: stream,
                effectiveNorm: effectiveNorm, countryHint: countryHint,
                method: .iptvOrgAltName, baseConfidence: 0.90)
        }
        // A metadata bridge cannot silently choose the first same-name country/feed.
        guard Set(results.map(\.canonicalChannelKey)).count == 1 else { return nil }
        return results.first
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

    // MARK: - Deterministic fuzzy matching

    private func fuzzyMatch(_ input: String, stream: ChannelStream) -> ChannelMatchResult? {
        let inputBigrams = bigrams(input)
        let inputNumbers = numbers(in: input)
        let inputModifiers = modifiers(in: input)
        let inputRegions = regions(in: input)
        let minimumCompetitorScore = fuzzyThreshold - 0.05
        var indexes: Set<Int> = []
        for bigram in inputBigrams { indexes.formUnion(fuzzyPostings[bigram] ?? []) }
        let hint = countryCode(normalizer.extractCountryHint(from: stream.originalName) ?? stream.countryHint)
        var scoresByKey: [String: Double] = [:]
        for index in indexes.sorted() {
            let candidate = fuzzyCandidates[index]
            guard let channel = curatedByKey[candidate.key], countryAgrees(hint, channel.country),
                  inputNumbers == candidate.numbers, inputModifiers == candidate.modifiers,
                  inputRegions == candidate.regions else { continue }
            // Character overlap supplies a cheap safe upper bound before edit distance.
            let dice = 2 * Double(inputBigrams.intersection(candidate.bigrams).count) /
                       Double(max(1, inputBigrams.count + candidate.bigrams.count))
            guard 0.65 + 0.35 * dice >= minimumCompetitorScore else { continue }
            let score = similarity(input, candidate.name, dice: dice)
            if score >= minimumCompetitorScore { scoresByKey[candidate.key] = max(scoresByKey[candidate.key] ?? 0, score) }
        }
        if let hint, hint != "INTL" {
            let local = scoresByKey.filter { countryCode(curatedByKey[$0.key]?.country) == hint }
            if !local.isEmpty { scoresByKey = local }
        }
        let ranked = scoresByKey.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        guard let best = ranked.first, best.value >= fuzzyThreshold else { return nil }
        // Distinct canonical identities need a winning margin; aliases of the same
        // canonical channel do not compete against one another.
        if ranked.count > 1, best.value - ranked[1].value < 0.05 { return nil }
        return resolveFromCandidates([best.key], stream: stream, baseConfidence: best.value, method: .fuzzy)
    }

    private func similarity(_ lhs: String, _ rhs: String, dice suppliedDice: Double? = nil) -> Double {
        if lhs == rhs { return 1 }
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, other) in b.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (character == other ? 0 : 1))
            }
            previous = current
        }
        let edit = 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
        let left = bigrams(lhs), right = bigrams(rhs)
        let dice = suppliedDice ?? (2 * Double(left.intersection(right).count) / Double(max(1, left.count + right.count)))
        return 0.65 * edit + 0.35 * dice
    }

    private func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.unicodeScalars)
        guard chars.count >= 2 else { return [] }
        var result = Set<String>()
        for i in 0..<(chars.count - 1) {
            result.insert(String(chars[i]) + String(chars[i+1]))
        }
        return result
    }

    // MARK: - Build canonical channels from matched streams

    func buildCanonicalChannels(
        from matches: [ChannelMatchResult],
        profile: String = "expanded"
    ) -> [CanonicalChannel] {

        guard let profileDef = config.profiles[profile] ?? config.profiles["expanded"] else { return [] }
        let allowedTiers = Set(profileDef.includeTiers)

        var grouped: [String: [ChannelMatchResult]] = [:]
        for match in matches where match.isHighConfidence && match.conflicts.isEmpty {
            grouped[match.canonicalChannelKey, default: []].append(match)
        }

        var result: [CanonicalChannel] = []
        for channel in config.channels {
            guard allowedTiers.contains(channel.tier) else { continue }
            guard !(channel.optional && !profileDef.includeOptional) else { continue }
            guard let streamMatches = grouped[channel.key], !streamMatches.isEmpty else { continue }

            var seenStreams: Set<String> = []
            let sortedMatches = streamMatches.sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                if $0.stream.resolution != $1.stream.resolution { return $0.stream.resolution > $1.stream.resolution }
                return $0.stream.id < $1.stream.id
            }.filter { seenStreams.insert($0.stream.id).inserted }
            let sortedStreams = sortedMatches.map(\.stream)
            guard let bestMatch = sortedMatches.first else { continue }
            let best = bestMatch.stream

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
                identityConflicts: []
            )
            result.append(canonical)
        }

        return result.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.name < $1.name
        }
    }
}
