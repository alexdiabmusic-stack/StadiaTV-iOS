import Foundation

/// Resolves catch-up/archive playback URLs from EPG programme + channel data.
///
/// Supports two provider strategies:
/// - Xtream Codes: timeshift URL constructed from the live stream URL path components
/// - M3U template: token substitution on the catchup-source attribute URL
///
/// Catch-up URL construction is isolated here; no guide view builds archive URLs directly.
struct CatchupResolver {

    private let store = LiveChannelStore.shared

    // MARK: - Eligibility

    /// True when a past programme is within the channel's declared retention window.
    /// Does not make a network call — uses only locally cached data.
    func isEligible(programme: EPGProgramme, channel: CanonicalChannel, now: Date = Date()) -> Bool {
        guard programme.isPast(at: now) else { return false }
        guard channel.hasCatchup else { return false }
        let days = channel.catchupDays
        guard days > 0 else { return true }  // days=0 means unknown retention; assume eligible
        return now.timeIntervalSince(programme.start) <= TimeInterval(days * 24 * 3600)
    }

    /// Returns the date after which the archive for this channel will expire (nil if unknown).
    func retentionExpiry(channel: CanonicalChannel, relativeTo now: Date = Date()) -> Date? {
        let days = channel.catchupDays
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(days * 24 * 3600))
    }

    // MARK: - URL resolution

    /// Resolves the catch-up stream URL for a past programme.
    ///
    /// - Parameters:
    ///   - programme: The past EPGProgramme with display-shifted times.
    ///   - channel: The canonical channel with archive metadata.
    ///   - epgOffsetMinutes: The EPG display offset applied to the programme — unshifted before URL construction.
    /// - Returns: A URL suitable for passing to PlayerView as the stream URL.
    /// - Throws: `CatchupError.unavailable` when no strategy could produce a URL.
    func resolveURL(
        programme: EPGProgramme,
        channel: CanonicalChannel,
        epgOffsetMinutes: Int = 0
    ) async throws -> URL {
        guard let stream = channel.primaryStream ?? channel.fallbackStreams.first else {
            throw CatchupError.unavailable
        }

        // Xtream strategy: live stream URL follows /live/{user}/{pass}/{id}.ext pattern
        if let url = try? resolveXtreamURL(
            programme: programme,
            streamURL: stream.streamURL,
            epgOffsetMinutes: epgOffsetMinutes
        ) {
            return url
        }

        // M3U template strategy: look up catchup.templateURL from the SQLite cache
        if let liveChannel = try? await store.channel(id: stream.providerChannelId),
           let template = liveChannel.catchup?.templateURL {
            return try resolveTemplate(template, programme: programme, epgOffsetMinutes: epgOffsetMinutes)
        }

        throw CatchupError.unavailable
    }

    // MARK: - Xtream timeshift

    private func resolveXtreamURL(
        programme: EPGProgramme,
        streamURL: URL,
        epgOffsetMinutes: Int
    ) throws -> URL {
        // Expected path: /live/{user}/{pass}/{stream_id}.{ext}
        let parts = streamURL.pathComponents   // ["/", "live", user, pass, "12345.m3u8"]
        guard parts.count >= 5, parts[safe: 1] == "live" else { throw CatchupError.unavailable }

        let user     = parts[2]
        let pass     = parts[3]
        let fileComp = parts[4]
        let streamID = fileComp.components(separatedBy: ".").first ?? fileComp

        guard !user.isEmpty, !pass.isEmpty, !streamID.isEmpty else { throw CatchupError.unavailable }

        // Reconstruct base host (scheme + host + optional port, no path)
        var comps = URLComponents()
        comps.scheme = streamURL.scheme ?? "http"
        comps.host   = streamURL.host
        comps.port   = streamURL.port
        guard let hostBase = comps.url?.absoluteString
                              .trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw CatchupError.unavailable
        }

        let realStart = programme.start.addingTimeInterval(-TimeInterval(epgOffsetMinutes * 60))
        let realEnd   = programme.end.addingTimeInterval(-TimeInterval(epgOffsetMinutes * 60))
        let duration  = max(1, Int(ceil(realEnd.timeIntervalSince(realStart) / 60)))
        let startStr  = xtreamStartString(from: realStart)

        let urlStr = "\(hostBase)/timeshift/\(user)/\(pass)/\(duration)/\(startStr)/\(streamID).m3u8"
        guard let url = URL(string: urlStr) else { throw CatchupError.unavailable }
        return url
    }

    /// Formats a Date as the Xtream timeshift start string: `YYYY-MM-DD:HH-MM` in UTC.
    private func xtreamStartString(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d:%02d-%02d",
                      c.year ?? 2024, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - M3U template substitution

    private func resolveTemplate(
        _ template: String,
        programme: EPGProgramme,
        epgOffsetMinutes: Int
    ) throws -> URL {
        let realStart  = programme.start.addingTimeInterval(-TimeInterval(epgOffsetMinutes * 60))
        let realEnd    = programme.end.addingTimeInterval(-TimeInterval(epgOffsetMinutes * 60))
        let startEpoch = Int(realStart.timeIntervalSince1970)
        let endEpoch   = Int(realEnd.timeIntervalSince1970)
        let duration   = max(1, endEpoch - startEpoch)
        let durationM  = max(1, duration / 60)

        var result = template
        result = result.replacingOccurrences(of: "{start}",           with: String(startEpoch))
        result = result.replacingOccurrences(of: "{end}",             with: String(endEpoch))
        result = result.replacingOccurrences(of: "{utc}",             with: String(startEpoch))
        result = result.replacingOccurrences(of: "{lutc}",            with: String(startEpoch))
        result = result.replacingOccurrences(of: "{timestamp}",       with: String(startEpoch))
        result = result.replacingOccurrences(of: "{duration}",        with: String(duration))
        result = result.replacingOccurrences(of: "{durationMinutes}", with: String(durationM))
        result = result.replacingOccurrences(of: "{offset}",          with: String(-durationM))

        guard let url = URL(string: result) else { throw CatchupError.unavailable }
        return url
    }

    // MARK: - Direct Xtream archive (for recording playback, no EPGProgramme required)

    /// Builds a timeshift URL from a raw time range — used by RecordingService for DVR playback.
    /// Credentials are already embedded in the live stream URL path and are never stored separately.
    func resolveXtreamArchive(streamURL: URL, start: Date, end: Date) throws -> URL {
        let parts = streamURL.pathComponents
        guard parts.count >= 5, parts[safe: 1] == "live" else { throw CatchupError.unavailable }

        let user     = parts[2]
        let pass     = parts[3]
        let fileComp = parts[4]
        let streamID = fileComp.components(separatedBy: ".").first ?? fileComp

        guard !user.isEmpty, !pass.isEmpty, !streamID.isEmpty else { throw CatchupError.unavailable }

        var comps = URLComponents()
        comps.scheme = streamURL.scheme ?? "http"
        comps.host   = streamURL.host
        comps.port   = streamURL.port
        guard let hostBase = comps.url?.absoluteString
                              .trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw CatchupError.unavailable
        }

        let duration = max(1, Int(ceil(end.timeIntervalSince(start) / 60)))
        let startStr = xtreamStartString(from: start)

        let urlStr = "\(hostBase)/timeshift/\(user)/\(pass)/\(duration)/\(startStr)/\(streamID).m3u8"
        guard let url = URL(string: urlStr) else { throw CatchupError.unavailable }
        return url
    }

    // MARK: - Error

    enum CatchupError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { "Catch-up is not available for this programme." }
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
