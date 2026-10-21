import Foundation
import Testing
@testable import StreamEngineCore

/// The single authority over recovery: when to reconnect, switch route, wait, or give up.
@Suite("Recovery referee")
struct RefereeTests {
    private let balanced = StreamEngineConfiguration.profile(.balanced)

    /// A health monitor whose connection last delivered programme at `lastDelivery`.
    private func health(lastDelivery: Double?) -> StreamHealthMonitor {
        var monitor = StreamHealthMonitor()
        monitor.connectionOpened(at: 0)
        if let lastDelivery {
            monitor.received(bytes: 1_000, at: lastDelivery)
            monitor.ingested(programmeSeconds: 1, at: lastDelivery)
        }
        return monitor
    }

    private func observation(_ now: Double, buffered: Double = 20, starved: Bool = false,
                             health: StreamHealthMonitor, silenceFloor: Double = 0) -> RecoveryReferee.Observation {
        RecoveryReferee.Observation(now: now, buffered: buffered, isStarved: starved, health: health, silenceFloor: silenceFloor)
    }

    /// A referee that has been playing on route 0 since t = 1.
    private func playingReferee(routes: Int = 1, singleAccount: Bool = false) -> RecoveryReferee {
        var referee = RecoveryReferee(configuration: balanced, routeCount: routes, isSingleConnectionAccount: singleAccount)
        _ = referee.start(at: 0)
        referee.programmeArrived(at: 1)
        return referee
    }

    private func connects(_ actions: [RecoveryReferee.Action]) -> Bool {
        actions.contains { if case .connect = $0 { true } else { false } }
    }

    /// Seconds until the referee connects again after `actions`; nil when it gave up.
    private func retryDelay(_ referee: RecoveryReferee, after actions: [RecoveryReferee.Action], at now: Double) -> Double? {
        if connects(actions) { return 0 }
        if case .waiting(_, let until) = referee.phase { return until - now }
        return nil
    }

    @Test("A cut is answered with an immediate reconnect")
    func immediateReconnect() {
        var referee = playingReferee()
        let actions = referee.connectionEnded(.endOfStream, at: 100, openedAt: 0, deliveredProgramme: true, drought: 0.25)
        #expect(actions == [.connect(route: 0)])
        #expect(referee.reconnects == 1)
        #expect(referee.phase == .connecting(route: 0, since: 100))
        #expect(referee.notice == nil)
    }

    @Test("Repeated failures back off 0, 0.5, 1, 2, 3, 4 and 5 s")
    func backoff() {
        var referee = playingReferee()
        var now = 20.0
        var delays: [Double] = []
        for _ in 0..<8 {
            let actions = referee.connectionEnded(.network, at: now, openedAt: now - 0.5, deliveredProgramme: false, drought: now - 1)
            guard let delay = retryDelay(referee, after: actions, at: now) else {
                Issue.record("the referee gave up")
                return
            }
            delays.append(delay)
            now += delay
            if delay > 0 {
                let retry = referee.tick(observation(now, health: health(lastDelivery: 1)))
                #expect(retry == [.connect(route: 0)])
            }
            now += 0.5
        }
        #expect(delays == [0, 0.5, 1, 2, 3, 4, 5, 5])
    }

    @Test("After a minute without programme, retries step out to 15, 30 and 60 s and the viewer is told")
    func steppedBackoff() {
        var referee = playingReferee()
        var now = 100.0
        var delays: [Double] = []
        for attempt in 0..<4 {
            let actions = referee.connectionEnded(.server(503), at: now, openedAt: now - 1, deliveredProgramme: false, drought: now - 30)
            guard let delay = retryDelay(referee, after: actions, at: now) else {
                Issue.record("the referee gave up")
                return
            }
            delays.append(delay)
            if attempt == 0 {
                _ = referee.tick(observation(now + 5, buffered: 0, starved: true, health: health(lastDelivery: 30)))
                #expect(referee.notice == .retrying(inSeconds: 10))
            }
            now += delay
            let retry = referee.tick(observation(now, buffered: 0, health: health(lastDelivery: 30)))
            #expect(retry == [.connect(route: 0)])
            #expect(referee.notice == nil)
            now += 1
        }
        #expect(delays == [15, 30, 60, 60])
    }

