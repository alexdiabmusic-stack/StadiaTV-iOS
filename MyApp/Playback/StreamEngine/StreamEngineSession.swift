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

    // Playback feedback from the player.
    private var playhead: Double?
    private var playheadReportedAt: Double?
    private var playerRate: Double = 0
    private var playerWaiting = false
    private var playerPlaying = false
    private var firstPublishedAt: Double?
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
        if file.hasPrefix("s"), file.hasSuffix(".ts"), let sequence = Int(file.dropFirst().dropLast(3)),
           let data = publication.segment(sequence) {
            return LoopbackHTTPServer.Response(status: 200, contentType: "video/mp2t", body: data, cacheControl: "max-age=3600")
        }
        return .notFound()
    }

    // MARK: - Connections

    private func now() -> Double { ProcessInfo.processInfo.systemUptime - clockOrigin }

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
        connectionRoute = route
        let id = connectionID
        aligner.reset()
        splicer.beginConnection()
        connectionOpenedAt = now()
        connectionDeliveredProgramme = false
        connectionCadence = 0
        health.connectionOpened(at: now())
        let emit: (EngineConnectionEvent) -> Void = { [weak self] event in self?.handle(event, connection: id) }
        if let hls = hlsRoutes[route] {
            hlsRoutes[route]?.playlist = nil
            connection = HLSIngestConnection(playlistURL: hls.url, initialPlaylist: hls.playlist, headers: headers,
                                             joinSeconds: configuration.targetBuffer, resumeAfter: hlsDelivered[route],
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
        splicer.endConnection()
        aligner.reset()
        health.connectionClosed()
        if let segment = segmenter.flush() {
            reserve.append(segment)
            publishIfNeeded()
        }
    }

    private func handle(_ event: EngineConnectionEvent, connection id: Int) {
        guard id == connectionID, !stopped else { return }
        let time = now()
        switch event {
        case .opened(_, let cadence):
            connectionCadence = cadence
        case .received(let bytes):
            health.received(bytes: bytes, at: time)
        case .media(let data):
            ingest(data, at: time)
        case .segmentDelivered(let sequence):
            hlsDelivered[connectionRoute] = sequence
        case .sourceDiscontinuity:
            splicer.beginSourceDiscontinuity()
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
        let units = splicer.process(packets, wallTime: time)
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
                referee.programmeArrived(at: time)
                recordDecisions()
            }
        }
        for segment in finished { reserve.append(segment) }
        if !finished.isEmpty { publishIfNeeded() }
    }

    private func handleSplicerEvents(at time: Double) {
        for event in splicer.drainEvents() {
            switch event {
            case .program(let program):
                codecs = program.codecSummary
                journal.record(.splice, "Program: \(program.codecSummary)", buffered: bufferedAhead(time))
            case .splice(let report):
                guard report.kind != .start else { continue }
                var message = "Spliced (\(report.kind.rawValue))"
                if report.skippedSeconds > 0 { message += String(format: ", skipped %.1f s already played", report.skippedSeconds) }
                if report.missingSeconds > 0.05 { message += String(format: ", %.1f s of programme missing", report.missingSeconds) }
                journal.record(.splice, message, buffered: bufferedAhead(time))
            case .unsupportedProgram(let reason):
                journal.record(.warning, reason, buffered: bufferedAhead(time))
                if !announcedReady { fail(.unsupported(reason)) }
            }
        }
    }

    // MARK: - Publishing

    /// Programme time at the end of everything ingested.
    private var ingestEdge: Double { (reserve.ingestEnd ?? 0) + segmenter.openDuration }

    /// AVPlayer's position, extrapolated between reports.
    private func estimatedPlayhead(_ time: Double) -> Double? {
        if let playhead, let reportedAt = playheadReportedAt {
            let advance = playerPlaying ? max(0, time - reportedAt) * max(0, playerRate) : 0
            return playhead + min(advance, 3)
        }
        // No report yet: assume playback began about a second after the first segment went out,
        // so publishing never stalls on a player that doesn't report.
        if let firstPublishedAt, let start = firstPublishedStart {
            return start + max(0, time - firstPublishedAt - 1)
        }
        return nil
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
            // Fast start: the first segment goes out immediately, then up to the lead.
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
            }
        }
    }

    private func renderPlaylist() {
        let window = reserve.published
        guard !window.isEmpty else { return }
        // Where a (re)built player item should start: the keyframe segment under the playhead.
        let target = joinTarget ?? estimatedPlayhead(now()) ?? window.first?.programmeStart ?? 0
        let join = reserve.joinPoint(atOrBefore: target)
        let offset = join.map { $0.programmeStart - (window.first?.programmeStart ?? 0) }
        let text = HLSPlaylistWriter.mediaPlaylist(segments: window, targetDuration: configuration.segmenter.playlistTargetDuration,
                                                   discontinuitySequence: reserve.evictedDiscontinuities,
                                                   epoch: epoch, startOffset: offset)
        publication.update(playlist: Data(text.utf8), segments: Array(window))
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

        perform(referee.tick(.init(now: time, buffered: buffered, isStarved: starved, health: health,
                                   silenceFloor: connectionCadence > 0 ? 2 * connectionCadence + 2 : 0)))
        guard !stopped else { return }
        publishIfNeeded()
        reserve.evict(playhead: estimatedPlayhead(time))

        if time - lastPaceUpdate >= 1 {
            let isOutage = connection == nil || (health.programmeDrought(at: time) ?? 0) > 3
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
            timelineRepairs: statistics.timebaseResets + statistics.timelineJumps + statistics.gapsClosed,
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
    private var playlist: Data?
    private var segments: [Int: Data] = [:]
    private var closed = false

    func update(playlist: Data, segments window: [MediaSegment]) {
        condition.lock()
        self.playlist = playlist
        segments = Dictionary(uniqueKeysWithValues: window.map { ($0.sequence, $0.data) })
        condition.broadcast()
        condition.unlock()
    }

    func waitForPlaylist(timeout: Double) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while playlist == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        return closed ? nil : playlist
    }

    func segment(_ sequence: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return segments[sequence]
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
