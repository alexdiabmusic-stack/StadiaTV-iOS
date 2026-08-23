import Foundation

/// Downloads a live HLS stream to a local .ts file while the app is in the foreground.
///
/// Segment format requirements:
/// - MPEG-TS (.ts): fully supported. Segments are appended sequentially.
/// - fMP4 / CMAF (EXT-X-MAP present): rejected with `incompatibleFormat`.
///   These require initialisation-segment-aware reassembly that is out of scope here.
///   Channels using fMP4 should use providerDVR mode instead.
///
/// Background note: this recorder uses a standard (non-background) URLSession.
/// Recording will pause if the OS suspends the app. The caller (RecordingService)
/// is responsible for transitioning the job state to .partial in that event.
actor HLSRecorder {

    enum RecorderError: Error, LocalizedError {
        case playlistFetchFailed
        case noSegments
        case storageFull
        /// Provider returned HTTP 403 or 429 — connection/stream limit reached.
        case connectionLimited
        /// All retry attempts exhausted after network errors.
        case connectionLost
        /// EXT-X-MAP present: stream uses fMP4/CMAF which cannot be naively concatenated.
        case incompatibleFormat

        var errorDescription: String? {
            switch self {
            case .playlistFetchFailed:  return "Could not fetch the stream playlist."
            case .noSegments:           return "The playlist contained no downloadable segments."
            case .storageFull:          return "Not enough free storage to continue recording."
            case .connectionLimited:    return "Provider connection limit reached."
            case .connectionLost:       return "Connection to the stream was lost after retries."
            case .incompatibleFormat:   return "Stream uses fMP4/CMAF segments — use provider DVR instead."
            }
        }
    }

    private var isStopping = false
    private let session: URLSession
    // Abort if free space drops below this threshold.
    private static let minimumFreeBytes: Int64 = 200 * 1_048_576  // 200 MB

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Begins recording. Returns when recording ends — either via `stop()`, an error, or
    /// when EXT-X-ENDLIST is received (stream finished). Throws on fatal errors.
    func start(masterPlaylistURL: URL, outputURL: URL) async throws {
        isStopping = false

        let mediaURL = try await resolveMediaPlaylist(from: masterPlaylistURL)

        // Create the output file; fail early if the path is not writable.
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw RecorderError.playlistFetchFailed
        }
        defer { try? fileHandle.close() }

        var seenSegmentURLs: Set<String> = []
        var consecutiveErrors            = 0
        let maxConsecutiveErrors         = 3

        while !isStopping {
            try checkStorage(near: outputURL)

            // Fetch the current media playlist.
            let playlistData: Data
            do {
                (playlistData, _) = try await fetch(url: mediaURL, retries: 2)
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= maxConsecutiveErrors { throw RecorderError.connectionLost }
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            consecutiveErrors = 0

            let text = String(data: playlistData, encoding: .utf8) ?? ""

            // Reject fMP4 streams before writing anything.
            if text.contains("#EXT-X-MAP") { throw RecorderError.incompatibleFormat }

            let (segments, targetDuration) = parseMediaPlaylist(text, baseURL: mediaURL)
            let newSegments = segments.filter { !seenSegmentURLs.contains($0.absoluteString) }

            for segURL in newSegments {
                guard !isStopping else { break }
                try checkStorage(near: outputURL)

                do {
                    let (data, response) = try await fetch(url: segURL, retries: 2)

                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 403 || http.statusCode == 429 {
                            throw RecorderError.connectionLimited
                        }
                        guard (200...299).contains(http.statusCode) else {
                            consecutiveErrors += 1
                            if consecutiveErrors >= maxConsecutiveErrors { throw RecorderError.connectionLost }
                            continue
                        }
                    }

                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                    seenSegmentURLs.insert(segURL.absoluteString)
                    consecutiveErrors = 0

                } catch let err as RecorderError {
                    throw err
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= maxConsecutiveErrors { throw RecorderError.connectionLost }
                }
            }

            // Stream finished.
            if text.contains("#EXT-X-ENDLIST") { break }

            if !isStopping {
                let pollInterval = max(1.0, min(Double(targetDuration), 8.0))
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    /// Requests the recorder to stop after the current segment finishes.
    func stop() {
        isStopping = true
    }

    // MARK: - Playlist resolution

    private func resolveMediaPlaylist(from url: URL) async throws -> URL {
        let (data, _) = try await fetch(url: url, retries: 3)
        let text = String(data: data, encoding: .utf8) ?? ""

        // A master playlist has EXT-X-STREAM-INF; pick the highest-bandwidth variant.
        guard text.contains("#EXT-X-STREAM-INF") else { return url }

        let lines = text.components(separatedBy: .newlines)
        var bestBandwidth = -1
        var bestURL: URL?

        for i in 0..<lines.count {
            let line = lines[i]
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            let bw = extractBandwidth(from: line)
            guard i + 1 < lines.count else { continue }
            let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard !nextLine.isEmpty, !nextLine.hasPrefix("#"),
                  let variantURL = URL(string: nextLine, relativeTo: url)?.absoluteURL else { continue }
            if bw > bestBandwidth {
                bestBandwidth = bw
                bestURL = variantURL
            }
        }

        guard let resolved = bestURL else { throw RecorderError.noSegments }
        return resolved
    }

    // MARK: - Playlist parsing

    private func parseMediaPlaylist(_ text: String, baseURL: URL) -> (urls: [URL], targetDuration: Int) {
        let lines = text.components(separatedBy: .newlines)
        var urls: [URL] = []
        var targetDuration = 5

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:"),
               let val = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces)) {
                targetDuration = val
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let segURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                urls.append(segURL)
            }
        }
        return (urls, targetDuration)
    }

    private func extractBandwidth(from streamInfLine: String) -> Int {
        guard let range = streamInfLine.range(of: "BANDWIDTH=") else { return 0 }
        let suffix = String(streamInfLine[range.upperBound...])
        let digits = suffix.prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    // MARK: - Network helpers

    private func fetch(url: URL, retries: Int) async throws -> (Data, URLResponse) {
        var lastError: Error = RecorderError.connectionLost
        for attempt in 0..<max(1, retries) {
            do {
                return try await session.data(from: url)
            } catch {
                lastError = error
                if attempt < retries - 1 {
                    try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
                }
            }
        }
        throw lastError
    }

    // MARK: - Storage check

    private func checkStorage(near url: URL) throws {
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = vals?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        if available < Self.minimumFreeBytes { throw RecorderError.storageFull }
    }
}
