import Foundation

/// Reads provider HLS playlists for the engine's HLS ingest.
///
/// Only what live IPTV needs: single-rendition live playlists of MPEG-TS segments. Anything
/// else (adaptive ladders, on-demand, encryption, fMP4, byte ranges) is reported so the
/// player can hand the URL to AVPlayer directly instead.
nonisolated enum HLSPlaylistParser {
    struct Variant: Equatable, Sendable {
        let url: URL
        let bandwidth: Int?
    }

    struct Segment: Equatable, Sendable {
        let url: URL
        let duration: Double
        let sequence: Int
        /// Preceded by EXT-X-DISCONTINUITY.
        let discontinuity: Bool
    }

    struct MediaPlaylist: Equatable, Sendable {
        var targetDuration: Double
        var mediaSequence: Int
        var segments: [Segment]
        var isEnded: Bool
        /// Why the engine can't ingest this playlist, if it can't.
        var unsupportedReason: String?
    }

    enum Result: Equatable, Sendable {
        case master([Variant])
        case media(MediaPlaylist)
        case invalid
    }

    static func parse(_ text: String, baseURL: URL) -> Result {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first.map({ $0.hasPrefix("#EXTM3U") || $0.hasPrefix("\u{FEFF}#EXTM3U") }) == true else { return .invalid }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var variants: [Variant] = []
            var pendingBandwidth: Int?
            var expectingURI = false
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init)
                    expectingURI = true
                } else if expectingURI, !line.isEmpty, !line.hasPrefix("#") {
                    if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                        variants.append(Variant(url: url, bandwidth: pendingBandwidth))
                    }
                    expectingURI = false
                }
            }
            return variants.isEmpty ? .invalid : .master(variants)
        }

        var playlist = MediaPlaylist(targetDuration: 6, mediaSequence: 0, segments: [], isEnded: false, unsupportedReason: nil)
        var sequence = 0
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                playlist.targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 6
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                playlist.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                sequence = playlist.mediaSequence
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces))
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                playlist.isEnded = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
                playlist.isEnded = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                if attribute("METHOD", in: line)?.uppercased() != "NONE" { playlist.unsupportedReason = "encrypted" }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                playlist.unsupportedReason = "fragmented MP4"
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                playlist.unsupportedReason = "byte-range segments"
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    playlist.segments.append(Segment(url: url, duration: pendingDuration ?? playlist.targetDuration,
                                                     sequence: sequence, discontinuity: pendingDiscontinuity))
                }
                sequence += 1
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        if playlist.isEnded, playlist.unsupportedReason == nil { playlist.unsupportedReason = "on-demand" }
        if playlist.unsupportedReason == nil, let first = playlist.segments.first {
            let ext = first.url.pathExtension.lowercased()
            if ["mp4", "m4s", "m4a", "m4v", "aac", "mp3", "ac3", "ec3", "vtt", "webvtt"].contains(ext) {
                playlist.unsupportedReason = "\(ext) segments"
            }
        }
        return .media(playlist)
    }

    /// Value of `NAME=value` or `NAME="value"` in an attribute list.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var rest = line[line.index(after: colon)...]
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...]
            var value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let close = rest.firstIndex(of: "\"") ?? rest.endIndex
                value = rest[..<close]
                rest = close < rest.endIndex ? rest[rest.index(after: close)...] : ""
                if rest.first == "," { rest = rest.dropFirst() }
            } else {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<comma]
                rest = comma < rest.endIndex ? rest[rest.index(after: comma)...] : ""
            }
            if key.caseInsensitiveCompare(name) == .orderedSame { return String(value) }
        }
        return nil
    }
}
