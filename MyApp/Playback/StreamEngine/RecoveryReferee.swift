import Foundation

/// Why the engine gave up on a source. The controller decides what the viewer sees.
nonisolated enum StreamEngineFailure: Error, Equatable, Sendable {
    /// Not something the engine handles (VOD, fMP4/CMAF, encrypted or adaptive HLS, unknown
    /// container); AVPlayer should play the provider URL directly.
    case unsupported(String)
    /// No route produced a picture.
    case startupFailed
    /// The provider refused the account (expired, banned, or over its connection limit at start).
    case accountRejected(Int)
    /// Another device took this account's only connection. The engine stops competing for it.
    case accountInUse
    /// The stream doesn't exist at the provider any more.
    case notFound
    /// The provider stayed silent after the reserve ran out.
    case sourceUnavailable

    var message: String {
        switch self {
        case .unsupported: return "This stream format isn't supported."
        case .startupFailed: return "The stream didn't start. Try again or choose another broadcast."
        case .accountRejected: return "Access denied. Check your IPTV account."
        case .accountInUse: return "Your IPTV account is being used on another device. Retry to watch here."
        case .notFound: return "This channel is no longer available from your provider."
        case .sourceUnavailable: return "Lost connection to the stream."
        }
    }

    /// Whether letting AVPlayer fetch the provider URL itself is worth a try.
    var allowsDirectPlayback: Bool {
        switch self {
        case .unsupported, .startupFailed: return true
        case .accountRejected, .accountInUse, .notFound, .sourceUnavailable: return false
        }
    }
}

/// Status the player may show. Most recoveries happen inside the reserve and show nothing.
nonisolated enum StreamEngineNotice: Equatable, Sendable {
    /// The reserve ran out and the provider is silent; the engine keeps reconnecting.
    case waitingForProvider
    /// Prolonged outage: probing on the 15/30/60 s schedule.
    case retrying(inSeconds: Int)
    /// The line can't sustain the stream; playback is slowed to avoid freezing.
    case slowLine

    /// On-screen text; nil when the remedy itself is the whole story (a slightly slower picture).
    var displayText: String? {
        switch self {
        case .waitingForProvider: return "Waiting for the provider…"
        case .retrying(let seconds): return "Provider not responding · retrying in \(seconds) s"
        case .slowLine: return nil
        }
    }
}

