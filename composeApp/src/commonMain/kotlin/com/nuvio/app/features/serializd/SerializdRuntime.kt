package com.nuvio.app.features.serializd

import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.mdblist.TmdbMdbListEpisodes
import com.nuvio.app.features.music.data.MusicStorage
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

/** The app's one Serializd manager, built on first use. Everything else reaches Serializd through it. */
internal object SerializdRuntime {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val metaIds = HashMap<Int, String>()

    private val store = object : SerializdKeyValue {
        override fun read(key: String): String? = MusicStorage.getString("serializd", key)?.takeIf { it.isNotEmpty() }
        override fun write(key: String, value: String?) { if (value == null) MusicStorage.remove("serializd", key) else MusicStorage.putString("serializd", key, value) }
    }

    val manager: SerializdManager by lazy {
        SerializdManager(
            kv = store,
            secrets = PlatformSerializdSecrets,
            transport = KtorSerializdTransport(::createSerializdHttpClient),
            scope = scope,
            newId = { "${kotlin.time.Clock.System.now().toEpochMilliseconds().toString(36)}-${Random.nextLong().toULong().toString(36)}" },
            isFavorite = { _, showTmdbId -> metaIds[showTmdbId]?.let { LibraryRepository.isSaved(it, "series") } == true },
            // Only asked when Serializd keeps a show as one long season: the earlier seasons' lengths place the later ones' episodes.
            seasonLengthsOf = { showTmdbId -> runCatching { TmdbMdbListEpisodes.seasonCounts(showTmdbId.toLong()) }.getOrDefault(emptyMap()) },
            importSink = SerializdWatchedImport,
            watchlistSink = com.nuvio.app.features.watchlist.WatchLaterImport,
        )
    }

    /** Remembers which library id a TMDB show has, for the favourites-to-likes setting. */
    fun rememberMetaId(showTmdbId: Int, metaId: String) { metaIds[showTmdbId] = metaId }

    private val tmdbByMeta = HashMap<String, Int>()
    private val resolving = HashSet<String>()

    private val _playerActive = MutableStateFlow(false)
    /** True while an episode is playing with Serializd tracking on. */
    val playerActive: StateFlow<Boolean> = _playerActive.asStateFlow()

    /** The show's TMDB id for a BannerTV series id (an IMDb id or a "tmdb:" id), resolved once and remembered. Null while unknown or for a show with none. */
    suspend fun showTmdbId(metaId: String, imdbId: String? = null): Int? {
        tmdbByMeta[metaId]?.let { return it.takeIf { id -> id > 0 } }
        val id = runCatching { TmdbService.ensureTmdbId(metaId, "tv", imdbId) }.getOrNull()?.toIntOrNull() ?: 0
        tmdbByMeta[metaId] = id
        if (id > 0) metaIds[id] = metaId
        return id.takeIf { it > 0 }
    }

    /**
     * Called by the player about once a second for a TV episode. Cheap when no account is connected. The show's TMDB id is looked up
     * once per series; until it is known nothing is counted. Movies never come here and episodes never go to Letterboxd.
     */
    fun onPlayerSnapshot(
        profileId: Int, metaId: String, season: Int, episode: Int, showName: String, episodeTitle: String?, poster: String?, snapshot: PlayerPlaybackSnapshot,
    ) {
        if (metaId.isBlank()) return
        val m = manager
        if (m.accountOf(profileId) == null) return
        val tmdb = tmdbByMeta[metaId]
        if (tmdb == null) {
            if (resolving.add(metaId)) scope.launch { showTmdbId(metaId); resolving.remove(metaId) }
            return
        }
        if (tmdb <= 0) return
        _playerActive.value = true
        m.playbackSample(profileId, tmdb, season, episode, showName, episodeTitle, poster, snapshot.positionMs, snapshot.durationMs, snapshot.isPlaying && !snapshot.isLoading, snapshot.isEnded)
    }

    /** The player went away from this episode. */
    fun onPlayerStopped(profileId: Int, metaId: String, season: Int?, episode: Int?) {
        _playerActive.value = false
        val tmdb = tmdbByMeta[metaId] ?: return
        if (tmdb > 0 && season != null && episode != null) manager.playbackStopped(profileId, tmdb, season, episode)
    }
}
