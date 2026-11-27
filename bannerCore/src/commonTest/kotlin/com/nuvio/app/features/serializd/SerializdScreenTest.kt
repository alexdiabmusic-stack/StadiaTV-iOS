package com.nuvio.app.features.serializd

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SerializdScreenTest {
    // 2026-11-23 20:30 UTC. At -5 hours that is 3:30 PM on the 23rd.
    private val now = 1_795_465_800_000L
    private val minus5 = SerializdClock { -5 * 3_600_000L }
    private val utc = SerializdClock { 0L }

    private fun build(
        account: SerializdAccount? = SerializdAccount("alex", now - 3 * 86_400_000L, lastValidatedAtMs = now - 3_600_000L),
        connection: SerializdConnectionState = SerializdConnectionState.Connected,
        settings: SerializdSettings = SerializdSettings(),
        ops: List<SerializdOperation> = emptyList(),
        events: List<SerializdSyncEvent> = emptyList(),
        tracked: Int = 6_506,
        watchlist: SerializdWatchlistSnapshot? = SerializdWatchlistSnapshot(List(63) { SerializdWatchlistEntry(it + 1, "Show $it", null, emptyList(), emptyList()) }, now),
        importStatus: String? = null,
        syncing: Boolean = false,
    ) = SerializdScreenText.build(1, account, connection, settings, ops, events, tracked, watchlist, importStatus, syncing, now, minus5)

    private fun op(status: SerializdOperationStatus) = SerializdOperation(
        id = "o${status.name}", profileId = 1, account = "alex", type = SerializdOperationType.MarkEpisodeWatched, showTmdbId = 1, title = "Show",
        dedupeKey = "k${status.name}", createdAtMs = now, status = status,
    )

    @Test fun timesAreWordedFromTheDevicesOwnClock() {
        assertEquals("today at 3:30 PM", SerializdScreenText.describeTime(now, now, minus5))
        assertEquals("today at 8:30 PM", SerializdScreenText.describeTime(now, now, utc))
        assertEquals("yesterday at 9:55 AM", SerializdScreenText.describeTime(now - 30 * 3_600_000L + 25 * 60_000L, now, minus5))
        assertEquals("Nov 20 at 3:30 PM", SerializdScreenText.describeTime(now - 3 * 86_400_000L, now, minus5))
        assertEquals("Dec 31, 2025 at 12:00 AM", SerializdScreenText.describeTime(1_767_139_200_000L, now, utc))
        // Midnight and noon read as 12, not 0.
        assertEquals("today at 12:15 PM", SerializdScreenText.describeTime(now - 8 * 3_600_000L - 15 * 60_000L, now, utc))
        assertEquals("today at 12:00 AM", SerializdScreenText.describeTime(now - 20 * 3_600_000L - 30 * 60_000L, now, utc))
    }

    @Test fun numbersAreGroupedByThousands() {
        assertEquals("6,506", SerializdScreenText.grouped(6_506)); assertEquals("63", SerializdScreenText.grouped(63))
        assertEquals("1,234,567", SerializdScreenText.grouped(1_234_567)); assertEquals("0", SerializdScreenText.grouped(0))
    }

    @Test fun aConnectedUpToDateAccountReadsAsUpToDate() {
        val s = build()
        assertEquals("alex", s.username); assertTrue(s.connected)
        assertEquals("Connected to Serializd", s.connectionLabel); assertEquals(SerializdTone.Good, s.connectionTone)
        assertEquals("Everything is up to date", s.syncHeadline); assertEquals("Last synced today at 2:30 PM", s.syncDetail)
        assertEquals("6,506 episodes tracked", s.watchHistoryLine); assertEquals(6_506, s.trackedEpisodes); assertEquals("63 shows", s.watchlistLine)
        assertFalse(s.busy); assertFalse(s.needsReconnect)
    }

    @Test fun theLastSyncIsTheLatestSuccessfulContactOfAnyKind() {
        val account = SerializdAccount("alex", 1L, lastValidatedAtMs = now - 5 * 86_400_000L, lastImportAtMs = now - 60_000L)
        assertEquals("Last synced today at 3:29 PM", build(account = account).syncDetail)
        assertEquals("Nothing synced yet", build(account = SerializdAccount("alex", 1L)).syncDetail)
    }

    @Test fun waitingAndStoppedItemsAreSaidInPlainWords() {
        assertEquals("1 item waiting to send", build(ops = listOf(op(SerializdOperationStatus.Pending))).syncHeadline)
        val waiting = build(ops = listOf(op(SerializdOperationStatus.Pending), op(SerializdOperationStatus.RetryScheduled)))
        assertEquals("2 items waiting to send", waiting.syncHeadline); assertEquals(2, waiting.pendingCount)
        val failed = build(ops = listOf(op(SerializdOperationStatus.FailedPermanent), op(SerializdOperationStatus.Pending)))
        assertEquals("1 item needs attention", failed.syncHeadline); assertEquals(SerializdTone.Warning, failed.syncTone); assertEquals(1, failed.failedCount)
    }

    @Test fun otherProfilesWorkDoesNotCount() {
        assertEquals("Everything is up to date", build(ops = listOf(op(SerializdOperationStatus.Pending).copy(profileId = 2))).syncHeadline)
    }

    @Test fun aRunningSyncOrImportIsShownAsBusy() {
        val syncing = build(syncing = true)
        assertEquals("Syncing…", syncing.syncHeadline); assertTrue(syncing.busy)
        val importing = build(importStatus = "Reading watched shows page 3")
        assertEquals("Reading watched shows page 3", importing.syncHeadline); assertTrue(importing.busy)
    }

    @Test fun aConnectionProblemTellsTheMemberWhatToDo() {
        val expired = build(connection = SerializdConnectionState.SessionExpired)
        assertTrue(expired.needsReconnect); assertEquals(SerializdTone.Problem, expired.connectionTone); assertEquals("Sign in again", expired.connectionLabel)
        assertTrue(build(connection = SerializdConnectionState.ReconnectionRequired).needsReconnect)
        val down = build(connection = SerializdConnectionState.TemporarilyUnavailable)
        assertFalse(down.needsReconnect); assertEquals(SerializdTone.Warning, down.syncTone); assertTrue(down.syncDetail!!.contains("try again later"))
    }

    @Test fun aDisconnectedProfileHasNoUsernameAndNoStatusLine() {
        val s = build(account = null, connection = SerializdConnectionState.Disconnected)
        assertNull(s.username); assertFalse(s.connected); assertEquals("Not connected", s.connectionLabel)
    }

    @Test fun theWatchlistSwitchIsOnOnlyWhenTheWatchlistIsBothReadAndAddedToMyList() {
        assertTrue(build().syncWatchlist)
        assertFalse(build(settings = SerializdSettings(watchlistToLibrary = false)).syncWatchlist)
        assertFalse(build(settings = SerializdSettings(importWatchlist = false)).syncWatchlist)
        assertEquals("Not synced", build(settings = SerializdSettings(importWatchlist = false), watchlist = null).watchlistLine)
        assertEquals("Not read yet", build(watchlist = null).watchlistLine)
    }

    @Test fun theMainSwitchesMirrorTheStoredPreferencesAndTheAdvancedOnesStayUntouched() {
        val prefs = SerializdSettings(autoTrackEpisodes = false, createDiaryEntries = false, logRewatches = false, syncRatings = false, syncFavorites = true, completionThreshold = 0.95)
        val s = build(settings = prefs)
        assertFalse(s.trackEpisodes); assertFalse(s.syncRatings)
        assertEquals(prefs, s.settings, "turning tracking off does not reset the advanced choices")
    }

    @Test fun importSentencesAreShortAndHonest() {
        fun stats(added: Int, known: Int = 0, unmatched: Int = 0, partial: Boolean = false) = SerializdImportStats(1L, added, known, unmatched, partial = partial)
        assertEquals("181 episodes imported successfully.", SerializdScreenText.importSentence(stats(181, 6325)))
        assertEquals("1 episode imported successfully.", SerializdScreenText.importSentence(stats(1)))
        assertEquals("1,200 episodes imported successfully. 3 couldn't be matched.", SerializdScreenText.importSentence(stats(1200, unmatched = 3)))
        assertEquals("Nothing new to import. Everything is already here.", SerializdScreenText.importSentence(stats(0, 50)))
        assertEquals("Nothing new to import. 2 couldn't be matched.", SerializdScreenText.importSentence(stats(0, 50, 2)))
        assertEquals("Import stopped early. Run it again to continue.", SerializdScreenText.importSentence(stats(40, partial = true)))
    }

    @Test fun theMainScreenShowsTheLastImportSentenceWhenThereIsOne() {
        val account = SerializdAccount("alex", 1L, lastImportStats = SerializdImportStats(1L, 181, 6325, 0))
        val s = build(account = account)
        assertEquals("181 episodes imported successfully.", s.importLine); assertEquals(181, s.importStats!!.added)
        assertNull(build().importLine)
    }

    @Test fun trackedLinesCoverZeroOneAndMany() {
        assertEquals("Nothing tracked yet", SerializdScreenText.trackedLine(0)); assertEquals("1 episode tracked", SerializdScreenText.trackedLine(1))
        assertEquals("1 show", SerializdScreenText.shows(1)); assertEquals("2 shows", SerializdScreenText.shows(2))
    }
}
