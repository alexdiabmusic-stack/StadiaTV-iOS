import Foundation
import CoreGraphics
import Testing
@testable import BannerTV

@Suite("Player upgrade regressions")
@MainActor
struct PlayerUpgradeTests {
    private func channel(_ id: String) throws -> Channel {
        Channel(id: id, name: id,
                streamURL: try #require(URL(string: "https://example.invalid/\(id).m3u8")),
                logoURL: nil, group: "Sports", playlistID: UUID(), playlistName: "Tests")
    }

    @Test func liveSeekClampsOffsetsToAvailableWindow() {
        #expect(PlaybackController.liveSeekTarget(rangeStart: 100, rangeEnd: 130, recommendedOffset: 5) == 125)
        #expect(PlaybackController.liveSeekTarget(rangeStart: 100, rangeEnd: 130, recommendedOffset: 60) == 100)
        #expect(PlaybackController.liveSeekTarget(rangeStart: 100, rangeEnd: 130, recommendedOffset: .nan) == 130)
        #expect(PlaybackController.liveSeekTarget(rangeStart: 100, rangeEnd: 130, recommendedOffset: -5) == 130)
        #expect(PlaybackController.liveSeekTarget(rangeStart: .nan, rangeEnd: 130, recommendedOffset: 5) == nil)
        #expect(PlaybackController.liveSeekTarget(rangeStart: 130, rangeEnd: 100, recommendedOffset: 5) == nil)
    }

    @Test func queuedAlertsRespectUpdatedChoices() {
        var preferences = UserPreferences()
        preferences.matchNotificationsEnabled = true
        preferences.scoreChangeAlertsEnabled = true
        preferences.broadcastAlertsEnabled = true
        let score = ["notificationType": "scoreChange", "origin": MatchNotificationPlanner.favoriteSyncOrigin]
        let broadcast = ["notificationType": "broadcastAvailable", "origin": MatchNotificationPlanner.favoriteSyncOrigin]
        #expect(preferences.allowsMatchNotification(score))
        preferences.sportsScoreDelaySeconds = 30
        #expect(!preferences.allowsMatchNotification(score))
        #expect(preferences.allowsMatchNotification(broadcast))
        preferences.broadcastAlertsEnabled = false
        #expect(!preferences.allowsMatchNotification(broadcast))
        preferences.sportsScoreDelaySeconds = 0
        preferences.matchNotificationsEnabled = false
        #expect(!preferences.allowsMatchNotification(score))
    }

    @Test func explicitRemindersStillHonorSpoilerProtection() {
        var preferences = UserPreferences()
        let reminder = ["notificationType": "gameTimeReminder", "origin": MatchNotificationPlanner.userOrigin]
        let closeGame = ["notificationType": "closeGame", "origin": MatchNotificationPlanner.userOrigin]
        #expect(preferences.allowsMatchNotification(reminder))
        preferences.spoilerFreeMode = true
        #expect(preferences.allowsMatchNotification(reminder))
        #expect(!preferences.allowsMatchNotification(closeGame))
    }

    @Test func latestRapidSelectionWins() throws {
        let first = try channel("first")
        let second = try channel("second")
        let third = try channel("third")
        let selection = StreamSelectionState(channel: first)
        let initialToken = selection.loadToken
        selection.reset(to: second, canonicalChannel: nil)
        selection.reset(to: third, canonicalChannel: nil)
        #expect(selection.activeChannel == third)
        #expect(selection.loadToken == initialToken + 2)
    }

    @Test func failureNeverAutomaticallySelectsAnotherRawBroadcast() throws {
        let original = try channel("english")
        let alternate = try channel("regional")
        let selection = StreamSelectionState(channel: original, candidates: [alternate])
        selection.handlePlaybackFailure()
        #expect(selection.activeChannel == original)
        if case .failed = selection.switchState {} else {
            Issue.record("Failure must await explicit broadcast selection")
        }
        selection.selectManual(streamID: alternate.id)
        #expect(selection.activeChannel == alternate)
    }