    @Test("Two routes failing instantly never add up to more than 15 connections a minute")
    func noReconnectStorm() {
        var referee = playingReferee(routes: 2)
        var now = 10.0
        var actions = referee.connectionEnded(.network, at: now, openedAt: 1, deliveredProgramme: true, drought: 0)
        var connections: [Double] = []
        var routesUsed: Set<Int> = []
        var gaveUp = false
        while now < 600 {
            if let action = actions.first(where: { if case .connect = $0 { true } else { false } }), case .connect(let route) = action {
                connections.append(now)
                routesUsed.insert(route)
                // Every attempt is refused at once.
                now += 0.125
                actions = referee.connectionEnded(.server(502), at: now, openedAt: now - 0.125, deliveredProgramme: false, drought: now - 10)
            } else {
                if actions.contains(where: { if case .fail = $0 { true } else { false } }) { gaveUp = true }
                now += 0.25
                actions = referee.tick(observation(now, buffered: 0, health: health(lastDelivery: 10)))
            }
        }
        #expect(!gaveUp)
        #expect(routesUsed == [0, 1])
        let busiestMinute = connections.map { start in connections.filter { $0 >= start && $0 < start + 60 }.count }.max() ?? 0
        #expect(busiestMinute <= 15)
        // Once the provider has been silent for a minute, probes step out to one a minute, on either route.
        let late = connections.filter { $0 > 300 }
        let gaps = zip(late.dropFirst(), late).map { $0 - $1 }
        #expect(late.count >= 3)
        #expect(gaps.allSatisfy { $0 >= 59 }, "gaps \(gaps)")
    }

