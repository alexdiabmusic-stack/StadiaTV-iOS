package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.music.data.MusicStorage
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.sports.compat.CivilTime
import com.nuvio.app.features.sports.compat.LiveTvTimeZones
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

/** The app's one Letterboxd manager, built on first use. Everything else reaches Letterboxd through it. */
internal object LetterboxdRuntime {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val metaIds = HashMap<Int, String>()

    private val store = object : LetterboxdKeyValue {
        override fun read(key: String): String? = MusicStorage.getString("letterboxd", key)?.takeIf { it.isNotEmpty() }
        override fun write(key: String, value: String?) { if (value == null) MusicStorage.remove("letterboxd", key) else MusicStorage.putString("letterboxd", key, value) }
    }

    val manager: LetterboxdManager by lazy {
        LetterboxdManager(
            kv = store,
            secrets = PlatformLetterboxdSecrets,
            transport = KtorLetterboxdTransport(::createLetterboxdHttpClient),
            scope = scope,
            localDate = { ms -> CivilTime.at(ms, LiveTvTimeZones.SYSTEM).let { LetterboxdDates.format(it.year, it.month, it.day) } },
            newId = { "${kotlin.time.Clock.System.now().toEpochMilliseconds().toString(36)}-${Random.nextLong().toULong().toString(36)}" },
            isFavorite = { _, tmdbId -> metaIds[tmdbId]?.let { LibraryRepository.isSaved(it, "movie") } == true },
            watchlistSink = com.nuvio.app.features.watchlist.WatchLaterImport,
        )
    }

    /** Remembers which library id a TMDB movie has, for the favourites-to-likes setting. */
    fun rememberMetaId(tmdbId: Int, metaId: String) { metaIds[tmdbId] = metaId }

    private val _playerActive = MutableStateFlow(false)
    /** True while a movie is playing with Letterboxd tracking on: the post-watch sheet waits until it is false. */
    val playerActive: StateFlow<Boolean> = _playerActive.asStateFlow()

    private val tmdbByMeta = HashMap<String, Int>()
    private val resolving = HashSet<String>()

    /**
     * Called by the player about once a second for a movie. Cheap when no account is connected. The TMDB id comes from the
     * library id (resolved once, then remembered); until it is known nothing is counted.
     */
    fun onPlayerSnapshot(profileId: Int, metaId: String, title: String, poster: String?, snapshot: PlayerPlaybackSnapshot) {
        if (metaId.isBlank()) return
        val m = manager
        if (m.accountOf(profileId) == null) return
        val tmdb = tmdbByMeta[metaId]
        if (tmdb == null) {
            if (resolving.add(metaId)) scope.launch {
                tmdbByMeta[metaId] = runCatching { TmdbService.ensureTmdbId(metaId, "movie") }.getOrNull()?.toIntOrNull() ?: 0
            }
            return
        }
        if (tmdb <= 0) return
        _playerActive.value = true
        metaIds[tmdb] = metaId
        m.playbackSample(profileId, tmdb, title, poster, snapshot.positionMs, snapshot.durationMs, snapshot.isPlaying && !snapshot.isLoading, snapshot.isEnded)
    }

    /** The player went away from this movie. */
    fun onPlayerStopped(profileId: Int, metaId: String) {
        _playerActive.value = false
        val tmdb = tmdbByMeta[metaId] ?: return
        if (tmdb > 0) manager.playbackStopped(profileId, tmdb)
    }
}
