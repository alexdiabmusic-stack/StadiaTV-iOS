import Foundation

/// Resolves the best logo for a CanonicalChannel from all available sources.
/// Do not call inside SwiftUI body — call once during canonical lineup build.
struct ChannelLogoResolver {

    private let iptvOrg: IPTVOrgMetadataService

    init(iptvOrg: IPTVOrgMetadataService) {
        self.iptvOrg = iptvOrg
    }

    // MARK: - Bulk resolution

    func resolveAll(
        channels: [CanonicalChannel],
        epgIcons: [String: URL] = [:]
    ) async -> [String: ResolvedChannelLogo] {
        var result: [String: ResolvedChannelLogo] = [:]
        for channel in channels {
            let epgIcon = epgIcons[channel.epgChannelId ?? ""]
            result[channel.id] = await resolve(for: channel, epgIconURL: epgIcon)
        }
        return result
    }

    // MARK: - Single channel resolution

    func resolve(
        for channel: CanonicalChannel,
        epgIconURL: URL? = nil
    ) async -> ResolvedChannelLogo {

        // 1. IPTV-org exact ID via confirmed iptvOrgChannelId
        if let iptvId = channel.iptvOrgChannelId,
           let logo = await iptvOrg.bestLogo(forChannelId: iptvId),
           let url = logo.resolvedURL {
            return make(channel.id, url: url, source: .iptvOrgExact,
                        method: .iptvOrgExactId, confidence: 0.95,
                        feed: logo.feed, tags: logo.tags)
        }

        // 2. Provider icon when identity confidence is high (≥ 0.85)
        if channel.identityConfidence >= 0.85,
           let iconURL = channel.primaryStream?.tvgLogoURL {
            return make(channel.id, url: iconURL, source: .provider,
                        method: .providerIconHighConfidence,
                        confidence: channel.identityConfidence * 0.9)
        }

        // 3. IPTV-org lookup via curated channel name + country
        if let logo = await iptvOrgLogoViaBridge(channel: channel),
           let url = logo.resolvedURL {
            return make(channel.id, url: url, source: .iptvOrgBridge,
                        method: .iptvOrgMetadataBridge, confidence: 0.75,
                        feed: logo.feed, tags: logo.tags)
        }

        // 4. XMLTV / EPG icon
        if let epgURL = epgIconURL {
            return make(channel.id, url: epgURL, source: .xmltv,
                        method: .xmltvIcon, confidence: 0.60)
        }

        // 5. Provider icon (lower confidence — identity not confirmed)
        if let iconURL = channel.primaryStream?.tvgLogoURL {
            return make(channel.id, url: iconURL, source: .provider,
                        method: .providerIconLowConfidence, confidence: 0.40)
        }

        // 6. Text fallback
        return ResolvedChannelLogo(
            canonicalChannelId: channel.id, url: nil,
            source: .textFallback, matchMethod: .textFallback,
            confidence: 0, feed: nil, tags: []
        )
    }

    // MARK: - IPTV-org metadata bridge

    private func iptvOrgLogoViaBridge(channel: CanonicalChannel) async -> IPTVOrgLogo? {
        // Try curated channel name (normalized) against IPTV-org, country-filtered
        let normName = channel.name.lowercased()
        let country = channel.country

        let byName = await iptvOrg.channels(forNormalizedName: normName, country: country)
        if let first = byName.first, let logo = await iptvOrg.bestLogo(forChannelId: first.id) {
            return logo
        }

        // Try network if present
        if let network = channel.network {
            let byNet = await iptvOrg.channels(forNormalizedName: network.lowercased(), country: country)
            if let first = byNet.first, let logo = await iptvOrg.bestLogo(forChannelId: first.id) {
                return logo
            }
        }
        return nil
    }

    private func make(
        _ id: String, url: URL, source: LogoSource, method: LogoMatchMethod,
        confidence: Double, feed: String? = nil, tags: [String] = []
    ) -> ResolvedChannelLogo {
        ResolvedChannelLogo(
            canonicalChannelId: id, url: url,
            source: source, matchMethod: method,
            confidence: confidence, feed: feed, tags: tags
        )
    }
}
