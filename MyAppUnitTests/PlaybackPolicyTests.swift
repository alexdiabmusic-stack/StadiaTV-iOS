import Foundation
import Testing
@testable import BannerTV

/// When the player gives up on a stream, and how it words what it knows about why.
@Suite("Playback give-up rules")
struct PlaybackPolicyTests {

    @Test("A converted transport stream gets longer to start than one the player opens itself")
    func startupLimits() {
        #expect(PlaybackPolicy.startupLimit(for: .direct, startupTimeout: 10) == 10)
        #expect(PlaybackPolicy.startupLimit(for: .convertedTransportStream, startupTimeout: 10) == 22,
                "the converter has to connect and cut its first segments")
        #expect(PlaybackPolicy.startupLimit(for: .convertedTransportStream, startupTimeout: 7) == 19, "Fast")
        for source in [PlaybackCandidate.Source.direct, .convertedTransportStream] {
            #expect(PlaybackPolicy.candidateDeadline(for: source, startupTimeout: 10)
                    > PlaybackPolicy.startupLimit(for: source, startupTimeout: 10),
                    "the deadline backs the watchdog up, so it comes after it")
        }
    }

    @Test("A channel always gets at least 30 s to show a picture, more when it has several ways to be tried")
    func firstFrameDeadline() {
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 7, sources: [.direct]) == 30, "Fast")
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 10, sources: [.direct]) == 30, "Balanced")
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 10, sources: []) == 30, "nothing to try")
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 10, sources: [.direct, .convertedTransportStream]) == 41,
                "12 s for HLS, 24 s for the converter, and a margin")
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 10, sources: [.convertedTransportStream, .direct]) == 41,
                "the same whichever comes first")
        #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: 7, sources: [.direct, .convertedTransportStream]) == 35, "Fast")
        // Always longer than every start-up limit put together, or the deadline would pre-empt the failover it backs up.
        for timeout in [7.0, 10, 25] {
            for sources in [[PlaybackCandidate.Source.direct], [.direct, .convertedTransportStream], [.convertedTransportStream, .direct]] {
                let limits = sources.reduce(0) { $0 + PlaybackPolicy.startupLimit(for: $1, startupTimeout: timeout) }
                #expect(PlaybackPolicy.firstFrameDeadline(startupTimeout: timeout, sources: sources) > limits)
            }
        }
    }

    @Test("Reconnects are counted over a window, so playing for a second between stalls doesn't reset the limit")
    func reconnectBudget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func reconnects(_ agesInSeconds: [Double]) -> [Date] { agesInSeconds.map { now.addingTimeInterval(-$0) } }

        #expect(!PlaybackPolicy.reconnectBudgetSpent(reconnects: [], now: now))
        #expect(!PlaybackPolicy.reconnectBudgetSpent(reconnects: reconnects([5, 30, 60, 90]), now: now), "four is allowed")
        #expect(PlaybackPolicy.reconnectBudgetSpent(reconnects: reconnects([5, 30, 60, 90, 120]), now: now), "the fifth in the window is not")
        #expect(!PlaybackPolicy.reconnectBudgetSpent(reconnects: reconnects([5, 30, 60, 90, 200]), now: now),
                "one older than the window no longer counts")
        #expect(!PlaybackPolicy.reconnectBudgetSpent(reconnects: reconnects([400, 500, 600, 700, 800, 900]), now: now),
                "a stream that recovered long ago starts afresh")
    }

    @Test("The player's own error log is worded for a person")
    func loggedError() {
        #expect(PlaybackPolicy.describeLoggedError(statusCode: 403, domain: "CoreMediaErrorDomain", comment: nil)
                == "Player log: HTTP 403.")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: 404, domain: "CoreMediaErrorDomain", comment: "Not Found")
                == "Player log: HTTP 404 (Not Found).")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: -12642, domain: "CoreMediaErrorDomain", comment: "No playlist")
                == "Player log: CoreMediaErrorDomain -12642 (No playlist).")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: -1001, domain: "", comment: nil) == "Player log: error -1001.")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: 0, domain: "NSURLErrorDomain", comment: "  segment timed out ")
                == "Player log: segment timed out.")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: 0, domain: "", comment: nil) == nil, "nothing to say")
        #expect(PlaybackPolicy.describeLoggedError(statusCode: 0, domain: "", comment: "   ") == nil)

        let long = PlaybackPolicy.describeLoggedError(statusCode: 500, domain: "", comment: String(repeating: "x", count: 400)) ?? ""
        #expect(long.count < 140, "a long comment is cut short")
    }

    @Test("What is known about a failure reads as one block, a part to a line, leaving out what is missing")
    func combine() {
        #expect(PlaybackPolicy.combine([nil, nil]) == nil)
        #expect(PlaybackPolicy.combine(["  ", "\n"]) == nil)
        #expect(PlaybackPolicy.combine(["Player log: HTTP 403.", nil, "  ", "The provider refused this stream."])
                == "Player log: HTTP 403.\nThe provider refused this stream.")
        #expect(PlaybackPolicy.combine(["As HLS: stalled", "Player log: HTTP 403."], separator: " ")
                == "As HLS: stalled Player log: HTTP 403.")
    }
}