    @Test("However many routes are refused at once, connections are rationed to 15 a minute")
    func rationing() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 20, isSingleConnectionAccount: false)
        var actions = referee.start(at: 0)
        var now = 0.0
        var connections: [Double] = []
        while now < 70, connections.count < 20 {
            if connects(actions) {
                connections.append(now)
                now += 0.125
                actions = referee.connectionEnded(.accountRejected(403), at: now, openedAt: now - 0.125, deliveredProgramme: false, drought: nil)
            } else {
                now += 0.25
                actions = referee.tick(observation(now, health: StreamHealthMonitor()))
            }
        }
        #expect(connections.filter { $0 < 60 }.count == 15)
        let busiestMinute = connections.map { start in connections.filter { $0 >= start && $0 < start + 60 }.count }.max() ?? 0
        #expect(busiestMinute <= 15)
    }

    @Test("A silent connection is replaced sooner when the reserve is low", arguments: [
        (20.0, 0.0, 12.0), (14.0, 0.0, 8.0), (5.0, 0.0, 4.0), (20.0, 14.0, 14.0)
    ])
    func stallTimeout(buffered: Double, silenceFloor: Double, expected: Double) {
        var referee = playingReferee()
        let monitor = health(lastDelivery: 10)
        let before = referee.tick(observation(10 + expected - 0.25, buffered: buffered, health: monitor, silenceFloor: silenceFloor))
        #expect(before.isEmpty)
        let after = referee.tick(observation(10 + expected, buffered: buffered, health: monitor, silenceFloor: silenceFloor))
        #expect(after == [.disconnect, .connect(route: 0)])
    }

    @Test("At start-up a dead route is abandoned after 6 s when there is a backup, 10 s when there isn't")
    func startupTimeouts() {
        var monitor = StreamHealthMonitor()
        monitor.connectionOpened(at: 0)

        var twoRoutes = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: false)
        #expect(twoRoutes.start(at: 0) == [.connect(route: 0)])
        let early = twoRoutes.tick(observation(5.75, health: monitor))
        #expect(early.isEmpty)
        let switched = twoRoutes.tick(observation(6, health: monitor))
        #expect(switched == [.disconnect, .connect(route: 1)])
        #expect(twoRoutes.routeSwitches == 1)

        var oneRoute = RecoveryReferee(configuration: balanced, routeCount: 1, isSingleConnectionAccount: false)
        _ = oneRoute.start(at: 0)
        let patient = oneRoute.tick(observation(9.75, health: monitor))
        #expect(patient.isEmpty)
        let retried = oneRoute.tick(observation(10, health: monitor))
        #expect(retried == [.disconnect, .connect(route: 0)])
    }

    @Test("A source that never plays fails after two attempts per route and the start-up timeout")
    func startupFailure() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: false)
        _ = referee.start(at: 0)
        var now = 0.0
        var outcome: [RecoveryReferee.Action] = []
        var attempts = 0
        while attempts < 10 {
            attempts += 1
            now += 0.25
            outcome = referee.connectionEnded(.network, at: now, openedAt: now - 0.25, deliveredProgramme: false, drought: nil)
            if outcome.contains(where: { if case .fail = $0 { true } else { false } }) { break }
            if let delay = retryDelay(referee, after: outcome, at: now), delay > 0 {
                now += delay
                _ = referee.tick(observation(now, health: StreamHealthMonitor()))
            }
        }
        #expect(outcome == [.fail(.startupFailed)])
        #expect(attempts == 7)
        #expect(now >= balanced.startupTimeout)
        #expect(StreamEngineFailure.startupFailed.allowsDirectPlayback)
    }

    @Test("A route refused at start-up falls through to the other before the account is blamed")
    func refusedRouteFallsThrough() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: false)
        _ = referee.start(at: 0)
        let fallThrough = referee.connectionEnded(.accountRejected(403), at: 0.25, openedAt: 0, deliveredProgramme: false, drought: nil)
        #expect(fallThrough == [.connect(route: 1)])
        // Refused there too: one patient retry, then the account is reported.
        let wait = referee.connectionEnded(.accountRejected(403), at: 0.5, openedAt: 0.25, deliveredProgramme: false, drought: nil)
        #expect(wait.isEmpty)
        #expect(referee.phase == .waiting(route: 1, until: 2.5))
        let retry = referee.tick(observation(2.5, health: StreamHealthMonitor()))
        #expect(retry == [.connect(route: 1)])
        let verdict = referee.connectionEnded(.accountRejected(403), at: 2.75, openedAt: 2.5, deliveredProgramme: false, drought: nil)
        #expect(verdict == [.fail(.accountRejected(403))])
        #expect(!StreamEngineFailure.accountRejected(403).allowsDirectPlayback)
    }

    @Test("Refused after playing, the engine yields the account to the other device", arguments: [true, false])
    func accountInUse(singleAccount: Bool) {
        var referee = playingReferee(singleAccount: singleAccount)
        var now = 50.0
        var outcome: [RecoveryReferee.Action] = []
        var refusals = 0
        while refusals < 5 {
            refusals += 1
            outcome = referee.connectionEnded(.accountRejected(403), at: now, openedAt: now - 0.25, deliveredProgramme: false, drought: 5)
            if outcome == [.fail(.accountInUse)] { break }
            now += 2
            let retry = referee.tick(observation(now, health: health(lastDelivery: 45)))
            #expect(retry == [.connect(route: 0)])
            now += 0.25
        }
        #expect(outcome == [.fail(.accountInUse)])
        #expect(refusals == (singleAccount ? 2 : 3))
    }

    @Test("Cut seconds into every connection, a one-stream account is in use elsewhere", arguments: [true, false])
    func quickDrops(singleAccount: Bool) {
        var referee = playingReferee(singleAccount: singleAccount)
        var now = 100.0
        var outcome: [RecoveryReferee.Action] = []
        for _ in 0..<3 {
            referee.programmeArrived(at: now + 0.5)
            outcome = referee.connectionEnded(.endOfStream, at: now + 5, openedAt: now, deliveredProgramme: true, drought: 0.5)
            now += 5
            if let delay = retryDelay(referee, after: outcome, at: now), delay > 0 {
                now += delay
                _ = referee.tick(observation(now, health: health(lastDelivery: now - 1)))
            }
        }
        #expect((outcome == [.fail(.accountInUse)]) == singleAccount)
    }

    @Test("Starved with the provider silent, the source is reported after the profile's grace period")
    func starvation() {
        var referee = playingReferee()
        _ = referee.connectionEnded(.network, at: 100, openedAt: 1, deliveredProgramme: true, drought: 1)
        let monitor = health(lastDelivery: 99)
        var failedAt: Double?
        var now = 100.0
        while now < 140, failedAt == nil {
            now += 0.25
            let actions = referee.tick(observation(now, buffered: 0, starved: true, health: monitor))
            if actions.contains(.fail(.sourceUnavailable)) {
                failedAt = now
            } else {
                #expect(referee.notice == .waitingForProvider)
            }
            if connects(actions) {
                // Every reconnect is refused at once.
                _ = referee.connectionEnded(.server(503), at: now, openedAt: now, deliveredProgramme: false, drought: now - 99)
            }
        }
        #expect(failedAt == 125.25)
        #expect(!StreamEngineFailure.sourceUnavailable.allowsDirectPlayback)
    }

    @Test("A stream missing on every route is reported as gone")
    func notFound() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: false)
        _ = referee.start(at: 0)
        let other = referee.connectionEnded(.notFound(404), at: 0.25, openedAt: 0, deliveredProgramme: false, drought: nil)
        #expect(other == [.connect(route: 1)])
        let gone = referee.connectionEnded(.notFound(404), at: 0.5, openedAt: 0.25, deliveredProgramme: false, drought: nil)
        #expect(gone == [.fail(.notFound)])
    }

    @Test("Once something has played, a 404 is retried; only a frozen picture turns it into a verdict")
    func notFoundAfterPlaying() {
        var referee = playingReferee()
        var actions = referee.connectionEnded(.notFound(404), at: 50, openedAt: 40, deliveredProgramme: true, drought: 1)
        #expect(actions == [.connect(route: 0)])
        var verdict: [RecoveryReferee.Action] = []
        var now = 50.0
        while now < 90, verdict.isEmpty {
            // Every connection is answered with another 404.
            var answered = 0
            while connects(actions), answered < 5 {
                answered += 1
                actions = referee.connectionEnded(.notFound(404), at: now, openedAt: now, deliveredProgramme: false, drought: now - 49)
            }
            #expect(!actions.contains { if case .fail = $0 { true } else { false } })
            now += 0.25
            actions = referee.tick(observation(now, buffered: 0, starved: true, health: health(lastDelivery: 49)))
            verdict = actions.filter { if case .fail = $0 { true } else { false } }
        }
        #expect(verdict == [.fail(.notFound)])
        #expect(now == 75.25)
    }

    @Test("A route that never played isn't retried while the working route rides out an outage")
    func deadRouteStaysDead() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: true)
        _ = referee.start(at: 0)
        // The panel doesn't offer .ts to this account; its HLS output plays.
        let fallThrough = referee.connectionEnded(.accountRejected(403), at: 0.25, openedAt: 0, deliveredProgramme: false, drought: nil)
        #expect(fallThrough == [.connect(route: 1)])
        referee.programmeArrived(at: 1)

        // Then the HLS output fails for two minutes, with 503s and 404s.
        var now = 30.0
        var actions = referee.connectionEnded(.server(503), at: now, openedAt: 1, deliveredProgramme: true, drought: 2)
        var connected: [Int] = []
        var gaveUp = false
        while now < 150 {
            if let action = actions.first(where: { if case .connect = $0 { true } else { false } }), case .connect(let route) = action {
                connected.append(route)
                now += 0.125
                let kind: RecoveryReferee.FailureKind = connected.count.isMultiple(of: 2) ? .notFound(404) : .server(503)
                actions = referee.connectionEnded(kind, at: now, openedAt: now - 0.125, deliveredProgramme: false, drought: now - 28)
            } else {
                if actions.contains(where: { if case .fail = $0 { true } else { false } }) { gaveUp = true }
                now += 0.25
                actions = referee.tick(observation(now, buffered: 10, health: health(lastDelivery: 28)))
            }
        }
        #expect(!gaveUp)
        #expect(connected.count >= 10)
        #expect(Set(connected) == [1])
    }

    @Test("Content no route can carry goes to AVPlayer; an error page mid-stream is just retried")
    func unsupportedContent() {
        var referee = RecoveryReferee(configuration: balanced, routeCount: 2, isSingleConnectionAccount: false)
        _ = referee.start(at: 0)
        let other = referee.connectionEnded(.unsupportedContent("fragmented MP4"), at: 0.25, openedAt: 0, deliveredProgramme: false, drought: nil)
        #expect(other == [.connect(route: 1)])
        let handOver = referee.connectionEnded(.unsupportedContent("adaptive bitrate ladder"), at: 0.5, openedAt: 0.25,
                                               deliveredProgramme: false, drought: nil)
        #expect(handOver == [.fail(.unsupported("adaptive bitrate ladder"))])
        #expect(StreamEngineFailure.unsupported("x").allowsDirectPlayback)

        var playing = playingReferee(routes: 2)
        let retry = playing.connectionEnded(.unsupportedContent("not an MPEG transport stream"), at: 50, openedAt: 40,
                                            deliveredProgramme: true, drought: 1)
        #expect(retry == [.connect(route: 0)])
    }

    @Test("Sustained delivery forgives earlier failures")
    func forgiveness() {
        var referee = playingReferee()
        var now = 10.0
        for _ in 0..<4 {
            let actions = referee.connectionEnded(.network, at: now, openedAt: now - 0.5, deliveredProgramme: false, drought: 0.5)
            if let delay = retryDelay(referee, after: actions, at: now) { now += delay }
            _ = referee.tick(observation(now, health: health(lastDelivery: now)))
            referee.programmeArrived(at: now + 0.25)
            now += 0.5
        }
        // Ten seconds of programme on the current connection: the next cut is answered at once again.
        let since = now
        while now < since + 11 {
            now += 0.25
            _ = referee.tick(observation(now, health: health(lastDelivery: now)))
        }
        let actions = referee.connectionEnded(.endOfStream, at: now, openedAt: since, deliveredProgramme: true, drought: 0.25)
        #expect(actions == [.connect(route: 0)])
    }

    @Test("Only real trouble reaches the screen")
    func notices() {
        #expect(StreamEngineNotice.slowLine.displayText == nil)
        #expect(StreamEngineNotice.waitingForProvider.displayText == "Waiting for the provider…")
        #expect(StreamEngineNotice.retrying(inSeconds: 30).displayText == "Provider not responding · retrying in 30 s")
        var referee = playingReferee()
        referee.noteSlowLine(true)
        #expect(referee.notice == .slowLine)
        referee.noteSlowLine(false)
        #expect(referee.notice == nil)
        #expect(!StreamEngineFailure.accountInUse.allowsDirectPlayback)
        #expect(!StreamEngineFailure.notFound.allowsDirectPlayback)
    }
}