    @Test func retryKeepsSelectedIdentity() throws {
        let selected = try channel("selected")
        let selection = StreamSelectionState(channel: selected)
        selection.handlePlaybackFailure()
        let before = selection.loadToken
        selection.retryActiveStream()
        #expect(selection.activeChannel == selected)
        #expect(selection.loadToken == before + 1)
        #expect(selection.switchState == .idle)
    }

    @Test func errorsNeverExposeProviderCredentials() {
        let secret = "https://provider.example/username/password/live.m3u8?token=secret"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: secret])
        let message = PlaybackController.safeErrorMessage(error)
        #expect(message == "The stream timed out. Try again.")
        #expect(!message.contains("password"))
        #expect(!message.contains("token"))
    }

    @Test func oldPreferencesDecodeWithSafeDefaults() throws {
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        #expect(preferences.playerDoubleTapSeeks)
        #expect(!preferences.commercialBreakMode)
        #expect(preferences.preferredAudioLanguage.isEmpty)
        #expect(preferences.playerPanelTimeoutSeconds == 4)
    }

    @Test func preferencesRoundTrip() throws {
        var preferences = UserPreferences()
        preferences.preferredAudioLanguage = "fr"
        preferences.preferredSubtitleLanguage = "off"
        preferences.commercialBreakMode = true
        preferences.savedMultiviewSlots = [
            "1": SavedMultiviewLayout(channelIDs: ["playlist:a", "playlist:b"], layout: "twoHorizontal"),
            "4": SavedMultiviewLayout(channelIDs: ["playlist:c", "playlist:d", "playlist:e"], layout: "three")
        ]
        let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored == preferences)
    }
    @Test func delayedScoresWaitForReceiptTimeAndClearOnEventChange() throws {
        let league = try #require(League.all.first)
        let start = Date(timeIntervalSince1970: 1_000)
        let side = TeamSide(displayName: "Team", shortName: "Team", abbreviation: "TM", logoURL: nil,
                            score: "2", record: nil, isWinner: false)
        func match(_ id: String) -> Match {
            Match(id: id, league: league, date: start, name: "Fixture", shortName: "Fixture",
                  state: .live, statusDetail: "Live", home: side, away: side, broadcasts: [], venue: nil)
        }
        var buffer = PlayerSpoilerBuffer()
        buffer.receive(match("first"), at: start)
        #expect(buffer.snapshot(delay: 30, now: start.addingTimeInterval(29)) == nil)
        #expect(buffer.snapshot(delay: 30, now: start.addingTimeInterval(30))?.id == "first")
        buffer.receive(match("second"), at: start.addingTimeInterval(31))
        #expect(buffer.snapshot(delay: 30, now: start.addingTimeInterval(32)) == nil)
        buffer.receive(nil)
        #expect(buffer.snapshot(delay: 0, now: start.addingTimeInterval(100)) == nil)
    }

    @Test func invalidSavedDelayAndTimeoutAreClamped() throws {
        let data = Data(#"{"sportsScoreDelaySeconds":-30,"playerPanelTimeoutSeconds":0}"#.utf8)
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(preferences.sportsScoreDelaySeconds == 0)
        #expect(preferences.playerPanelTimeoutSeconds == 2)
    }
    @Test func duplicateProviderIDsKeepTheirPlaylistIdentity() throws {
        let first = try channel("same-provider-id")
        let second = try channel("same-provider-id")
        let selection = StreamSelectionState(channel: first, candidates: [second])
        #expect(selection.usableStreams.count == 2)
        selection.selectManual(streamID: second.id)
        #expect(selection.activeChannel.playlistID == first.playlistID) // Ambiguous legacy ID is rejected.
        selection.selectManual(streamID: StreamLinkerAdapters.streamID(second))
        #expect(selection.activeChannel.playlistID == second.playlistID)
    }

    @Test func olderBroadcastValidationCannotOverrideNewerSelection() async throws {
        let original = try channel("original")
        let older = try channel("older")
        let latest = try channel("latest")
        let selection = StreamSelectionState(channel: original, candidates: [older, latest])
        var pending: [String: CheckedContinuation<Bool, Never>] = [:]
        var completed: Set<String> = []
        defer {
            selection.cancelPendingValidation()
            for continuation in pending.values { continuation.resume(returning: false) }
        }
        selection.broadcastValidator = { candidate in
            let result = await withCheckedContinuation { pending[candidate.id] = $0 }
            completed.insert(candidate.id)
            return result
        }
        selection.selectManual(streamID: older.id)
        try await waitUntil { pending[older.id] != nil }
        selection.selectManual(streamID: latest.id)
        try await waitUntil { pending[latest.id] != nil }
        let latestContinuation = pending.removeValue(forKey: latest.id)
        let latestRequest = try #require(latestContinuation)
        latestRequest.resume(returning: true)
        try await waitUntil { selection.activeChannel.id == latest.id }
        let olderContinuation = pending.removeValue(forKey: older.id)
        let olderRequest = try #require(olderContinuation)
        olderRequest.resume(returning: true)
        try await waitUntil { completed.contains(older.id) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(selection.activeChannel == latest)
    }

    @Test func rejectedBroadcastRetryRevalidatesTheRequestedChannel() async throws {
        let original = try channel("original")
        let requested = try channel("requested")
        let selection = StreamSelectionState(channel: original, candidates: [requested])
        var attempts = 0
        selection.broadcastValidator = { candidate in
            #expect(candidate == requested)
            attempts += 1
            return attempts > 1
        }
        selection.selectManual(streamID: requested.id)
        try await waitUntil { selection.switchState == .failed("No confirmed stream found.") }
        #expect(selection.activeChannel == original)
        selection.retryActiveStream()
        try await waitUntil { selection.activeChannel == requested }
        #expect(attempts == 2)
    }


    @Test func multiviewBudgetAndLegacyAudioMigration() throws {
        let prefs = try JSONDecoder().decode(UserPreferences.self,
            from: Data(#"{"playerMaximumStreams":99,"savedMultiviewSlots":{"1":{"channelIDs":["a","b"],"layout":"twoHorizontal"}}}"#.utf8))
        #expect(prefs.playerMaximumStreams == 4)
        #expect(prefs.savedMultiviewSlots["1"]?.audioChannelID == nil)
        #expect(!prefs.scoreChangeAlertsEnabled)
        #expect(!prefs.broadcastAlertsEnabled)
        let saved = SavedMultiviewLayout(channelIDs: ["a", "b"], layout: "twoHorizontal", audioChannelID: "b")
        #expect(try JSONDecoder().decode(SavedMultiviewLayout.self, from: JSONEncoder().encode(saved)) == saved)
    }

    @Test func originalVideoUsesDisplayPixelsWithoutUpscaling() {
        let available = CGSize(width: 1000, height: 800)
        let original = OriginalVideoSize.size(mode: .original, video: CGSize(width: 640, height: 360), available: available, scale: 2)
        #expect(original == CGSize(width: 320, height: 180))
        let reduced = OriginalVideoSize.size(mode: .original, video: CGSize(width: 3840, height: 2160), available: available, scale: 2)
        #expect(abs(reduced.width - 1000) < 0.000001)
        #expect(abs(reduced.height - 562.5) < 0.000001)
        #expect(OriginalVideoSize.size(mode: .original, video: .zero, available: available, scale: 2) == available)
    }

    @Test func playerAlertsHaveStableDeduplicationAndSafeBroadcastText() {
        let match = NotificationCandidate(matchID: "event", leagueID: "league", date: Date(), state: .live,
            awayShortName: "Away", homeShortName: "Home", awayScore: "123", homeScore: "124",
            statusDetail: "Final score spoiler", closeMargin: 5)
        let broadcast = MatchNotificationPlanner.broadcastAlert(for: match)
        #expect(!broadcast.body.contains("123"))
        #expect(!broadcast.body.contains("spoiler"))
        #expect(broadcast == MatchNotificationPlanner.broadcastAlert(for: match))
        #expect(MatchNotificationPlanner.scoreChangeAlert(for: match).identifier.contains("123.124"))
        #expect(!MatchNotificationPlanner.liveAlert(for: match, origin: "favorite").body.contains("spoiler"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            try #require(clock.now < deadline, "Asynchronous selection did not reach its expected state")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

}
