package com.nuvio.app.features.smartdownloads

import com.nuvio.app.features.playback.InMemoryPlaybackStateStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val GB = 1024L * 1024L * 1024L
private fun id(s: Int, e: Int) = EpisodeId(s, e)
private fun cat(e: Int, aired: Boolean = true, bytes: Long = GB) = CatalogEpisode(id(1, e), aired, bytes)
private fun ref(e: Int, profile: Int = 1, title: String = "show") = OfflineRef(profile, title, id(1, e))

private fun entry(
    e: Int,
    origin: DownloadOrigin = DownloadOrigin.MANUAL,
    status: OfflineStatus = OfflineStatus.COMPLETED,
    size: Long = GB,
    profile: Int = 1,
    title: String = "show",
    pinned: Boolean = false,
    retained: Boolean = false,
    playing: Boolean = false,
    watched: Boolean = false,
    created: Long = e.toLong(),
) = OfflineEntry(profile, title, id(1, e), origin, status, size, pinned, retained, playing, watched, created)

private fun series(watched: Set<Int>, total: Int = 8, airedThrough: Int = total, profile: Int = 1, restricted: Boolean = false) =
    SeriesContext(profile, "show", (1..total).map { cat(it, aired = it <= airedThrough) }, watched.map { id(1, it) }.toSet(), restricted)

private val goodConditions = DeviceConditions(online = true, onWifi = true, freeStorageBytes = 50 * GB)
private val on = SmartDownloadSettings(nextEpisodeEnabled = true, upcomingEpisodes = 2, autoDelete = AutoDeletePolicy.ALL_WATCHED)

class NextEpisodePlannerTest {
    private fun plan(
        settings: SmartDownloadSettings = on,
        conditions: DeviceConditions = goodConditions,
        s: SeriesContext,
        entries: List<OfflineEntry>,
        history: SmartDownloadHistory = NoSmartDownloadHistory,
        now: Long = 0L,
    ) = NextEpisodePlanner.plan(settings, conditions, s, entries, history, now)

    @Test fun finishingEpisodeOneQueuesEpisodeThreeKeepsTwoAndRemovesOneOnlyAfterTheReplacementIsOnTheDevice() {
        val first = plan(s = series(watched = setOf(1)), entries = listOf(entry(1), entry(2)))
        assertEquals(listOf(id(1, 3)), first.enqueue.map { it.episode })
        assertEquals(DownloadOrigin.NEXT_EPISODE, first.enqueue.single().origin)
        assertTrue(first.remove.isEmpty(), "episode 1 stays until episode 3 is verified on the device")

        // Episode 3 is still transferring: nothing is deleted yet.
        val midway = plan(s = series(watched = setOf(1)), entries = listOf(entry(1), entry(2), entry(3, DownloadOrigin.NEXT_EPISODE, OfflineStatus.DOWNLOADING)))
        assertTrue(midway.enqueue.isEmpty()); assertTrue(midway.remove.isEmpty())

        // Episode 3 arrived: episode 1 goes, episode 2 remains.
        val done = plan(s = series(watched = setOf(1)), entries = listOf(entry(1), entry(2), entry(3, DownloadOrigin.NEXT_EPISODE)))
        assertTrue(done.enqueue.isEmpty()); assertEquals(listOf(ref(1)), done.remove)
    }