@Suite("Pace, health and configuration")
struct PaceAndHealthTests {
    private let balanced = StreamEngineConfiguration.profile(.balanced)

    @Test("The pace target follows the reserve and the line")
    func paceTargets() {
        let cases: [(buffered: Double, ratio: Double?, outage: Bool, starved: Bool, rate: Double, reason: PlaybackPaceController.Reason)] = [
            (5, nil, false, false, 0.98, .building),
            (12, nil, false, false, 0.992, .trickling),
            (30, nil, false, false, 1.0, .normal),
            (50, nil, false, false, 1.01, .shedding),
            (5, nil, false, true, 1.0, .normal),
            (12, nil, true, false, 0.93, .outage),
            (25, nil, true, false, 1.0, .normal),
            (12, 0.90, false, false, 0.93, .slowLine),
            (12, 0.96, false, false, 0.945, .slowLine)
        ]
        for item in cases {
            let (rate, reason) = PlaybackPaceController.target(buffered: item.buffered, deliveryRatio: item.ratio, isOutage: item.outage,
                                                               isStarved: item.starved, configuration: balanced)
            #expect(abs(rate - item.rate) < 0.000_1, "buffered \(item.buffered)")
            #expect(reason == item.reason, "buffered \(item.buffered)")
        }
    }

