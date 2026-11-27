package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.serializd.SerializdTone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LetterboxdScreenTest {
    // 2026-11-23 20:30 UTC. At -5 hours that is 3:30 PM on the 23rd.
    private val now = 1_795_465_800_000L
    private val minus5 = SerializdClock { -5 * 3_600_000L }

    private fun build(
        account: LetterboxdAccount? = LetterboxdAccount("tester", now - 3 * 86_400_000L, lastValidatedAtMs = now - 3_600_000L),
        connection: LetterboxdConnectionState = LetterboxdConnectionState.Connected,
        settings: LetterboxdSettings = LetterboxdSettings(),
        ops: List<LetterboxdOperation> = emptyList(),
        events: List<LetterboxdSyncEvent> = emptyList(),
        journal: Int = 182,
        watchlist: LetterboxdWatchlistSnapshot? = LetterboxdWatchlistSnapshot(List(191) { LetterboxdWatchlistFilm("f$it", it + 1, "Film $it") }, now),
        importStatus: String? = null,
        syncing: Boolean = false,
    ) = LetterboxdScreenText.build(1, account, connection, settings, ops, events, journal, watchlist, importStatus, syncing, now, minus5)

    private fun op(status: LetterboxdOperationStatus, profile: Int = 1) = LetterboxdOperation(
        id = "o$status$profile", profileId = profile, account = "tester", tmdbId = 603, title = "The Matrix", type = LetterboxdOperationType.CreateDiaryEntry,
        createdAtMs = now, status = status,
    )

    @Test fun aConnectedUpToDateAccountReadsLikeSerializds() {
        val s = build()
        assertEquals("tester", s.username); assertTrue(s.connected)
        assertEquals("Connected to Letterboxd", s.connectionLabel); assertEquals(SerializdTone.Good, s.connectionTone)
        assertEquals("Everything is up to date", s.syncHeadline); assertEquals("Last synced today at 2:30 PM", s.syncDetail)
        assertEquals("182 films in your journal", s.watchHistoryLine); assertEquals("191 films", s.watchlistLine)
        assertFalse(s.busy); assertFalse(s.needsReconnect)
    }

    @Test fun theLastSyncIsTheLatestSuccessfulContact() {
        val account = LetterboxdAccount("tester", 1L, lastValidatedAtMs = now - 5 * 86_400_000L, lastWatchlistAtMs = now - 60_000L)
        assertEquals("Last synced today at 3:29 PM", build(account = account).syncDetail)
        val event = LetterboxdSyncEvent("e1", now - 120_000L, 1, "tester", 603, "The Matrix", LetterboxdOperationType.CreateDiaryEntry, LetterboxdOperationStatus.Succeeded)
        assertEquals("Last synced today at 3:28 PM", build(account = account.copy(lastWatchlistAtMs = 0L, lastValidatedAtMs = 0L), events = listOf(event)).syncDetail)
        assertEquals("Nothing synced yet", build(account = LetterboxdAccount("tester", 1L)).syncDetail)
    }

    @Test fun waitingAndStoppedItemsAreSaidInPlainWords() {
        assertEquals("1 item waiting to send", build(ops = listOf(op(LetterboxdOperationStatus.Pending))).syncHeadline)
        assertEquals("2 items waiting to send", build(ops = listOf(op(LetterboxdOperationStatus.Pending), op(LetterboxdOperationStatus.NeedsReconciliation))).syncHeadline)
        val failed = build(ops = listOf(op(LetterboxdOperationStatus.Failed), op(LetterboxdOperationStatus.ActionRequired)))
        assertEquals("2 items need attention", failed.syncHeadline); assertEquals(SerializdTone.Warning, failed.syncTone); assertEquals(2, failed.failedCount)
        assertEquals("Everything is up to date", build(ops = listOf(op(LetterboxdOperationStatus.Pending, profile = 2))).syncHeadline, "another profile's work does not count")
    }

    @Test fun aRunningSyncOrImportIsBusy() {
        assertTrue(build(syncing = true).busy); assertEquals("Syncing…", build(syncing = true).syncHeadline)
        val importing = build(importStatus = "Reading diary page 2")
        assertEquals("Reading diary page 2", importing.syncHeadline); assertTrue(importing.busy)
    }

    @Test fun aConnectionProblemTellsTheMemberWhatToDo() {
        val expired = build(connection = LetterboxdConnectionState.SessionExpired)
        assertTrue(expired.needsReconnect); assertEquals("Sign in again", expired.connectionLabel); assertEquals(SerializdTone.Problem, expired.syncTone)
        assertTrue(build(connection = LetterboxdConnectionState.ReconnectionRequired).needsReconnect)
        val down = build(connection = LetterboxdConnectionState.TemporarilyUnavailable)
        assertFalse(down.needsReconnect); assertEquals(SerializdTone.Warning, down.syncTone)
    }

    @Test fun aDisconnectedProfileHasNoUsername() {
        val s = build(account = null, connection = LetterboxdConnectionState.Disconnected)
        assertNull(s.username); assertFalse(s.connected); assertEquals("Not connected", s.connectionLabel)
    }

    @Test fun theMainSwitchesMirrorTheStoredPreferencesAndTheAdvancedOnesStayUntouched() {
        val prefs = LetterboxdSettings(autoLogMovies = false, syncRatings = false, watchlistToLibrary = false, logRewatches = false, syncFavorites = true, showPostWatchPrompt = false, completionThreshold = 0.98)
        val s = build(settings = prefs)
        assertFalse(s.logFilms); assertFalse(s.syncRatings); assertFalse(s.syncWatchlist)
        assertEquals(prefs, s.settings, "turning the main switches off does not reset the advanced choices")
        assertEquals("Not synced", build(settings = prefs, watchlist = null).watchlistLine)
        assertEquals("Not read yet", build(watchlist = null).watchlistLine)
    }

    @Test fun journalLinesCoverZeroOneAndMany() {
        assertEquals("Nothing logged yet", LetterboxdScreenText.journalLine(0)); assertEquals("1 film in your journal", LetterboxdScreenText.journalLine(1))
        assertEquals("1,204 films in your journal", LetterboxdScreenText.journalLine(1204)); assertEquals("1 film", LetterboxdScreenText.films(1))
    }

    @Test fun importSentencesAreShortAndHonest() {
        assertEquals("182 films imported successfully.", LetterboxdScreenText.importSentence(182, 0, false))
        assertEquals("1 film imported successfully. 3 couldn't be matched.", LetterboxdScreenText.importSentence(1, 3, false))
        assertEquals("Nothing new to import. 2 couldn't be matched.", LetterboxdScreenText.importSentence(0, 2, false))
        assertEquals("Nothing new to import. Everything is already here.", LetterboxdScreenText.importSentence(0, 0, false))
        assertEquals("Import stopped early. Run it again to continue.", LetterboxdScreenText.importSentence(40, 0, true))
        assertEquals("Reconnect Letterboxd first", LetterboxdScreenText.importSentence(0, 0, true, "Reconnect Letterboxd first"))
    }

    private fun viewing(source: String = "playback", onDiary: Boolean = false, localOnly: Boolean = false, published: Boolean = false) =
        LetterboxdViewing(id = "v1", profileId = 1, tmdbId = 603, title = "The Matrix", completedAtMs = now, localDate = "2026-11-23", source = source, onDiary = onDiary, localOnly = localOnly, reviewPublished = published)

    @Test fun eachViewingSaysHowItStandsOnLetterboxd() {
        fun status(v: LetterboxdViewing, ops: List<LetterboxdOperation> = emptyList(), account: Boolean = true) = LetterboxdLabels.viewingStatus(v, ops, account)
        assertEquals("Imported from Letterboxd", status(viewing(source = "import")).label)
        assertEquals("On Letterboxd", status(viewing(onDiary = true)).label)
        assertEquals("On Letterboxd with review", status(viewing(onDiary = true, published = true)).label)
        assertEquals("Kept here: already logged that day", status(viewing(localOnly = true)).label)
        assertEquals("Not sent to Letterboxd", status(viewing()).label); assertTrue(status(viewing()).canLog)
        assertEquals("Letterboxd not connected", status(viewing(), account = false).label); assertFalse(status(viewing(), account = false).canLog)
        fun withOp(s: LetterboxdOperationStatus) = listOf(op(s).copy(viewingId = "v1"))
        assertEquals("Waiting to send", status(viewing(), withOp(LetterboxdOperationStatus.RetryScheduled)).label)
        assertEquals("Could not send", status(viewing(), withOp(LetterboxdOperationStatus.Failed)).label)
        assertEquals(SerializdTone.Problem, status(viewing(), withOp(LetterboxdOperationStatus.Failed)).tone)
        assertEquals("Confirming on your diary", status(viewing(), withOp(LetterboxdOperationStatus.NeedsReconciliation)).label)
    }

    @Test fun labelsReadTheSameAsTheyAlwaysDid() {
        assertEquals("Diary entry", LetterboxdLabels.type(LetterboxdOperationType.CreateDiaryEntry)); assertEquals("Will retry", LetterboxdLabels.status(LetterboxdOperationStatus.RetryScheduled))
        assertEquals("", LetterboxdLabels.error(LetterboxdErrorCategory.None)); assertEquals("No connection", LetterboxdLabels.error(LetterboxdErrorCategory.Offline))
        assertTrue(LetterboxdLabels.needsAttention(LetterboxdOperationStatus.Failed)); assertFalse(LetterboxdLabels.needsAttention(LetterboxdOperationStatus.Pending))
    }
}