/// The single authority over recovery.
///
/// Network code reports failures, the health monitor reports silence and throughput, the
/// reserve reports its depth, the player reports starvation; only this type decides what
/// happens next, and only one remedy is in flight at a time. Without one referee, a timeout,
/// a stall watchdog and a failover policy all react to the same three-second hiccup and turn
/// it into a reload. Each decision is described in `decisions` for the diagnostics journal.
nonisolated struct RecoveryReferee {
    enum FailureKind: Equatable, Sendable {
        case endOfStream
        case network
        case server(Int)
        case accountRejected(Int)
        case notFound(Int)
        case unsupportedContent(String)
        /// The engine closed a connection that went silent.
        case stalled
        /// Connected, but no programme ever arrived.
        case deadChannel

        var description: String {
            switch self {
            case .endOfStream: return "provider closed the connection"
            case .network: return "network error"
            case .server(let code): return "server error \(code)"
            case .accountRejected(let code): return "account rejected (\(code))"
            case .notFound(let code): return "stream not found (\(code))"
            case .unsupportedContent(let reason): return "unsupported content: \(reason)"
            case .stalled: return "connection went silent"
            case .deadChannel: return "no programme from the provider"
            }
        }
    }

    enum Action: Equatable, Sendable {
        case connect(route: Int)
        /// Close the current connection without reporting it again.
        case disconnect
        case fail(StreamEngineFailure)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case connecting(route: Int, since: Double)
        case streaming(route: Int, since: Double)
        case waiting(route: Int, until: Double)
        case finished
    }

    struct Observation {
        var now: Double
        /// Programme seconds held ahead of the playhead.
        var buffered: Double
        /// The viewer is looking at a frozen picture for lack of programme.
        var isStarved: Bool
        var health: StreamHealthMonitor
        /// Silence that is normal for this connection (HLS waits a target duration between segments).
        var silenceFloor: Double = 0
        /// Programme the provider dropped on this connection in the last `droppedProgrammeWindow`
        /// seconds, and in how many gaps.
        var droppedProgramme: Double = 0
        var droppedGaps = 0
    }

    /// A route that drops this much programme, or this many gaps of it, within the window gives way
    /// to a route that hasn't: panels' MPEG-TS output drops chunks of 4K streams that their HLS
    /// output carries whole.
    static let droppedProgrammeWindow: Double = 30
    static let droppedProgrammeLimit: Double = 1.5
    static let droppedGapLimit = 2

    let configuration: StreamEngineConfiguration
    let routeCount: Int
    /// The account allows a single stream (or its limit is unknown and already reached).
    let isSingleConnectionAccount: Bool

    private(set) var phase: Phase = .idle
    private(set) var notice: StreamEngineNotice?
    private(set) var reconnects = 0
    private(set) var routeSwitches = 0
    private var decisionLog: [String] = []

    private var everStreamed = false
    private var startedAt: Double = 0
    private var attempt = 0
    private var startupAttempts = 0
    private var routeFailures: [Int]
    private var accountRejections = 0
    private var quickDrops = 0
    private var steppedAttempts = 0
    private var connectionTimes: [Double] = []
    private var starvedSince: Double?
    private var triedRoutes: Set<Int> = []
    private var streamedRoutes: Set<Int> = []
    /// Routes that answered "not here" (404, a refusal, unplayable content) without ever having
    /// delivered programme: the panel doesn't offer that output to this account. They're skipped
    /// while another route is left, so an outage on the working route never sends the engine back
    /// to one that can't play and has it give up with the wrong verdict.
    private var deadRoutes: Set<Int> = []
    /// 404s per route since that route last delivered programme.
    private var notFoundCounts: [Int]
    /// Routes found dropping programme. They aren't switched to for that reason again.
    private var lossyRoutes: Set<Int> = []
    private var lastFailure: FailureKind?

    init(configuration: StreamEngineConfiguration, routeCount: Int, isSingleConnectionAccount: Bool) {
        self.configuration = configuration
        self.routeCount = max(1, routeCount)
        self.isSingleConnectionAccount = isSingleConnectionAccount
        self.routeFailures = Array(repeating: 0, count: max(1, routeCount))
        self.notFoundCounts = Array(repeating: 0, count: max(1, routeCount))
    }

    var currentRoute: Int {
        switch phase {
        case .connecting(let route, _), .streaming(let route, _), .waiting(let route, _): return route
        case .idle, .finished: return 0
        }
    }

    mutating func drainDecisions() -> [String] {
        defer { decisionLog.removeAll() }
        return decisionLog
    }

    // MARK: - Events

    mutating func start(at now: Double) -> [Action] {
        startedAt = now
        return [connect(route: 0, at: now, reason: "start")]
    }

    /// New programme reached the reserve.
    mutating func programmeArrived(at now: Double) {
        guard case .connecting(let route, _) = phase else { return }
        phase = .streaming(route: route, since: now)
        everStreamed = true
        streamedRoutes.insert(route)
        deadRoutes.remove(route)
        notFoundCounts[route] = 0
        if notice != .slowLine { notice = nil }
    }

    /// The current connection ended on its own (or the engine closed it after `disconnect`).
    mutating func connectionEnded(_ kind: FailureKind, at now: Double, openedAt: Double?,
                                  deliveredProgramme: Bool, drought: Double?) -> [Action] {
        guard phase != .finished else { return [] }
        let route = currentRoute
        let neverPlayedHere = !streamedRoutes.contains(route)
        lastFailure = kind
        decisionLog.append("Connection ended: \(kind.description)")

        switch kind {
        case .unsupportedContent(let reason):
            if neverPlayedHere { deadRoutes.insert(route) }
            if !everStreamed {
                if let next = nextRoute(after: route) {
                    return switchRoute(to: next, at: now, drought: drought, reason: "route can't be decoded")
                }
                return [finish(.unsupported(reason))]
            }
            // Mid-stream, an error page served in place of the stream is the provider misbehaving,
            // not a format change: retry like any other failure.
            routeFailures[route] += 1

        case .accountRejected(let code):
            // Panels refuse output formats an account isn't allowed (403 on .ts, say): a route that
            // never played is refused, not the account, while another route can still be tried.
            if neverPlayedHere {
                deadRoutes.insert(route)
                if let next = nextRoute(after: route) {
                    return switchRoute(to: next, at: now, drought: drought, reason: "route refused (\(code))")
                }
            }
            accountRejections += 1
            let limit = everStreamed ? (isSingleConnectionAccount ? 2 : 3) : 2
            if accountRejections >= limit {
                return [finish(everStreamed ? .accountInUse : .accountRejected(code))]
            }
            return schedule(route: route, delay: 2, at: now, reason: "account refused (\(code)); waiting before one retry")

        case .notFound:
            routeFailures[route] += 2
            notFoundCounts[route] += 1
            if neverPlayedHere { deadRoutes.insert(route) }
            // Before anything plays, 404 everywhere means the stream doesn't exist. Once it has
            // played, a 404 can be a panel restarting: retry, and let starvation give the verdict.
            if !everStreamed, notFoundCounts.allSatisfy({ $0 > 0 }) {
                return [finish(.notFound)]
            }
            if neverPlayedHere, let next = nextRoute(after: route) {
                return switchRoute(to: next, at: now, drought: drought, reason: "stream missing on this route")
            }

        case .endOfStream, .network, .server, .stalled, .deadChannel:
            let providerClosed = kind == .endOfStream || kind == .network
            if providerClosed, deliveredProgramme, let openedAt, (2...12).contains(now - openedAt) {
                quickDrops += 1
                // On a one-stream account, being cut a few seconds into every connection means
                // another device holds the line; fighting it would lock both out.
                if isSingleConnectionAccount, quickDrops >= 3 {
                    return [finish(.accountInUse)]
                }
            }
            routeFailures[route] += kind == .deadChannel ? 2 : 1
        }

        attempt += 1
        if !everStreamed {
            startupAttempts += 1
            // Two tries per route and the start-up timeout's worth of patience, so a network blip
            // at the moment of tuning in isn't taken for a stream that won't start.
            if startupAttempts >= 2 * routeCount, now - startedAt >= configuration.startupTimeout {
                return [finish(.startupFailed)]
            }
        }
        // A route that has played gets more patience before the backup is tried: a reconnect to it
        // comes with the provider's burst, while the backup (often HLS) can run behind it.
        let patience = streamedRoutes.contains(route) ? 3 : 2
        if let next = nextRoute(after: route), routeFailures[route] >= patience, routeFailures[next] <= routeFailures[route] {
            return switchRoute(to: next, at: now, drought: drought, reason: "route failing repeatedly")
        }
        let delay = retryDelay(at: now, drought: drought)
        return schedule(route: route, delay: delay, at: now, reason: "reconnecting")
    }

    // MARK: - Periodic evaluation

    mutating func tick(_ observation: Observation) -> [Action] {
        let now = observation.now
        var actions: [Action] = []

        switch phase {
        case .idle, .finished:
            return []
        case .waiting(let route, let until):
            if now >= until { actions.append(connect(route: route, at: now, reason: "retry")) }
        case .connecting(_, let since):
            // A backup route makes waiting out a dead first route at start-up pointless.
            let startupLimit = routeCount > 1 && triedRoutes.count < routeCount
                ? min(configuration.startupTimeout, 6) : configuration.startupTimeout
            let limit = everStreamed ? configuration.deadChannelTimeout : startupLimit
            if now - since >= limit {
                decisionLog.append("No programme \(Int(limit)) s after connecting")
                actions.append(.disconnect)
                actions += connectionEnded(.deadChannel, at: now, openedAt: since, deliveredProgramme: false,
                                           drought: observation.health.programmeDrought(at: now))
            }
        case .streaming(let route, let since):
            let health = observation.health
            let timeout = max(StreamHealthMonitor.stallTimeout(buffered: observation.buffered, configuration: configuration),
                              observation.silenceFloor)
            if let silence = health.silence(at: now), silence >= timeout {
                decisionLog.append(String(format: "Silent for %.1f s with %.1f s buffered: replacing the connection", silence, observation.buffered))
                actions.append(.disconnect)
                actions += connectionEnded(.stalled, at: now, openedAt: since, deliveredProgramme: true,
                                           drought: health.programmeDrought(at: now))
            } else {
                if now - since >= 10, (health.programmeDrought(at: now) ?? 0) < 2 {
                    // Sustained delivery: forgive earlier failures.
                    attempt = 0
                    steppedAttempts = 0
                    accountRejections = 0
                    routeFailures[route] = 0
                    if now - since >= 30 { quickDrops = 0 }
                }
                if observation.droppedProgramme >= Self.droppedProgrammeLimit || observation.droppedGaps >= Self.droppedGapLimit,
                   lossyRoutes.insert(route).inserted {
                    let gaps = observation.droppedGaps == 1 ? "1 gap" : "\(observation.droppedGaps) gaps"
                    decisionLog.append(String(format: "Provider dropped %.1f s of programme in ", observation.droppedProgramme)
                                       + "\(gaps) within \(Int(Self.droppedProgrammeWindow)) s on this route")
                    if let next = nextRoute(after: route), !lossyRoutes.contains(next) {
                        actions.append(.disconnect)
                        actions += switchRoute(to: next, at: now, drought: nil, reason: "provider dropping programme")
                    }
                }
            }
        }

        // Starvation is the only time the viewer sees a problem; give the source a bounded
        // chance, then report it so another broadcast can be tried.
        if observation.isStarved {
            let since = starvedSince ?? now
            starvedSince = since
            let drought = observation.health.programmeDrought(at: now) ?? (now - since)
            if case .waiting(_, let until) = phase, drought >= configuration.steppedBackoffAfter {
                notice = .retrying(inSeconds: max(1, Int((until - now).rounded(.up))))
            } else {
                notice = .waitingForProvider
            }
            if everStreamed, now - since >= configuration.starvedFailover, drought >= configuration.starvedFailover {
                if case .notFound = lastFailure {
                    actions.append(finish(.notFound))
                } else {
                    actions.append(finish(.sourceUnavailable))
                }
            }
        } else {
            starvedSince = nil
            if notice == .waitingForProvider { notice = nil }
            if case .retrying = notice { notice = nil }
        }
        return actions
    }

    /// Leaves the current connection for `route` before anything has played: the session knows that
    /// route carries this stream better. A route already found dead is left alone.
    mutating func prefer(route: Int, at now: Double, reason: String) -> [Action] {
        guard !everStreamed, route != currentRoute, route < routeCount, !deadRoutes.contains(route) else { return [] }
        switch phase {
        case .connecting, .streaming:
            return [.disconnect] + switchRoute(to: route, at: now, drought: nil, reason: reason)
        case .idle, .waiting, .finished:
            return []
        }
    }

    /// Records the pace decision's effect on the notice: a slowed line is worth telling the viewer about.
    mutating func noteSlowLine(_ active: Bool) {
        if active, notice == nil { notice = .slowLine }
        if !active, notice == .slowLine { notice = nil }
    }

    // MARK: - Helpers

    private mutating func connect(route: Int, at now: Double, reason: String) -> Action {
        if everStreamed, reason != "start" { reconnects += 1 }
        connectionTimes.append(now)
        connectionTimes.removeAll { now - $0 > 60 }
        triedRoutes.insert(route)
        phase = .connecting(route: route, since: now)
        decisionLog.append("Connecting (route \(route + 1)/\(routeCount)): \(reason)")
        return .connect(route: route)
    }

    /// Moves to another route. The first try of an untried route goes immediately; after that a
    /// switch waits like any retry (stepped once the provider has been silent for a minute), so
    /// two failing routes can never ping-pong into a storm.
    private mutating func switchRoute(to route: Int, at now: Double, drought: Double?, reason: String) -> [Action] {
        routeSwitches += 1
        decisionLog.append("Switching to route \(route + 1): \(reason)")
        let delay = triedRoutes.contains(route) ? retryDelay(at: now, drought: drought) : rationed(0, at: now)
        return schedule(route: route, delay: delay, at: now, reason: "route switch")
    }

    private mutating func schedule(route: Int, delay: Double, at now: Double, reason: String) -> [Action] {
        guard delay > 0 else { return [connect(route: route, at: now, reason: reason)] }
        phase = .waiting(route: route, until: now + delay)
        decisionLog.append(String(format: "Retrying in %.1f s: %@", delay, reason))
        return []
    }

    /// Pushes `delay` out until the per-minute connection budget allows another attempt.
    private func rationed(_ delay: Double, at now: Double) -> Double {
        let recent = connectionTimes.filter { now - $0 < 60 }
        guard recent.count >= configuration.maximumConnectionsPerMinute, let oldest = recent.first else { return delay }
        return max(delay, oldest + 60 - now)
    }

    private mutating func finish(_ failure: StreamEngineFailure) -> Action {
        phase = .finished
        decisionLog.append("Giving up: \(failure.message)")
        return .fail(failure)
    }

    /// The next route worth trying after `route`, skipping dead ones.
    private func nextRoute(after route: Int) -> Int? {
        guard routeCount > 1 else { return nil }
        return (1..<routeCount).map { (route + $0) % routeCount }.first { !deadRoutes.contains($0) }
    }

    /// Immediate first retry, short backoff while the reserve covers the gap, then the stepped
    /// 15/30/60 s schedule once the provider has been silent for a minute. Never more than
    /// `maximumConnectionsPerMinute` attempts in any minute.
    private mutating func retryDelay(at now: Double, drought: Double?) -> Double {
        var delay: Double
        if let drought, drought >= configuration.steppedBackoffAfter {
            let steps: [Double] = [15, 30, 60]
            delay = steps[min(steppedAttempts, steps.count - 1)]
            steppedAttempts += 1
        } else {
            let schedule: [Double] = [0, 0.5, 1, 2, 3, 4, 5]
            delay = schedule[min(max(attempt - 1, 0), schedule.count - 1)]
        }
        return rationed(delay, at: now)
    }
}