    @Test("Rate changes are gentle and stop at the target")
    func paceSlew() {
        var pace = PlaybackPaceController()
        var rates: [Double?] = []
        for buffered in [5.0, 5, 5, 30, 30, 30] {
            rates.append(pace.update(buffered: buffered, deliveryRatio: 1, isOutage: false, isStarved: false,
                                     configuration: balanced, elapsed: 1))
        }
        #expect(rates == [0.99, 0.98, nil, 0.99, 1.0, nil])
        #expect(pace.reason == .normal)
    }

    @Test("Slow-line mode doesn't flap on delivery measured in bursts")
    func slowLineHysteresis() {
        var pace = PlaybackPaceController()
        var states: [Bool] = []
        for ratio in [0.96, 0.985, 0.999, 0.98, 0.96] {
            _ = pace.update(buffered: 10, deliveryRatio: ratio, isOutage: false, isStarved: false, configuration: balanced, elapsed: 1)
            states.append(pace.slowLineActive)
        }
        #expect(states == [true, true, false, false, true])
        _ = pace.update(buffered: 25, deliveryRatio: 0.96, isOutage: false, isStarved: false, configuration: balanced, elapsed: 1)
        #expect(!pace.slowLineActive)
    }

    @Test("Delivery is measured in programme seconds per second, whatever the bitrate")
    func deliveryRatio() {
        var health = StreamHealthMonitor()
        health.connectionOpened(at: 0)
        var now = 0.0
        while now < 60 {
            now += 0.25
            health.received(bytes: 25_000, at: now)
            health.ingested(programmeSeconds: 0.2, at: now)
            health.sample(at: now)
        }
        #expect(abs((health.slowRatio ?? 0) - 0.8) < 0.01)
        #expect(abs((health.fastRatio ?? 0) - 0.8) < 0.01)
        #expect(abs((health.bitrate ?? 0) - 800_000) < 1_000)
        #expect(abs((health.streamBitrate ?? 0) - 1_000_000) < 1)
        #expect(health.condition(at: now, buffered: 5, configuration: balanced) == .unsustainable)
        #expect(health.condition(at: now, buffered: 10, configuration: balanced) == .marginal)
    }

