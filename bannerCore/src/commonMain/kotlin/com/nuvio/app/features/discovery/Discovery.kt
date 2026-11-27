package com.nuvio.app.features.discovery

import com.nuvio.app.features.playback.PlaybackStateStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

// 4.2 Microgenres -------------------------------------------------------------------------------------------------------

data class Microgenre(
    val id: String,
    val title: String,
    val description: String,
    val types: Set<SearchMediaType>,
    val genreNames: List<String>,
    val keywords: List<String> = emptyList(),
    val exclusions: List<String> = emptyList(),
    val minResults: Int = 12,
    /** Months (1-12) when this is especially relevant; empty means all year. */
    val seasonalMonths: Set<Int> = emptySet(),
)

object MicrogenreCatalog {
    val all: List<Microgenre> = listOf(
        Microgenre("mind-bending-scifi", "Mind-Bending Science Fiction", "Reality-twisting stories that stay with you.", setOf(SearchMediaType.MOVIE, SearchMediaType.SERIES), listOf("Science Fiction"), listOf("mind-bending")),
        Microgenre("dark-crime-thrillers", "Dark Crime Thrillers", "Tense, morally grey crime stories.", setOf(SearchMediaType.MOVIE, SearchMediaType.SERIES), listOf("Crime", "Thriller"), listOf("dark")),
        Microgenre("cozy-small-town-romance", "Cozy Small-Town Romance", "Warm, gentle love stories.", setOf(SearchMediaType.MOVIE), listOf("Romance"), listOf("cozy", "small town"), seasonalMonths = setOf(11, 12, 2)),
        Microgenre("clever-heists", "Clever Heist Movies", "Elaborate plans and bigger twists.", setOf(SearchMediaType.MOVIE), listOf("Crime"), listOf("heist")),
        Microgenre("workplace-comedies", "Workplace Comedies", "Office life, only funnier.", setOf(SearchMediaType.SERIES), listOf("Comedy"), listOf("workplace")),
        Microgenre("emotional-scifi", "Emotional Science Fiction", "Big ideas with a human heart.", setOf(SearchMediaType.MOVIE), listOf("Science Fiction", "Drama")),
        Microgenre("atmospheric-mystery-series", "Atmospheric Mystery Series", "Slow-burn, moody whodunits.", setOf(SearchMediaType.SERIES), listOf("Mystery"), listOf("atmospheric")),
        Microgenre("underrated-2000s-thrillers", "Underrated 2000s Thrillers", "Overlooked thrillers from 2000 to 2009.", setOf(SearchMediaType.MOVIE), listOf("Thriller")),
        Microgenre("feel-good-escapes", "Feel-Good Escapes", "Easy, uplifting watches.", setOf(SearchMediaType.MOVIE, SearchMediaType.SERIES), listOf("Comedy", "Adventure"), listOf("feel-good")),
        Microgenre("political-suspense", "Political Suspense", "Power, secrets and consequences.", setOf(SearchMediaType.MOVIE, SearchMediaType.SERIES), listOf("Thriller", "Drama"), listOf("politics")),
    )

    /**
     * Which categories to show, best first. A category with too few real results is hidden, never padded. Personal taste leads
     * and a seasonal match gets a lift; everything above the result threshold stays reachable.
     */
    fun visible(resultCounts: Map<String, Int>, tasteAffinity: Map<String, Double>, month: Int, defs: List<Microgenre> = all): List<Microgenre> =
        defs.filter { (resultCounts[it.id] ?: 0) >= it.minResults }
            .sortedByDescending { (tasteAffinity[it.id] ?: 0.0) + if (month in it.seasonalMonths) 0.25 else 0.0 }
}

// 4.3 New & Hot labels --------------------------------------------------------------------------------------------------

enum class ReleaseKind { THEATRICAL, DIGITAL, SEASON, EPISODE, RECENTLY_AVAILABLE, TRENDING }

data class UpcomingItem(
    val mediaKey: String,
    val kind: ReleaseKind,
    val dateMs: Long?,
    /** True only when an authorised source actually lists the title as playable. */
    val streamingConfirmed: Boolean = false,
)

/** What a row says about an upcoming or new title, tied to the real source of the information. */
data class ReleaseLabel(val kind: ReleaseKind, val dateMs: Long?, val upcoming: Boolean, val canPlayNow: Boolean, val showWatchlistAndRemind: Boolean)

object ReleaseLabeler {
    fun label(item: UpcomingItem, nowMs: Long): ReleaseLabel {
        val upcoming = item.dateMs != null && item.dateMs > nowMs
        // A theatrical date says nothing about streaming; only a confirmed listing makes a title playable.
        val canPlay = item.streamingConfirmed && !upcoming
        return ReleaseLabel(item.kind, item.dateMs, upcoming, canPlay, showWatchlistAndRemind = upcoming || !canPlay && item.kind != ReleaseKind.TRENDING)
    }
}