    @Test fun anAlreadyDownloadedNextEpisodeIsNotQueuedAgain() {
        val p = plan(settings = on.copy(upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(entry(1), entry(2)))
        assertTrue(p.enqueue.isEmpty())
        assertEquals(listOf(ref(1)), p.remove)
    }

    @Test fun supportsRetainingOneTwoOrThreeUpcomingEpisodes() {
        for (n in 1..3) {
            val p = plan(settings = on.copy(upcomingEpisodes = n), s = series(setOf(1)), entries = listOf(entry(1)))
            assertEquals((2..(n + 1)).map { id(1, it) }, p.enqueue.map { it.episode }, "n=$n")
        }
        assertEquals(1, SmartDownloadSettings(upcomingEpisodes = 0).upcoming)
        assertEquals(3, SmartDownloadSettings(upcomingEpisodes = 9).upcoming)
    }

    @Test fun nothingHappensUntilAnEpisodeIsFinishedOrForASeriesThatWasNeverDownloaded() {
        assertTrue(plan(s = series(emptySet()), entries = listOf(entry(5), entry(6))).isEmpty)
        assertTrue(plan(s = series(setOf(1)), entries = emptyList()).isEmpty)
        assertTrue(plan(s = series(setOf(1)), entries = listOf(entry(1, status = OfflineStatus.FAILED))).isEmpty)
    }

    @Test fun onlyAiredEpisodesAreDownloadedAndWatchedOnesAreSkipped() {
        val p = plan(settings = on.copy(upcomingEpisodes = 3), s = series(watched = setOf(1, 3), total = 8, airedThrough = 5), entries = listOf(entry(1)))
        assertEquals(listOf(id(1, 4), id(1, 5)), p.enqueue.map { it.episode }) // 2 was skipped over by the viewer, 6+ not aired
    }

    @Test fun insufficientStorageBlocksTheDownloadAndKeepsEverything() {
        val low = goodConditions.copy(freeStorageBytes = GB + GB / 2) // 0.5 GB above the reserve, 1 GB needed
        val p = plan(
            settings = on.copy(upcomingEpisodes = 1, autoDelete = AutoDeletePolicy.AUTOMATIC_ONLY),
            conditions = low, s = series(setOf(1)), entries = listOf(entry(1)), // manual: cannot be deleted to make room
        )
        assertTrue(p.enqueue.isEmpty()); assertTrue(p.remove.isEmpty())
        assertEquals(BlockReason.InsufficientStorage(GB, GB / 2), p.blocked.single().reason)
    }

    @Test fun aFinishedAutomaticEpisodeIsGivenUpFirstOnlyWhenTheReplacementCannotFitOtherwise() {
        val low = goodConditions.copy(freeStorageBytes = GB + GB / 2)
        val p = plan(
            settings = on.copy(upcomingEpisodes = 1), conditions = low, s = series(setOf(1)),
            entries = listOf(entry(1, DownloadOrigin.NEXT_EPISODE)),
        )
        assertEquals(listOf(id(1, 2)), p.enqueue.map { it.episode })
        assertEquals(listOf(ref(1)), p.remove) // free-first, because it would not fit otherwise
        assertTrue(p.blocked.isEmpty())
    }

    @Test fun freeingEverythingDeletableStillNotEnoughMeansNothingIsDeleted() {
        val tiny = goodConditions.copy(freeStorageBytes = GB / 2)
        val p = plan(settings = on.copy(upcomingEpisodes = 1), conditions = tiny, s = series(setOf(1)), entries = listOf(entry(1, DownloadOrigin.NEXT_EPISODE)))
        assertTrue(p.enqueue.isEmpty()); assertTrue(p.remove.isEmpty(), "never delete when the replacement still would not fit")
        assertTrue(p.blocked.single().reason is BlockReason.InsufficientStorage)
    }

    @Test fun anOfflineDeviceStartsNothingAndDeletesNothing() {
        val p = plan(conditions = goodConditions.copy(online = false, onWifi = false), s = series(setOf(1)), entries = listOf(entry(1), entry(2)))
        assertTrue(p.enqueue.isEmpty()); assertTrue(p.remove.isEmpty())
        assertEquals(BlockReason.Offline, p.blocked.single().reason)
    }

    @Test fun cellularRestrictionsAreHonouredAndCanBeRelaxed() {
        val cell = goodConditions.copy(onWifi = false)
        assertEquals(BlockReason.CellularRestricted, plan(conditions = cell, s = series(setOf(1)), entries = listOf(entry(1), entry(2))).blocked.single().reason)
        val allowed = plan(settings = on.copy(wifiOnly = false), conditions = cell, s = series(setOf(1)), entries = listOf(entry(1), entry(2)))
        assertEquals(listOf(id(1, 3)), allowed.enqueue.map { it.episode })
        assertEquals(BlockReason.ChargingRequired, plan(settings = on.copy(chargingOnly = true), s = series(setOf(1)), entries = listOf(entry(1), entry(2))).blocked.single().reason)
    }

    @Test fun anUnavailableSourceStopsRetriesKeepsTheWatchedEpisodeAndRespectsBackoff() {
        val store = SmartDownloadHistoryStore(InMemoryPlaybackStateStore())
        val target = ref(3)
        repeat(3) { store.recordAttempt(target, nowMs = 1_000L) }
        val exhausted = plan(s = series(setOf(1)), entries = listOf(entry(1), entry(2)), history = store, now = 10_000_000_000L)
        assertEquals(BlockReason.AttemptsExhausted, exhausted.blocked.single().reason)
        assertTrue(exhausted.remove.isEmpty(), "the finished episode stays when the replacement cannot be fetched")

        val fresh = SmartDownloadHistoryStore(InMemoryPlaybackStateStore())
        fresh.recordAttempt(target, nowMs = 1_000_000L)
        val tooSoon = plan(s = series(setOf(1)), entries = listOf(entry(1), entry(2)), history = fresh, now = 1_000_000L + 60_000L)
        assertTrue(tooSoon.blocked.single().reason is BlockReason.RetryLater)
        val later = plan(s = series(setOf(1)), entries = listOf(entry(1), entry(2)), history = fresh, now = 1_000_000L + 20 * 60_000L)
        assertEquals(listOf(id(1, 3)), later.enqueue.map { it.episode })

        fresh.markUserRemoved(target)
        assertEquals(BlockReason.SuppressedByUser, plan(s = series(setOf(1)), entries = listOf(entry(1), entry(2)), history = fresh, now = 9_999_999_999L).blocked.single().reason)
    }

    @Test fun aFailedAutomaticAttemptIsReplacedWithAFreshSource() {
        val p = plan(settings = on.copy(upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(entry(1), entry(2, DownloadOrigin.NEXT_EPISODE, OfflineStatus.FAILED)))
        assertTrue(p.enqueue.single().replacesFailed)
        // A failed manual download is the viewer's to retry, not replaced behind their back.
        val manual = plan(settings = on.copy(upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(entry(1), entry(2, DownloadOrigin.MANUAL, OfflineStatus.FAILED)))
        assertFalse(manual.enqueue.single().replacesFailed)
    }

    @Test fun manualDownloadsRemainProtectedUnlessTheViewerChoseOtherwise() {
        val asDefault = plan(settings = SmartDownloadSettings(nextEpisodeEnabled = true, upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(entry(1), entry(2)))
        assertTrue(asDefault.remove.isEmpty(), "the default deletes only automatic downloads")
        val never = plan(settings = on.copy(upcomingEpisodes = 1, autoDelete = AutoDeletePolicy.NEVER), s = series(setOf(1)), entries = listOf(entry(1, DownloadOrigin.NEXT_EPISODE), entry(2)))
        assertTrue(never.remove.isEmpty())
        // The viewer's explicit choice still never deletes pinned, retained or playing content.
        for (protectedEntry in listOf(entry(1, pinned = true), entry(1, retained = true), entry(1, playing = true))) {
            val p = plan(settings = on.copy(upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(protectedEntry, entry(2)))
            assertTrue(p.remove.isEmpty(), "$protectedEntry")
        }
        val automaticPinned = plan(settings = on.copy(upcomingEpisodes = 1), s = series(setOf(1)), entries = listOf(entry(1, DownloadOrigin.NEXT_EPISODE, pinned = true), entry(2)))
        assertTrue(automaticPinned.remove.isEmpty())
    }

    @Test fun theLastEpisodeOfASeriesIsKeptUnlessTheViewerChoosesOtherwise() {
        val s = series(setOf(1, 2, 3), total = 5, airedThrough = 3)
        val entries = listOf(entry(1, DownloadOrigin.NEXT_EPISODE), entry(2, DownloadOrigin.NEXT_EPISODE), entry(3, DownloadOrigin.NEXT_EPISODE))
        val kept = plan(s = s, entries = entries)
        assertTrue(kept.enqueue.isEmpty())
        assertEquals(listOf(ref(1), ref(2)), kept.remove)
        val chosen = plan(settings = on.copy(deleteLastEpisode = true), s = s, entries = entries)
        assertEquals(listOf(ref(1), ref(2), ref(3)), chosen.remove)
    }

    @Test fun storageBudgetsArePerProfileAndManualDownloadsDoNotCountAgainstThem() {
        val limited = on.copy(upcomingEpisodes = 1, profileBudgetBytes = 2 * GB)
        val entries = listOf(
            entry(1, profile = 1), entry(2, DownloadOrigin.NEXT_EPISODE, size = GB + GB / 2, profile = 1, title = "other"),
            entry(1, profile = 2),
        )
        val profileOne = plan(settings = limited, s = series(setOf(1), profile = 1), entries = entries)
        assertEquals(BlockReason.ProfileBudgetReached(2 * GB), profileOne.blocked.single().reason)
        val profileTwo = plan(settings = limited, s = series(setOf(1), profile = 2), entries = entries)
        assertEquals(listOf(id(1, 2)), profileTwo.enqueue.map { it.episode }, "another profile's automatic downloads do not use this profile's budget")
        val manualOnly = plan(settings = limited, s = series(setOf(1)), entries = listOf(entry(1, size = 40 * GB), entry(5, size = 40 * GB)))
        assertEquals(1, manualOnly.enqueue.size, "manual downloads never count against an automatic budget")
    }

    @Test fun theDeviceWideStorageLimitCountsAutomaticDownloadsOfEveryProfile() {
        val limited = on.copy(upcomingEpisodes = 1, storageLimitBytes = 2 * GB)
        val entries = listOf(entry(1, profile = 1), entry(7, DownloadOrigin.FOR_YOU, size = 2 * GB, profile = 2, title = "movie"))
        val p = plan(settings = limited, s = series(setOf(1), profile = 1), entries = entries)
        assertEquals(BlockReason.StorageLimitReached(2 * GB), p.blocked.single().reason)
    }

    @Test fun disablingSmartDownloadsMidTransferStopsUnfinishedAutomaticWorkAndKeepsEverythingElse() {
        val entries = listOf(
            entry(1, DownloadOrigin.NEXT_EPISODE, OfflineStatus.COMPLETED),
            entry(2, DownloadOrigin.NEXT_EPISODE, OfflineStatus.DOWNLOADING),
            entry(3, DownloadOrigin.NEXT_EPISODE, OfflineStatus.QUEUED),
            entry(4, DownloadOrigin.MANUAL, OfflineStatus.DOWNLOADING),
        )
        val p = plan(settings = on.copy(nextEpisodeEnabled = false), s = series(setOf(1)), entries = entries)
        assertEquals(listOf(ref(2), ref(3)), p.cancel)
        assertTrue(p.enqueue.isEmpty()); assertTrue(p.remove.isEmpty())
        assertEquals(BlockReason.FeatureDisabled, p.blocked.single().reason)
    }

    @Test fun aRestrictedTitleIsNeverDownloadedAutomatically() {
        val p = plan(s = series(setOf(1), restricted = true), entries = listOf(entry(1), entry(2, DownloadOrigin.NEXT_EPISODE, OfflineStatus.QUEUED)))
        assertTrue(p.enqueue.isEmpty()); assertEquals(listOf(ref(2)), p.cancel)
        assertEquals(BlockReason.RestrictedTitle, p.blocked.single().reason)
    }

    @Test fun planIsDeterministic() {
        val a = plan(s = series(setOf(1)), entries = listOf(entry(2), entry(1)))
        val b = plan(s = series(setOf(1)), entries = listOf(entry(1), entry(2)))
        assertEquals(a, b)
    }
}

class ForYouPlannerTest {
    private fun cand(key: String, relevance: Double = 0.8, bytes: Long = GB, watched: Boolean = false, available: Boolean = true, restricted: Boolean = false) =
        ForYouCandidate(key, id(1, 1), relevance, bytes, watched, available, restricted)

    private val settings = SmartDownloadSettings(forYouEnabled = true, forYouMaxTitles = 3, autoDelete = AutoDeletePolicy.AUTOMATIC_ONLY)
    private fun plan(
        candidates: List<ForYouCandidate>,
        entries: List<OfflineEntry> = emptyList(),
        s: SmartDownloadSettings = settings,
        c: DeviceConditions = goodConditions,
        history: SmartDownloadHistory = NoSmartDownloadHistory,
        now: Long = 0L,
        profile: Int = 1,
    ) = ForYouPlanner.plan(s, c, profile, candidates, entries, history, now)

    @Test fun picksTheMostRelevantTitlesUpToTheLimitAndIsOptIn() {
        val p = plan(listOf(cand("a", 0.6), cand("b", 0.9), cand("c", 0.7), cand("d", 0.95)))
        assertEquals(listOf("d", "b", "c"), p.enqueue.map { it.titleKey })
        assertTrue(p.enqueue.all { it.origin == DownloadOrigin.FOR_YOU })
        val off = plan(listOf(cand("a")), s = settings.copy(forYouEnabled = false))
        assertTrue(off.enqueue.isEmpty()); assertEquals(BlockReason.FeatureDisabled, off.blocked.single().reason)
    }

    @Test fun excludesWatchedOfflineRestrictedUnavailableAndLowRelevanceTitlesWithReasons() {
        val entries = listOf(entry(1, DownloadOrigin.MANUAL, title = "have"))
        val p = plan(
            listOf(cand("watched", watched = true), cand("have"), cand("kids", restricted = true), cand("nolink", available = false), cand("meh", relevance = 0.2), cand("good")),
            entries = entries,
        )
        assertEquals(listOf("good"), p.enqueue.map { it.titleKey })
        val reasons = p.excluded.associate { it.titleKey to it.reason }
        assertEquals(ForYouExclusion.ALREADY_WATCHED, reasons["watched"])
        assertEquals(ForYouExclusion.ALREADY_OFFLINE, reasons["have"])
        assertEquals(ForYouExclusion.RESTRICTED, reasons["kids"])
        assertEquals(ForYouExclusion.NO_COMPATIBLE_SOURCE, reasons["nolink"])
        assertEquals(ForYouExclusion.LOW_RELEVANCE, reasons["meh"])
    }

    @Test fun theSameTitleIsNotDownloadedAutomaticallyAgainAndAViewerRemovalIsFinal() {
        val store = SmartDownloadHistoryStore(InMemoryPlaybackStateStore())
        store.recordSuccess(OfflineRef(1, "again", id(1, 1)), nowMs = 1_000L)
        store.markUserRemoved(OfflineRef(1, "gone", id(1, 1)))
        val soon = plan(listOf(cand("again"), cand("gone"), cand("new")), history = store, now = 10L * 24 * 60 * 60_000L)
        assertEquals(listOf("new"), soon.enqueue.map { it.titleKey })
        assertEquals(ForYouExclusion.RECENTLY_DOWNLOADED, soon.excluded.first { it.titleKey == "again" }.reason)
        assertEquals(ForYouExclusion.REMOVED_BY_USER, soon.excluded.first { it.titleKey == "gone" }.reason)
        val muchLater = plan(listOf(cand("again")), history = store, now = 90L * 24 * 60 * 60_000L)
        assertEquals(listOf("again"), muchLater.enqueue.map { it.titleKey })
    }

    @Test fun manualDownloadsAreNeverClearedCountedOrOverwritten() {
        val entries = listOf(
            entry(1, DownloadOrigin.MANUAL, size = 30 * GB, title = "mine", watched = true),
            entry(1, DownloadOrigin.FOR_YOU, title = "auto-done", watched = true),
        )
        val p = plan(listOf(cand("x")), entries = entries, s = settings.copy(storageLimitBytes = 3 * GB, autoDelete = AutoDeletePolicy.ALL_WATCHED))
        assertEquals(listOf(OfflineRef(1, "auto-done", id(1, 1))), p.remove, "only the automatic, finished download is cleared")
        assertEquals(listOf("x"), p.enqueue.map { it.titleKey }, "30 GB of manual downloads do not use the automatic limit")
    }

    @Test fun theBudgetAndStorageAreRespectedPerProfile() {
        val budget = settings.copy(profileBudgetBytes = 2 * GB)
        val entries = listOf(entry(1, DownloadOrigin.FOR_YOU, size = GB, title = "kept", profile = 1), entry(1, DownloadOrigin.FOR_YOU, size = 5 * GB, title = "theirs", profile = 2))
        val profileOne = plan(listOf(cand("a", 0.9), cand("b", 0.8)), entries = entries, s = budget, profile = 1)
        assertEquals(listOf("a"), profileOne.enqueue.map { it.titleKey })
        assertTrue(profileOne.blocked.any { it.subject == "b" && it.reason == BlockReason.ProfileBudgetReached(2 * GB) })
        val profileTwo = plan(listOf(cand("a", 0.9)), entries = entries, s = budget.copy(profileBudgetBytes = 8 * GB, storageLimitBytes = null), profile = 2)
        assertEquals(listOf("a"), profileTwo.enqueue.map { it.titleKey })
        val full = plan(listOf(cand("a")), c = goodConditions.copy(freeStorageBytes = GB))
        assertTrue(full.enqueue.isEmpty()); assertTrue(full.blocked.single().reason is BlockReason.InsufficientStorage)
    }

    @Test fun offlineAndCellularHoldBackNewPicksButFinishedOnesCanStillBeCleared() {
        val done = entry(1, DownloadOrigin.FOR_YOU, title = "seen", watched = true)
        val offline = plan(listOf(cand("x")), entries = listOf(done), c = goodConditions.copy(online = false, onWifi = false))
        assertTrue(offline.enqueue.isEmpty()); assertEquals(listOf(done.ref), offline.remove)
        assertEquals(BlockReason.CellularRestricted, plan(listOf(cand("x")), c = goodConditions.copy(onWifi = false)).blocked.single().reason)
    }

    @Test fun disablingStopsUnfinishedAutomaticDownloadsOnly() {
        val entries = listOf(
            entry(1, DownloadOrigin.FOR_YOU, OfflineStatus.DOWNLOADING, title = "a"),
            entry(1, DownloadOrigin.FOR_YOU, OfflineStatus.COMPLETED, title = "b"),
            entry(1, DownloadOrigin.MANUAL, OfflineStatus.DOWNLOADING, title = "c"),
        )
        val p = plan(emptyList(), entries = entries, s = settings.copy(forYouEnabled = false))
        assertEquals(listOf(OfflineRef(1, "a", id(1, 1))), p.cancel)
        assertTrue(p.remove.isEmpty())
    }
}

class DownloadRecoveryTest {
    @Test fun anExpiredStreamUrlIsRefreshedAFewTimesThenMarkedUnavailable() {
        for (status in listOf(401, 403, 410)) assertEquals(FailureKind.EXPIRED_SOURCE, DownloadFailures.classify(status, null), "$status")
        assertEquals(FailureKind.EXPIRED_SOURCE, DownloadFailures.classify(null, "The link has expired"))
        assertEquals(RecoveryAction.REFRESH_SOURCE_AND_RETRY, DownloadRecovery.next(FailureKind.EXPIRED_SOURCE, attempts = 0).action)
        assertEquals(RecoveryAction.REFRESH_SOURCE_AND_RETRY, DownloadRecovery.next(FailureKind.EXPIRED_SOURCE, attempts = 1).action)
        assertEquals(RecoveryAction.MARK_UNAVAILABLE, DownloadRecovery.next(FailureKind.EXPIRED_SOURCE, attempts = 2).action)
    }

    @Test fun networkDropsAreRetriedWithGrowingWaitsAndStorageFullWaits() {
        assertEquals(FailureKind.TRANSIENT_NETWORK, DownloadFailures.classify(503, null))
        assertEquals(FailureKind.TRANSIENT_NETWORK, DownloadFailures.classify(null, "The request timed out"))
        val waits = (0..2).map { DownloadRecovery.next(FailureKind.TRANSIENT_NETWORK, it).retryAfterMs!! }
        assertTrue(waits[0] < waits[1] && waits[1] < waits[2])
        assertEquals(RecoveryAction.FAIL, DownloadRecovery.next(FailureKind.TRANSIENT_NETWORK, 3).action)
        assertEquals(FailureKind.STORAGE_FULL, DownloadFailures.classify(null, "No space left on device"))
        assertEquals(RecoveryAction.WAIT_FOR_STORAGE, DownloadRecovery.next(FailureKind.STORAGE_FULL, 5).action)
        assertEquals(FailureKind.SOURCE_GONE, DownloadFailures.classify(404, null))
        assertEquals(RecoveryAction.MARK_UNAVAILABLE, DownloadRecovery.next(FailureKind.SOURCE_GONE, 1).action)
    }

    @Test fun sourcesThatCannotBeSavedAreNeverPicked() {
        assertNull(DownloadSourceSelector.pick(listOf(DownloadableSource("a", null, "magnet:?xt=urn:btih:abc", 1080), DownloadableSource("b", null, "https://x/y.m3u8", 1080), DownloadableSource("c", null, "https://x/y.mpd?z=1", 720)), DownloadQuality.STANDARD))
        assertNull(DownloadSourceSelector.pick(emptyList(), DownloadQuality.HIGH))
        assertFalse(DownloadSourceSelector.isDownloadable("https://x/y.torrent"))
        assertTrue(DownloadSourceSelector.isDownloadable("https://cdn.example/video.mkv?token=1"))
    }

    @Test fun qualityPreferenceCapsResolutionAndPrefersTheViewersProvider() {
        val sources = listOf(
            DownloadableSource("720", "a", "https://x/720.mp4", 720), DownloadableSource("1080a", "a", "https://x/1080a.mp4", 1080),
            DownloadableSource("1080b", "b", "https://x/1080b.mp4", 1080), DownloadableSource("2160", "a", "https://x/2160.mp4", 2160),
        )
        assertEquals("720", DownloadSourceSelector.pick(sources, DownloadQuality.DATA_SAVER)?.id)
        assertEquals("1080b", DownloadSourceSelector.pick(sources, DownloadQuality.STANDARD, preferredAddonId = "b")?.id)
        assertEquals("1080a", DownloadSourceSelector.pick(sources, DownloadQuality.STANDARD, preferredAddonId = "a")?.id)
        assertEquals("2160", DownloadSourceSelector.pick(sources, DownloadQuality.HIGH)?.id)
        // Everything above the cap: the smallest is used rather than nothing.
        assertEquals("1080a", DownloadSourceSelector.pick(sources.filter { it.resolutionHeight!! >= 1080 }, DownloadQuality.DATA_SAVER, "a")?.id)
    }

    @Test fun estimatedSizeFollowsRuntimeAndQuality() {
        assertEquals(45L * 60 * 4_000_000 / 8, EstimatedDownloadSize.forRuntime(null, DownloadQuality.STANDARD))
        assertTrue(EstimatedDownloadSize.forRuntime(60, DownloadQuality.HIGH) > EstimatedDownloadSize.forRuntime(60, DownloadQuality.DATA_SAVER))
    }
}

class DownloadReconcilerTest {
    private fun t(id: String, status: OfflineStatus, resumable: Boolean = false, attempts: Int = 0, total: Long? = null, file: Boolean = false) =
        PersistedTransfer(id, status, totalBytes = total, completedFileExists = file, resumable = resumable, attempts = attempts)

    @Test fun anInterruptedDownloadResumesFromThePartialFileOrRestarts() {
        val r = DownloadReconciler.reconcile(listOf(t("a", OfflineStatus.DOWNLOADING, resumable = true), t("b", OfflineStatus.DOWNLOADING)), emptyMap())
        assertEquals(ReconcileAction.ResumeFromPartial, r["a"]); assertEquals(ReconcileAction.RestartFromBeginning, r["b"])
        val dropped = DownloadReconciler.reconcile(listOf(t("a", OfflineStatus.DOWNLOADING, resumable = true)), mapOf("a" to NativeTransfer.Failed(FailureKind.TRANSIENT_NETWORK)))
        assertEquals(ReconcileAction.ResumeFromPartial, dropped["a"])
    }

    @Test fun anAppEndedByTheSystemIsReconciledAgainstWhatTheSystemStillHas() {
        val persisted = listOf(
            t("running", OfflineStatus.DOWNLOADING), t("finishedOk", OfflineStatus.DOWNLOADING, total = 100), t("finishedShort", OfflineStatus.DOWNLOADING, total = 100),
            t("lostTooOften", OfflineStatus.DOWNLOADING, attempts = 3), t("paused", OfflineStatus.PAUSED), t("done", OfflineStatus.COMPLETED, file = true), t("doneMissing", OfflineStatus.COMPLETED, file = false),
        )
        val native = mapOf("running" to NativeTransfer.Running, "finishedOk" to NativeTransfer.Finished(100), "finishedShort" to NativeTransfer.Finished(40), "stray" to NativeTransfer.Running)
        val r = DownloadReconciler.reconcile(persisted, native)
        assertEquals(ReconcileAction.Keep, r["running"])
        assertEquals(ReconcileAction.MarkCompleted, r["finishedOk"])
        assertEquals(ReconcileAction.RestartFromBeginning, r["finishedShort"])
        assertEquals(ReconcileAction.MarkFailed(FailureKind.UNKNOWN), r["lostTooOften"])
        assertEquals(ReconcileAction.Keep, r["paused"]); assertEquals(ReconcileAction.Keep, r["done"])
        assertEquals(ReconcileAction.MarkFailed(FailureKind.FILE_ERROR), r["doneMissing"])
        assertEquals(ReconcileAction.CancelOrphan, r["stray"])
    }

    @Test fun aSourceThatExpiredWhileTheAppWasAwayGetsAFreshOne() {
        val r = DownloadReconciler.reconcile(listOf(t("a", OfflineStatus.DOWNLOADING, attempts = 0), t("b", OfflineStatus.DOWNLOADING, attempts = 2)), mapOf("a" to NativeTransfer.Failed(FailureKind.EXPIRED_SOURCE), "b" to NativeTransfer.Failed(FailureKind.EXPIRED_SOURCE)))
        assertEquals(ReconcileAction.RefreshSourceAndRestart(FailureKind.EXPIRED_SOURCE), r["a"])
        assertEquals(ReconcileAction.MarkFailed(FailureKind.EXPIRED_SOURCE), r["b"])
    }
}

class SmartDownloadHistoryStoreTest {
    @Test fun recordsPersistPerProfileAndSuccessResetsAttempts() {
        val backing = InMemoryPlaybackStateStore()
        val store = SmartDownloadHistoryStore(backing)
        val r = ref(2)
        store.recordAttempt(r, 100L); store.recordAttempt(r, 200L)
        assertEquals(2, SmartDownloadHistoryStore(backing).attempt(r)?.attempts)
        assertNull(store.attempt(ref(2, profile = 2)))
        store.recordSuccess(r, 300L)
        assertEquals(0, store.attempt(r)?.attempts); assertEquals(300L, store.forYou(1, "show")?.lastAutoDownloadMs)
        store.markUserRemoved(r); assertTrue(store.attempt(r)!!.userRemoved); assertTrue(store.forYou(1, "show")!!.userRemoved)
        store.clear(r); assertNull(store.attempt(r)); assertNull(store.forYou(1, "show"))
    }
}


class SmartDownloadHelpersTest {
    @Test fun readsAnHttpStatusFromAPlatformMessage() {
        assertEquals(FailureKind.EXPIRED_SOURCE, DownloadFailures.classify(null, "Request failed with HTTP 403"))
        assertEquals(FailureKind.SOURCE_GONE, DownloadFailures.classify(null, "Request failed with HTTP 404"))
        assertEquals(FailureKind.TRANSIENT_NETWORK, DownloadFailures.classify(null, "Request failed with HTTP 503"))
        assertEquals(FailureKind.UNKNOWN, DownloadFailures.classify(null, "something odd 4041 happened"))
    }

    @Test fun readsAdvertisedResolutionFromLabels() {
        assertEquals(1080, DownloadSourceSelector.resolutionFromLabel("Provider 1080p WEB-DL", null))
        assertEquals(2160, DownloadSourceSelector.resolutionFromLabel("Movie.2020.4K.HDR"))
        assertEquals(720, DownloadSourceSelector.resolutionFromLabel("x", "720P"))
        assertNull(DownloadSourceSelector.resolutionFromLabel("Stream", "no resolution here"))
        assertNull(DownloadSourceSelector.resolutionFromLabel("S01E10805"))
    }

    @Test fun expiredLinksRetryImmediatelyButStillCountTowardTheLimit() {
        val store = SmartDownloadHistoryStore(InMemoryPlaybackStateStore())
        val r = ref(2)
        store.recordAttempt(r, nowMs = 1_000_000L, retryImmediately = true)
        val plan = NextEpisodePlanner.plan(on.copy(upcomingEpisodes = 1), goodConditions, series(setOf(1)), listOf(entry(1), entry(2, DownloadOrigin.NEXT_EPISODE, OfflineStatus.FAILED)), store, nowMs = 1_000_001L)
        assertEquals(listOf(id(1, 2)), plan.enqueue.map { it.episode }, "no waiting period after an expired link")
        repeat(2) { store.recordAttempt(r, nowMs = 1_000_000L, retryImmediately = true) }
        val exhausted = NextEpisodePlanner.plan(on.copy(upcomingEpisodes = 1), goodConditions, series(setOf(1)), listOf(entry(1), entry(2, DownloadOrigin.NEXT_EPISODE, OfflineStatus.FAILED)), store, nowMs = 1_000_001L)
        assertEquals(BlockReason.AttemptsExhausted, exhausted.blocked.single().reason)
    }

    @Test fun datesAndAiringAreReadWithoutADateLibrary() {
        assertEquals("1970-01-01", ReleaseDates.isoDateUtc(0L))
        assertEquals("2000-02-29", ReleaseDates.isoDateUtc(951_782_400_000L))
        assertEquals("2026-11-27", ReleaseDates.isoDateUtc(1_795_737_600_000L))
        assertEquals("1969-12-31", ReleaseDates.isoDateUtc(-1L))
        val now = 1_795_737_600_000L // 2026-11-27
        assertTrue(ReleaseDates.hasAired("2026-11-27", true, now))
        assertTrue(ReleaseDates.hasAired("2026-11-26T20:00:00Z", true, now))
        assertFalse(ReleaseDates.hasAired("2026-11-28", true, now))
        assertFalse(ReleaseDates.hasAired("2026-01-01", false, now), "the source says it is not available")
        assertTrue(ReleaseDates.hasAired(null, true, now)); assertFalse(ReleaseDates.hasAired("garbage", false, now))
    }
}