    @Test("Silence reads as a pause first, then as a stall that depends on the reserve")
    func silence() {
        var health = StreamHealthMonitor()
        health.connectionOpened(at: 0)
        #expect(health.condition(at: 1, buffered: 20, configuration: balanced) == .starting)
        health.received(bytes: 1_000, at: 1)
        health.ingested(programmeSeconds: 1, at: 1)
        #expect(health.condition(at: 2, buffered: 20, configuration: balanced) == .healthy)
        #expect(health.condition(at: 4, buffered: 20, configuration: balanced) == .deliveryPause)
        #expect(health.condition(at: 13, buffered: 20, configuration: balanced) == .stalled)
        #expect(health.condition(at: 5, buffered: 5, configuration: balanced) == .stalled)
        #expect(health.silence(at: 4) == 3)
        health.connectionClosed()
        #expect(health.silence(at: 4) == nil)
        #expect(health.programmeDrought(at: 4) == 3)
        #expect(StreamHealthMonitor.stallTimeout(buffered: 0, configuration: balanced) == 4)
        #expect(StreamHealthMonitor.stallTimeout(buffered: 14, configuration: balanced) == 8)
        #expect(StreamHealthMonitor.stallTimeout(buffered: 60, configuration: balanced) == 12)
    }

    @Test("The journal keeps the most recent decisions")
    func journal() {
        var journal = StreamEngineJournal(capacity: 3)
        for index in 0..<5 { journal.record(.recovery, "decision \(index)", buffered: Double(index)) }
        #expect(journal.entries.map(\.message) == ["decision 2", "decision 3", "decision 4"])
        #expect(journal.recent(2).map(\.id) == [3, 4])
    }

    @Test("Deeper profiles hold more and slow down further before freezing")
    func profiles() {
        let fast = StreamEngineConfiguration.profile(.fast)
        let maximum = StreamEngineConfiguration.profile(.maximum)
        #expect(fast.targetBuffer < balanced.targetBuffer && balanced.targetBuffer < maximum.targetBuffer)
        #expect(fast.slowLineFloor > balanced.slowLineFloor && balanced.slowLineFloor > maximum.slowLineFloor)
        for profile in [fast, balanced, maximum] {
            #expect(profile.lowBuffer < profile.targetBuffer && profile.targetBuffer < profile.highBuffer)
            #expect(profile.lead < profile.targetBuffer)
            #expect(profile.buildRate < profile.trickleRate && profile.trickleRate < 1 && profile.shedRate > 1)
            #expect(profile.slowLineFloor <= profile.buildRate)
            #expect(Double(profile.segmenter.playlistTargetDuration) >= profile.segmenter.maximumDuration)
        }
        let tile = maximum.forMultiviewTile()
        #expect(tile.profile == .fast)
        #expect(tile.maximumReserveBytes < fast.maximumReserveBytes)
    }
}