// 4.4 Reminders ---------------------------------------------------------------------------------------------------------

enum class ReminderStage { DATE_APPROACHING, DATE_REACHED_AVAILABILITY_UNKNOWN, AVAILABLE_CONFIRMED }

@Serializable
data class ReleaseReminder(
    val profileId: Int,
    val mediaKey: String,
    val kind: ReleaseKind,
    val releaseDateMs: Long?,
    val notified: List<ReminderStage> = emptyList(),
)

sealed interface ReminderAction {
    data object None : ReminderAction
    data class Notify(val stage: ReminderStage) : ReminderAction
}

object ReminderEngine {
    private const val APPROACHING_WINDOW_MS = 24 * 60 * 60_000L

    /**
     * What to tell the viewer now. "Available to watch" is only ever sent once availability is confirmed, never from a date
     * alone; a date that has passed with no confirmation says exactly that, once. Each stage is sent at most once.
     */
    fun next(reminder: ReleaseReminder, nowMs: Long, availabilityConfirmed: Boolean): ReminderAction {
        fun due(stage: ReminderStage) = stage !in reminder.notified
        if (availabilityConfirmed && due(ReminderStage.AVAILABLE_CONFIRMED)) return ReminderAction.Notify(ReminderStage.AVAILABLE_CONFIRMED)
        val date = reminder.releaseDateMs ?: return ReminderAction.None
        return when {
            nowMs >= date && !availabilityConfirmed && due(ReminderStage.DATE_REACHED_AVAILABILITY_UNKNOWN) && ReminderStage.AVAILABLE_CONFIRMED !in reminder.notified ->
                ReminderAction.Notify(ReminderStage.DATE_REACHED_AVAILABILITY_UNKNOWN)
            nowMs < date && date - nowMs <= APPROACHING_WINDOW_MS && due(ReminderStage.DATE_APPROACHING) -> ReminderAction.Notify(ReminderStage.DATE_APPROACHING)
            else -> ReminderAction.None
        }
    }
}

/** Reminders per profile; cancelling removes one, and a changed release date re-arms the stages that depend on it. */
class ReminderStore(private val store: PlaybackStateStore, private val storeName: String = "release_reminders") {
    private val json = Json { ignoreUnknownKeys = true }
    private val ser = ListSerializer(ReleaseReminder.serializer())
    private fun load(profileId: Int) = store.get(storeName, "p$profileId")?.let { runCatching { json.decodeFromString(ser, it) }.getOrNull() }.orEmpty()
    private fun save(profileId: Int, list: List<ReleaseReminder>) = store.put(storeName, "p$profileId", json.encodeToString(ser, list))

    fun all(profileId: Int): List<ReleaseReminder> = load(profileId)

    fun add(reminder: ReleaseReminder) {
        val list = load(reminder.profileId).filterNot { it.mediaKey == reminder.mediaKey && it.kind == reminder.kind }
        save(reminder.profileId, list + reminder)
    }

    fun cancel(profileId: Int, mediaKey: String, kind: ReleaseKind) =
        save(profileId, load(profileId).filterNot { it.mediaKey == mediaKey && it.kind == kind })

    fun markNotified(profileId: Int, mediaKey: String, kind: ReleaseKind, stage: ReminderStage) =
        save(profileId, load(profileId).map { if (it.mediaKey == mediaKey && it.kind == kind) it.copy(notified = (it.notified + stage).distinct()) else it })

    fun updateReleaseDate(profileId: Int, mediaKey: String, kind: ReleaseKind, newDateMs: Long?) =
        save(profileId, load(profileId).map {
            if (it.mediaKey == mediaKey && it.kind == kind && it.releaseDateMs != newDateMs) {
                // A moved date re-arms the date-based stages; a confirmed availability stays confirmed.
                it.copy(releaseDateMs = newDateMs, notified = it.notified.filter { s -> s == ReminderStage.AVAILABLE_CONFIRMED })
            } else it
        })
}

// 4.5 My BannerTV -------------------------------------------------------------------------------------------------------

enum class MyBannerSection { CONTINUE_WATCHING, WATCHLIST, DOWNLOADS, RECENTLY_WATCHED, LIKED_AND_LOVED, UPCOMING_REMINDERS, RECENT_FAVOURITES }

object MyBannerTv {
    /** The sections to show, in a fixed order, leaving out any that are empty. Existing Library content is untouched. */
    fun sections(counts: Map<MyBannerSection, Int>): List<MyBannerSection> =
        MyBannerSection.entries.filter { (counts[it] ?: 0) > 0 }
}
