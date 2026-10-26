import Foundation

/// What the player shows about a running engine session.
nonisolated struct StreamEngineStatus: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case starting = "Starting"
        case playing = "Playing"
        case reconnecting = "Reconnecting in background"
        case waiting = "Waiting for provider"
        case failed = "Stopped"
    }

    var phase: Phase
    var route: String
    var codecs: String?
    /// Programme seconds held ahead of what's on screen (engine reserve plus AVPlayer's lead).
    var buffered: Double
    /// Of which still held by the engine.
    var reserve: Double
    var target: Double
    var playbackRate: Double
    var paceReason: String
    var connections: Int
    var reconnects: Int
    var routeSwitches: Int
    var splices: Int
    var overlapsRemoved: Int
    var timelineRepairs: Int
    var decoderResets: Int
    var deliveryRatio: Double?
    var bitrate: Double?
    var notice: StreamEngineNotice?
    var journal: [StreamEngineJournal.Entry]
}

/// One channel playing through the engine: provider connection → reserve → local HLS.
///
/// Everything runs on the session's serial queue except `handle(file:)`, which the local
/// server calls from its threads and which only reads the lock-protected publication.
nonisolated final class StreamEngineSession: @unchecked Sendable {
    nonisolated enum Event: Sendable {
        /// The local playlist has its first segments; give AVPlayer this URL.
        case ready(URL)
        /// The local server moved; rebuild the player item with the new URL.
        case endpointChanged(URL)
        case status(StreamEngineStatus)
        /// Pitch-corrected playback rate to apply.
        case pace(Double)
        /// AVPlayer has been stuck for a while with programme available: rebuild its item.
        case decoderResetRequested
        case failed(StreamEngineFailure)
    }

    struct Route: Equatable, Sendable {
        let url: URL
        let label: String
    }

    let id: String
    let routes: [Route]
    let configuration: StreamEngineConfiguration

    private let headers: [String: String]
    private let queue: DispatchQueue
    private let emitEvent: @Sendable (Event) -> Void
    private let publication = PublicationStore()
    private let epoch = Date()
    private let clockOrigin = ProcessInfo.processInfo.systemUptime
    private var baseURL: URL

    // Pipeline (queue-confined).
    private var aligner = TSPacketAligner()
    private let splicer = TSTimelineSplicer()
    private var segmenter: HLSSegmenter
    private var reserve: SegmentReserve
    private var health = StreamHealthMonitor()
    private var referee: RecoveryReferee
    private var pace = PlaybackPaceController()
    private var journal = StreamEngineJournal()
    private var codecs: String?
    /// Set once HEVC arrives: AVPlayer plays HEVC only from fragmented MP4, so from then on the
    /// session publishes fMP4 renditions under a multivariant playlist instead of MPEG-TS.
    private var packager: FragmentedPackager?
    /// Written once, when the first fMP4 segments are published.
    private var multivariantPlaylist: Data?
    /// HEVC was announced while MPEG-TS was already playing: switch at its first segment.
    private var switchToFragmentedPending = false
    /// The player must be moved to the fMP4 playlist once it has something to play.
    private var endpointChangePending = false
    /// Programme the provider dropped on the current connection, and when: a route that keeps
    /// dropping it gives way to another.
    private var droppedProgramme: [(time: Double, seconds: Double)] = []
    /// The route whose connection last delivered programme.
    private var deliveredRoute: Int?
    /// A route to move to once what the current connection delivered so far is committed.
    private var preferredRoute: Int?

    // Connection.
    private var connection: EngineConnection?
    private var connectionID = 0
    private var connectionRoute = 0
    private var connectionOpenedAt: Double?
    private var connectionDeliveredProgramme = false
    private var hlsRoutes: [Int: (url: URL, playlist: String?)] = [:]
    /// Last HLS media sequence delivered per route, so reconnects continue without a gap.
    private var hlsDelivered: [Int: Int] = [:]
    /// Longest normal gap between deliveries on the current connection.
    private var connectionCadence: Double = 0
    private var connectionsOpened = 0
    private var lastOutputEnd: Int64?
    /// Since when the GOP a drop cut short is held out of the reserve, waiting to see whether the
    /// reconnect re-sends it whole.
    private var tailHeldSince: Double?

    // Playback feedback from the player.
    private var playhead: Double?
    private var playheadReportedAt: Double?
    private var playerRate: Double = 0
    private var playerWaiting = false
    private var playerPlaying = false
    /// The player has played at least once. Until then its reports only say where it will start.
    private var playerHasPlayed = false
    private var firstPublishedAt: Double?
    /// When the first segment reached the reserve.
    private var firstSegmentAt: Double?
    private var firstPublishedStart: Double?
    private var holdForRebuffer = false
    private var joinTarget: Double?
    private var decoderStuckSince: Double?
    private var lastDecoderReset: Double = -.infinity
    private var decoderResets = 0

    private var timer: DispatchSourceTimer?
    private var started = false
    private var stopped = false
    private var announcedReady = false
    private var lastPaceUpdate: Double = 0
    private var lastStatus: Double = 0
    private var lastPaceReason: PlaybackPaceController.Reason = .normal

    init(id: String, routes: [Route], headers: [String: String], configuration: StreamEngineConfiguration,
         isSingleConnectionAccount: Bool, baseURL: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.id = id
        self.routes = routes
        self.headers = headers
        self.configuration = configuration
        self.baseURL = baseURL
        self.emitEvent = onEvent
        self.queue = DispatchQueue(label: "BannerTV.StreamEngine.session.\(id)", qos: .userInitiated)
        self.segmenter = HLSSegmenter(configuration: configuration.segmenter)
        self.reserve = SegmentReserve(configuration: .init(backBufferSeconds: configuration.backBufferSeconds,
                                                           maximumBytes: configuration.maximumReserveBytes))
        self.referee = RecoveryReferee(configuration: configuration, routeCount: routes.count,
                                       isSingleConnectionAccount: isSingleConnectionAccount)
    }

    var playlistURL: URL { baseURL.appendingPathComponent("live.m3u8") }

    // MARK: - Control (any thread)

    func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            journal.record(.connection, "Engine started (\(configuration.profile.rawValue) profile)", buffered: 0)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            perform(referee.start(at: now()))
        }
    }

    func stop() {
        queue.async { [self] in
            shutDown()
        }
        publication.close()
    }

    /// Where AVPlayer is, in the engine's programme time (seconds since the session's first picture).
    func reportPlayback(programmeTime: Double?, isWaiting: Bool, isPlaying: Bool, rate: Double) {
        queue.async { [self] in
            let time = now()
            if let programmeTime, programmeTime.isFinite {
                playhead = programmeTime
                playheadReportedAt = time
                if let target = joinTarget, programmeTime >= target - 1 { joinTarget = nil }
            }
            playerWaiting = isWaiting
            playerPlaying = isPlaying
            if isPlaying { playerHasPlayed = true }
            playerRate = rate
        }
    }

    /// Hands the whole reserve to the player so the next item starts near the newest programme.
    /// Synchronous so the rebuilt player item never fetches the old playlist.
    func jumpToLive() {
        queue.sync {
            reserve.publishAll()
            if let end = reserve.publishedEnd {
                joinTarget = max(reserve.published.first?.programmeStart ?? 0, end - configuration.lead)
            }
            holdForRebuffer = false
            journal.record(.recovery, "Jumped to the newest programme", buffered: bufferedAhead(now()))
            renderPlaylist()
        }
    }

    /// The player rebuilt its item (decoder reset); the next item should rejoin at the playhead.
    func noteDecoderReset() {
        queue.async { [self] in
            decoderResets += 1
            journal.record(.decoder, "Player item rebuilt", buffered: bufferedAhead(now()))
            renderPlaylist()
        }
    }

    /// Updates the local server address after the listener was rebuilt.
    func updateBaseURL(_ url: URL) {
        queue.async { [self] in
            baseURL = url
            guard announcedReady, !stopped else { return }
            emitEvent(.endpointChanged(playlistURL))
        }
    }

    // MARK: - Local HTTP (server threads)

    func handle(file: String) -> LoopbackHTTPServer.Response {
        if file == "live.m3u8" {
            guard let playlist = publication.waitForPlaylist(timeout: 10) else { return .unavailable() }
            return LoopbackHTTPServer.Response(status: 200, contentType: "application/vnd.apple.mpegurl", body: playlist)
        }
        guard let data = publication.file(file) else { return .notFound() }
        if file.hasSuffix(".m3u8") {
            return LoopbackHTTPServer.Response(status: 200, contentType: "application/vnd.apple.mpegurl", body: data)
        }
        let type = file.hasSuffix(".ts") ? "video/mp2t" : file.hasSuffix(".m4s") ? "video/iso.segment" : "video/mp4"
        return LoopbackHTTPServer.Response(status: 200, contentType: type, body: data, cacheControl: "max-age=3600")
    }

    // MARK: - Connections

    private func now() -> Double { ProcessInfo.processInfo.systemUptime - clockOrigin }

    /// Longest a cut-short GOP waits for the reconnect to re-send it.
    private static let tailHoldLimit: Double = 6
    /// Longest the first playlist waits for a few seconds of programme.
    private static let startupWaitLimit: Double = 3
    /// How far behind its live end HLS ingest joins when the session moves to it mid-stream.
    private static let switchJoinSeconds: Double = 4

    private func perform(_ actions: [RecoveryReferee.Action]) {
        for action in actions {
            switch action {
            case .connect(let route): openConnection(route: route)
            case .disconnect: closeConnection()
            case .fail(let failure): fail(failure)
            }
        }
        recordDecisions()
    }

    private func openConnection(route: Int) {
        guard !stopped else { return }
        closeConnection()
        connectionID += 1
        connectionsOpened += 1
        let otherRoute = deliveredRoute.map { $0 != route } ?? false
        connectionRoute = route
        let id = connectionID
        aligner.reset()
        splicer.beginConnection(otherRoute: otherRoute)
        connectionOpenedAt = now()
        connectionDeliveredProgramme = false
        connectionCadence = 0
        droppedProgramme.removeAll()
        health.connectionOpened(at: now())
        let emit: (EngineConnectionEvent) -> Void = { [weak self] event in self?.handle(event, connection: id) }
        if let hls = hlsRoutes[route] {
            hlsRoutes[route]?.playlist = nil
            // Joining deep in the window fills the reserve at start-up. Later (moving here from another
            // route) the reserve already holds that programme: join at the newest segments, where the next
            // new programme is, and never further back than what was delivered, which the splicer recognises
            // by its keyframes (older programme would be taken for a new clock and replayed).
            let fresh = splicer.outputEnd == nil
            connection = HLSIngestConnection(playlistURL: hls.url, initialPlaylist: hls.playlist, headers: headers,
                                             joinSeconds: fresh ? configuration.targetBuffer : min(Self.switchJoinSeconds, max(0, ingestEdge - 2)),
                                             joinDepth: fresh ? HLSIngestConnection.joinDepth : 1, resumeAfter: hlsDelivered[route],
                                             queue: queue, emit: emit)
        } else {
            connection = TSStreamConnection(url: routes[route].url, headers: headers, queue: queue, emit: emit)
        }
        connection?.start()
    }

    /// Closes the current connection; what it already delivered stays playable.
    private func closeConnection() {
        guard let current = connection else { return }
        current.cancel()
        connection = nil
        connectionID += 1
        finishConnectionPipeline()
    }

    private func finishConnectionPipeline() {
        // HLS ingest hands over whole segments, so the PES packets one leaves open are whole.
        let finished = splicer.endConnection(atUnitBoundary: hlsRoutes[connectionRoute] != nil, wallTime: now())
        if !finished.isEmpty { commit(finished, at: now()) }
        aligner.reset()
        health.connectionClosed()
        holdTail()
    }

    /// After a drop, what arrived up to the last keyframe goes into the reserve at once; the rest of
    /// that GOP is held back. Providers re-send the last seconds on reconnect: when the new connection
    /// re-sends that keyframe, it delivers the GOP again, complete, and the splice loses nothing.
    /// Only while the reserve can cover the wait; HLS ingest resumes after its last segment instead.
    private func holdTail() {
        let isTransportStream = hlsRoutes[connectionRoute] == nil
        if isTransportStream, let keyframe = splicer.resumeKeyframeTime {
            // Cutting at the keyframe is harmless either way: what came before it is playable now.
            let split = segmenter.holdTail(fromKeyframeAt: keyframe)
            if let closed = split.closed {
                appendToReserve(closed)
                publishIfNeeded()
            }
            if split.held, reserveAhead(now()) >= tailHoldMinimum {
                tailHeldSince = tailHeldSince ?? now()
                return
            }
        }
        releaseTail()
    }

    /// Commits whatever the segmenter holds, so it can be played; no resume after this.
    private func releaseTail() {
        tailHeldSince = nil
        splicer.discardResumePoint()
        if let segment = segmenter.flush() {
            appendToReserve(segment)
            publishIfNeeded()
        }
    }

    private func handle(_ event: EngineConnectionEvent, connection id: Int) {
        guard id == connectionID, !stopped else { return }
        let time = now()
        switch event {
        case .opened(_, let cadence):
            connectionCadence = cadence
            referee.providerAnswered()
        case .received(let bytes):
            health.received(bytes: bytes, at: time)
        case .media(let data):
            ingest(data, at: time)
        case .segmentDelivered(let sequence):
            hlsDelivered[connectionRoute] = sequence
            splicer.segmentEnded()
        case .sourceDiscontinuity:
            let finished = splicer.beginSourceDiscontinuity(wallTime: time)
            if !finished.isEmpty { commit(finished, at: time) }
            journal.record(.splice, "Provider announced a discontinuity", buffered: bufferedAhead(time))
        case .playlist(let text, let url):
            // This route serves HLS: switch it to playlist ingest without counting a failure.
            journal.record(.connection, "\(routes[connectionRoute].label) route serves HLS; following its playlist", buffered: bufferedAhead(time))
            hlsRoutes[connectionRoute] = (url, text)
            connection = nil
            openConnection(route: connectionRoute)
        case .ended(let kind):
            connection = nil
            connectionID += 1
            finishConnectionPipeline()
            perform(referee.connectionEnded(kind, at: time, openedAt: connectionOpenedAt,
                                            deliveredProgramme: connectionDeliveredProgramme,
                                            drought: health.programmeDrought(at: time)))
        }
    }

    // MARK: - Pipeline

    private func ingest(_ data: Data, at time: Double) {
        let packets = aligner.push(data)
        guard !packets.isEmpty else { return }
        commit(splicer.process(packets, wallTime: time), at: time)
    }

    /// Takes what the splicer produced through the segmenter into the reserve.
    private func commit(_ units: [NormalizedUnit], at time: Double) {
        handleSplicerEvents(at: time)
        let finished = segmenter.append(units)
        if let end = splicer.outputEnd {
            if let last = lastOutputEnd {
                let advance = MPEGTS.signedDelta(end, last)
                if advance > 0 {
                    health.ingested(programmeSeconds: MPEGTS.seconds(advance), at: time)
                    lastOutputEnd = end
                }
            } else {
                lastOutputEnd = end
                health.ingested(programmeSeconds: MPEGTS.seconds(splicer.frameDuration), at: time)
            }
            if !connectionDeliveredProgramme, lastOutputEnd == end {
                connectionDeliveredProgramme = true
                deliveredRoute = connectionRoute
                referee.programmeArrived(at: time)
                recordDecisions()
            }
        }
        for segment in finished { appendToReserve(segment) }
        if !finished.isEmpty { publishIfNeeded() }
        if let route = preferredRoute {
            preferredRoute = nil
            perform(referee.prefer(route: route, at: time, reason: "HEVC plays from the panel's HLS output"))
        }
    }

    private func handleSplicerEvents(at time: Double) {
        for event in splicer.drainEvents() {
            switch event {
            case .program(let program):
                codecs = program.codecSummary
                journal.record(.splice, "Program: \(program.codecSummary)", buffered: bufferedAhead(time))
                if packager == nil, case .video(.hevc)? = program.video?.kind { startFragmentedPublishing(at: time) }
            case .splice(let report):
                guard report.kind != .start else { continue }
                if report.kind == .resumed {
                    // The held GOP is being delivered again, complete.
                    segmenter.discardOpenSegment()
                    tailHeldSince = nil
                    journal.record(.splice, String(format: "Rejoined at the last keyframe, nothing missed (%.1f s re-sent)", report.skippedSeconds),
                                   buffered: bufferedAhead(time))
                    continue
                }
                if tailHeldSince != nil {
                    // Not re-sent: what was held plays before the new connection's programme.
                    tailHeldSince = nil
                    if let segment = segmenter.flush() {
                        appendToReserve(segment)
                        publishIfNeeded()
                    }
                }
                // A jump inside one connection is a stretch the provider dropped too long to close up
                // on the spot (or a clock jump): it counts toward the route's dropped programme.
                if report.kind == .timelineJump { droppedProgramme.append((time, 0)) }
                var message = "Spliced (\(report.kind.rawValue))"
                if report.skippedSeconds > 0 { message += String(format: ", skipped %.1f s already played", report.skippedSeconds) }
                if report.missingSeconds > 0.05 { message += String(format: ", %.1f s of programme missing", report.missingSeconds) }
                journal.record(.splice, message, buffered: bufferedAhead(time))
            case .unsupportedProgram(let reason):
                journal.record(.warning, reason, buffered: bufferedAhead(time))
                if !announcedReady { fail(.unsupported(reason)) }
            case .sourceGapClosed(let seconds):
                droppedProgramme.append((time, seconds))
                journal.record(.splice, String(format: "Provider dropped %.2f s of programme: closed up", seconds),
                               buffered: bufferedAhead(time))
            }
        }
    }

    // MARK: - Publishing

    /// Adds a finished segment to the reserve, repackaged as fragmented MP4 in an HEVC session.
    private func appendToReserve(_ segment: MediaSegment) {
        if switchToFragmentedPending, FragmentedPackager.carriesHEVC(segment) {
            // MPEG-TS played up to here; the HEVC programme starts a fresh fMP4 publication and
            // the player is moved to it as soon as it can start.
            switchToFragmentedPending = false
            packager = FragmentedPackager()
            multivariantPlaylist = nil
            reserve = SegmentReserve(configuration: reserve.configuration)
            firstSegmentAt = nil
            endpointChangePending = true
            journal.record(.connection, "HEVC: moving the player to fragmented MP4 renditions", buffered: bufferedAhead(now()))
        }
        guard let packager else {
            reserve.append(segment)
            return
        }
        // Without parameter sets so far the segment can't be decoded; the next keyframe brings them.
        if let packaged = packager.package(segment) { reserve.append(packaged) }
    }

    /// From now on segments are published as fMP4. Mid-session, MPEG-TS carries on until the
    /// first HEVC segment is complete.
    private func startFragmentedPublishing(at time: Double) {
        guard reserve.segments.isEmpty, !announcedReady else {
            switchToFragmentedPending = true
            return
        }
        packager = FragmentedPackager()
        journal.record(.connection, "HEVC: publishing fragmented MP4 renditions", buffered: bufferedAhead(time))
        // Panels' MPEG-TS output drops chunks of 4K streams that their HLS output carries whole: before
        // anything plays, move to the HLS route, whose window then fills the reserve at once.
        if hlsRoutes[connectionRoute] == nil, routes[connectionRoute].label != "HLS" {
            preferredRoute = routes.indices.first { routes[$0].label == "HLS" }
        }
    }

    /// Programme time at the end of everything ingested.
    private var ingestEdge: Double { (reserve.ingestEnd ?? 0) + segmenter.openDuration }

    /// Programme in the reserve ahead of the picture, not counting the segment still being cut.
    private func reserveAhead(_ time: Double) -> Double {
        guard let end = reserve.ingestEnd else { return 0 }
        guard let head = estimatedPlayhead(time) else { return end - (reserve.published.first?.programmeStart ?? end) }
        return max(0, end - head)
    }

    /// A GOP is only held while the player has this much else ahead of it: enough to keep playing
    /// through AVPlayer's playlist reload delay (a target duration) if the hold ends late.
    private var tailHoldMinimum: Double { Double(configuration.segmenter.playlistTargetDuration) + 1.5 }

    /// Silence that is normal on the current connection: an HLS playlist's target duration between
    /// segments, or the rhythm a continuous stream has been seen to deliver in.
    private var normalSilence: Double {
        max(connectionCadence > 0 ? 2 * connectionCadence + 2 : 0,
            health.deliveryCadence > 0 ? 1.5 * health.deliveryCadence + 1 : 0)
    }

    /// AVPlayer's position, extrapolated between reports.
    private func estimatedPlayhead(_ time: Double) -> Double? {
        if let playhead, let reportedAt = playheadReportedAt, playerHasPlayed {
            let advance = playerPlaying ? max(0, time - reportedAt) * max(0, playerRate) : 0
            return playhead + min(advance, 3)
        }
        // No report yet, or the player hasn't started playing: assume playback began about a second
        // after the first segment went out, so the playlist keeps growing. A player still starting
        // reports the position it will start from; publishing no further than that would leave the
        // playlist unchanged, which AVPlayer treats as an error after 1.5 target durations.
        if let firstPublishedAt, let start = firstPublishedStart {
            return start + max(0, time - firstPublishedAt - 1)
        }
        return playhead
    }

    private func bufferedAhead(_ time: Double) -> Double {
        guard let head = estimatedPlayhead(time) else { return ingestEdge - (reserve.published.first?.programmeStart ?? 0) }
        return max(0, ingestEdge - head)
    }

    private func publishedAhead(_ time: Double) -> Double {
        guard let end = reserve.publishedEnd else { return 0 }
        guard let head = estimatedPlayhead(time) else { return end - (reserve.published.first?.programmeStart ?? end) }
        return max(0, end - head)
    }

    /// The viewer is looking at a frozen picture because nothing more has been handed over. The
    /// player only sees new segments when it reloads the playlist (about every segment), so a
    /// stall with no more than a segment published counts as starvation.
    private func isStarved(_ time: Double) -> Bool {
        playerWaiting && publishedAhead(time) < configuration.segmenter.targetDuration + 0.5
    }

    /// Hands the next segments to AVPlayer, keeping `lead` seconds published ahead of its playhead.
    private func publishIfNeeded() {
        let time = now()
        var changed = false
        if reserve.publishedCount == 0 {
            guard let first = reserve.segments.first else { return }
            // AVPlayer reloads a live playlist only a target duration after loading it, so the first
            // playlist must carry enough to play until then: wait for that (the provider's burst
            // usually brings it at once), but not for long when the provider sends in real time.
            let firstSegmentAt = self.firstSegmentAt ?? time
            self.firstSegmentAt = firstSegmentAt
            let startupLead = min(configuration.lead, Double(configuration.segmenter.playlistTargetDuration) + 1)
            guard reserve.reserveSeconds >= startupLead || time - firstSegmentAt >= Self.startupWaitLimit else { return }
            reserve.publishNext()
            reserve.publish(before: first.programmeStart + configuration.lead)
            firstPublishedAt = time
            firstPublishedStart = first.programmeStart
            changed = true
        } else if holdForRebuffer {
            if reserve.reserveSeconds >= configuration.rebufferGoal {
                holdForRebuffer = false
                journal.record(.recovery, String(format: "Resuming with %.1f s rebuilt", reserve.reserveSeconds), buffered: bufferedAhead(time))
            }
        }
        if !holdForRebuffer, reserve.publishedCount > 0 {
            let head = estimatedPlayhead(time) ?? (reserve.published.first?.programmeStart ?? 0)
            if reserve.publish(before: head + configuration.lead) > 0 { changed = true }
        }
        if changed {
            renderPlaylist()
            if !announcedReady {
                announcedReady = true
                journal.record(.connection, "First picture ready", buffered: bufferedAhead(time))
                emitEvent(.ready(playlistURL))
            } else if endpointChangePending {
                endpointChangePending = false
                emitEvent(.endpointChanged(playlistURL))
            }
        }
    }

    private func renderPlaylist() {
        let window = reserve.published
        guard !window.isEmpty else { return }
        // Where a (re)built player item should start: the keyframe segment under the playhead.
        let target = joinTarget ?? estimatedPlayhead(now()) ?? window.first?.programmeStart ?? 0
        let join = reserve.joinPoint(atOrBefore: target)
        if let packager {
            publication.update(files: fragmentedFiles(window: window, join: join, packager: packager))
            return
        }
        let offset = join.map { $0.programmeStart - (window.first?.programmeStart ?? 0) }
        let text = HLSPlaylistWriter.mediaPlaylist(segments: window, targetDuration: configuration.segmenter.playlistTargetDuration,
                                                   discontinuitySequence: reserve.evictedDiscontinuities,
                                                   epoch: epoch, startOffset: offset)
        var files = ["live.m3u8": Data(text.utf8)]
        for segment in window { files["s\(segment.sequence).ts"] = segment.data }
        publication.update(files: files)
    }

    /// The multivariant playlist, each rendition's media playlist, and what they list.
    private func fragmentedFiles(window: ArraySlice<MediaSegment>, join: MediaSegment?,
                                 packager: FragmentedPackager) -> [String: Data] {
        var files: [String: Data] = [:]
        func mediaPlaylist(_ entries: [HLSPlaylistWriter.FragmentEntry], sequence: Int) -> Data {
            // Every rendition starts where a rebuilt player item should: the same moment in each.
            let offset = join.flatMap { join in entries.first.map { join.programmeStart - $0.programmeStart } }
            return Data(HLSPlaylistWriter.fragmentedMediaPlaylist(
                entries: entries, mediaSequence: sequence, targetDuration: configuration.segmenter.playlistTargetDuration,
                discontinuitySequence: reserve.evictedDiscontinuities, epoch: epoch, startOffset: offset).utf8)
        }
        var video: [HLSPlaylistWriter.FragmentEntry] = []
        for segment in window {
            guard let number = segment.initialization else { continue }
            let map = "v\(number).mp4"
            if files[map] == nil { files[map] = packager.videoInitialization(number) }
            files["v\(segment.sequence).m4s"] = segment.data
            video.append(.init(uri: "v\(segment.sequence).m4s", map: map, duration: segment.duration,
                               programmeStart: segment.programmeStart, isDiscontinuity: segment.isDiscontinuity,
                               isIndependent: segment.startsWithKeyframe))
        }
        files["video.m3u8"] = mediaPlaylist(video, sequence: window.first?.sequence ?? 0)

        let renditions = packager.audioRenditions
        for rendition in renditions {
            var entries: [HLSPlaylistWriter.FragmentEntry] = []
            var firstSequence: Int?
            for segment in window {
                guard let fragment = segment.audio.first(where: { $0.rendition == rendition.index }) else { continue }
                let map = "a\(rendition.index)-\(fragment.initialization).mp4"
                if files[map] == nil { files[map] = packager.audioInitialization(rendition: rendition.index, number: fragment.initialization) }
                let uri = "a\(rendition.index)-\(segment.sequence).m4s"
                files[uri] = fragment.data
                firstSequence = firstSequence ?? segment.sequence
                entries.append(.init(uri: uri, map: map, duration: fragment.duration, programmeStart: fragment.programmeStart,
                                     isDiscontinuity: segment.isDiscontinuity))
            }
            files["audio\(rendition.index).m3u8"] = mediaPlaylist(entries, sequence: firstSequence ?? 0)
        }

        if multivariantPlaylist == nil, let format = packager.videoFormat {
            // Bit rates from what the reserve holds: the peak segment and the average.
            let held = reserve.segments.filter { $0.duration > 0.5 }
            let rates = held.map { Double(($0.data.count + ($0.audio.first?.data.count ?? 0)) * 8) / $0.duration }
            let average = rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)
            var names: Set<String> = []
            let audio = renditions.enumerated().map { position, rendition -> HLSPlaylistWriter.AudioRenditionTag in
                let language = Self.languageTag(rendition.language)
                var name = Self.languageName(language)
                var copy = 2
                while !names.insert(name).inserted {
                    name = "\(Self.languageName(language)) \(copy)"
                    copy += 1
                }
                return .init(uri: "audio\(rendition.index).m3u8", name: name, language: language,
                             channels: rendition.format.channelCount, isDefault: position == 0)
            }
            var codecs = [format.codecString]
            for rendition in renditions where !codecs.contains(rendition.format.codecString) { codecs.append(rendition.format.codecString) }
            multivariantPlaylist = Data(HLSPlaylistWriter.multivariantPlaylist(
                videoURI: "video.m3u8", bandwidth: Int((rates.max() ?? 0) * 1.1), averageBandwidth: Int(average),
                codecs: codecs, width: format.width, height: format.height, frameRate: packager.frameRate,
                videoRange: format.videoRange, audio: audio).utf8)
        }
        files["live.m3u8"] = multivariantPlaylist
        return files
    }

    /// RFC 5646 tags for the ISO 639-2 codes broadcasters use; others are valid as they are.
    private static func languageTag(_ code: String) -> String {
        let twoLetter = ["eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it", "spa": "es", "por": "pt",
                         "rus": "ru", "ara": "ar", "tur": "tr", "nld": "nl", "dut": "nl", "pol": "pl", "swe": "sv", "nor": "no",
                         "nob": "nb", "dan": "da", "fin": "fi", "ell": "el", "gre": "el", "ces": "cs", "cze": "cs", "hun": "hu",
                         "ron": "ro", "rum": "ro", "bul": "bg", "hrv": "hr", "srp": "sr", "slk": "sk", "slo": "sk", "slv": "sl",
                         "ukr": "uk", "heb": "he", "fas": "fa", "per": "fa", "hin": "hi", "urd": "ur", "zho": "zh", "chi": "zh",
                         "jpn": "ja", "kor": "ko", "tha": "th", "vie": "vi", "ind": "id", "msa": "ms", "may": "ms", "cat": "ca",
                         "alb": "sq", "sqi": "sq", "mkd": "mk", "mac": "mk", "bos": "bs", "kur": "ku", "aze": "az", "est": "et",
                         "lav": "lv", "lit": "lt", "isl": "is", "ice": "is", "gle": "ga", "cym": "cy", "wel": "cy", "eus": "eu",
                         "baq": "eu", "glg": "gl"]
        if let tag = twoLetter[code] { return tag }
        return code.count == 3 && !code.hasPrefix("q") && code != "mis" ? code : "und"
    }

    private static func languageName(_ tag: String) -> String {
        guard tag != "und" else { return "Audio" }
        return (Locale.current.localizedString(forLanguageCode: tag) ?? tag.uppercased()).replacingOccurrences(of: "\"", with: "")
    }

    /// The date EXT-X-PROGRAM-DATE-TIME gives to programme time zero.
    var programmeEpoch: Date { epoch }

    // MARK: - Periodic work

    private func tick() {
        guard !stopped else { return }
        let time = now()
        health.sample(at: time)
        let buffered = bufferedAhead(time)
        let starved = isStarved(time)

        if starved, !holdForRebuffer, reserve.reserveSeconds < configuration.rebufferGoal, announcedReady {
            holdForRebuffer = true
            journal.record(.recovery, "Reserve empty: holding the picture until it is rebuilt", buffered: buffered)
        }

        droppedProgramme.removeAll { time - $0.time > RecoveryReferee.droppedProgrammeWindow }
        perform(referee.tick(.init(now: time, buffered: buffered, isStarved: starved, health: health,
                                   silenceFloor: normalSilence,
                                   droppedProgramme: droppedProgramme.reduce(0) { $0 + $1.seconds },
                                   droppedGaps: droppedProgramme.count)))
        guard !stopped else { return }
        if let since = tailHeldSince, time - since >= Self.tailHoldLimit || reserveAhead(time) < tailHoldMinimum - 1 {
            journal.record(.splice, "Reconnect slow: releasing the held GOP", buffered: buffered)
            releaseTail()
        }
        publishIfNeeded()
        reserve.evict(playhead: estimatedPlayhead(time))

        if time - lastPaceUpdate >= 1 {
            let isOutage = connection == nil || (health.programmeDrought(at: time) ?? 0) > max(3, normalSilence)
            if let rate = pace.update(buffered: buffered, deliveryRatio: health.slowRatio, isOutage: isOutage,
                                      isStarved: starved, configuration: configuration, elapsed: time - lastPaceUpdate) {
                emitEvent(.pace(rate))
            }
            if pace.reason != lastPaceReason {
                journal.record(.pace, String(format: "Playback %.3fx (%@)", pace.rate, pace.reason.rawValue), buffered: buffered)
                lastPaceReason = pace.reason
            }
            referee.noteSlowLine(pace.reason == .slowLine && pace.rate < 0.985)
            lastPaceUpdate = time
        }

        checkDecoder(at: time)

        if time - lastStatus >= 1 {
            lastStatus = time
            emitEvent(.status(status(at: time, buffered: buffered)))
        }
    }

    /// AVPlayer waiting while several seconds are published ahead of it is a decoder problem,
    /// not a network one: only then is rebuilding the player item the right remedy.
    private func checkDecoder(at time: Double) {
        guard playerWaiting, publishedAhead(time) >= 3 else {
            decoderStuckSince = nil
            return
        }
        let since = decoderStuckSince ?? time
        decoderStuckSince = since
        if time - since >= 8, time - lastDecoderReset >= 30 {
            lastDecoderReset = time
            decoderStuckSince = nil
            journal.record(.decoder, "Player stalled with programme available", buffered: bufferedAhead(time))
            emitEvent(.decoderResetRequested)
        }
    }

    private func status(at time: Double, buffered: Double) -> StreamEngineStatus {
        let phase: StreamEngineStatus.Phase
        switch referee.phase {
        case .finished: phase = .failed
        case .idle: phase = .starting
        case .connecting, .waiting:
            phase = !announcedReady ? .starting : (isStarved(time) ? .waiting : .reconnecting)
        case .streaming:
            phase = !announcedReady ? .starting : (isStarved(time) ? .waiting : .playing)
        }
        let statistics = splicer.statistics
        return StreamEngineStatus(
            phase: phase, route: hlsRoutes[connectionRoute] != nil ? "HLS" : routes[connectionRoute].label, codecs: codecs,
            buffered: buffered, reserve: reserve.reserveSeconds, target: configuration.targetBuffer,
            playbackRate: pace.rate, paceReason: pace.reason.rawValue,
            connections: connectionsOpened, reconnects: referee.reconnects, routeSwitches: referee.routeSwitches,
            splices: statistics.splices, overlapsRemoved: statistics.overlapsRemoved,
            timelineRepairs: statistics.timebaseResets + statistics.timelineJumps + statistics.gapsClosed + statistics.sourceGaps,
            decoderResets: decoderResets, deliveryRatio: health.slowRatio,
            bitrate: health.streamBitrate, notice: referee.notice, journal: journal.recent(12))
    }

    private func recordDecisions() {
        let buffered = bufferedAhead(now())
        for decision in referee.drainDecisions() { journal.record(.recovery, decision, buffered: buffered) }
    }

    private func fail(_ failure: StreamEngineFailure) {
        guard !stopped else { return }
        journal.record(.warning, "Stopped: \(failure.message)", buffered: bufferedAhead(now()))
        emitEvent(.status(status(at: now(), buffered: bufferedAhead(now()))))
        shutDown()
        emitEvent(.failed(failure))
    }

    private func shutDown() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        publication.close()
        StreamEngine.shared.remove(sessionID: id)
    }
}

/// The published window, readable from the server's threads.
nonisolated final class PublicationStore: @unchecked Sendable {
    private let condition = NSCondition()
    /// Playlists, initialization sections and segments, by the name AVPlayer requests.
    private var files: [String: Data] = [:]
    private var closed = false

    func update(files: [String: Data]) {
        condition.lock()
        self.files = files
        condition.broadcast()
        condition.unlock()
    }

    /// The top-level playlist, once the first one is published.
    func waitForPlaylist(timeout: Double) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while files["live.m3u8"] == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        return closed ? nil : files["live.m3u8"]
    }

    func file(_ name: String) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return files[name]
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
