package com.nuvio.app.mac

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.livetv.LIVE_TV_EPG_FUTURE_WINDOW_MILLIS
import com.nuvio.app.features.livetv.LIVE_TV_EPG_PAST_WINDOW_MILLIS
import com.nuvio.app.features.livetv.LiveTvChannel
import com.nuvio.app.features.livetv.LiveTvEpgGuide
import com.nuvio.app.features.livetv.LiveTvEpgProgram
import com.nuvio.app.features.livetv.LiveTvPlaylist
import com.nuvio.app.features.livetv.LiveTvPlaylistType
import com.nuvio.app.features.livetv.LiveTvStalkerSettings
import com.nuvio.app.features.livetv.LiveTvXtreamSettings
import com.nuvio.app.features.livetv.describeProviderFailure
import com.nuvio.app.features.livetv.fetchXmltvGuide
import com.nuvio.app.features.livetv.fetchXtreamChannels
import com.nuvio.app.features.livetv.matchEpgToChannels
import com.nuvio.app.features.livetv.parseM3uEpgUrls
import com.nuvio.app.features.livetv.parseM3uPlaylist
import com.nuvio.app.features.livetv.xtreamEpgUrl
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import platform.Foundation.NSUserDefaults

/** The person's IPTV sources. Credentials are held by the Swift app (Keychain) and handed in here at launch. */
class MacLiveTvSources(
    val playlistNames: List<String>,
    val playlistUrls: List<String>,
    val xtreamServer: String,
    val xtreamUsername: String,
    val xtreamPassword: String,
    val epgUrls: List<String>,
)

class MacLiveTvState(
    val channels: List<LiveTvChannel>,
    val isLoading: Boolean,
    val error: String?,
    val isGuideLoading: Boolean,
    val guideLoaded: Boolean,
)

/** One airing, ready for the guide grid. */
class MacProgram(val title: String, val startMs: Long, val endMs: Long, val description: String?, val category: String?)

/**
 * Live TV: channels from M3U playlists and Xtream, the XMLTV guide, favourites and recents. Playlist parsing, the Xtream
 * client and the guide parser are the shared core's.
 */
object MacLiveTv {
    private val scope = macScope()
    private val defaults get() = NSUserDefaults.standardUserDefaults

    private var sources = MacLiveTvSources(emptyList(), emptyList(), "", "", "", emptyList())
    private val _state = MutableStateFlow(MacLiveTvState(emptyList(), false, null, false, false))
    val state: StateFlow<MacLiveTvState> = _state

    private var programs: Map<String, List<LiveTvEpgProgram>> = emptyMap()

    /** The guide as loaded, by channel id (the Sports hub reads it to find a game's channels). */
    internal fun programsSnapshot(): Map<String, List<LiveTvEpgProgram>> = programs
    private val _favorites = MutableStateFlow(loadSet("mac_live_favorites"))
    val favorites: StateFlow<Set<String>> = _favorites
    private val _recents = MutableStateFlow(defaults.stringForKey("mac_live_recents")?.split("\n")?.filter { it.isNotBlank() }.orEmpty())
    val recents: StateFlow<List<String>> = _recents

    private var channelsJob: Job? = null
    private var guideJob: Job? = null

    private fun loadSet(key: String): Set<String> =
        defaults.stringForKey(key)?.split("\n")?.filter { it.isNotBlank() }?.toSet().orEmpty()

    val hasSources: Boolean
        get() = sources.playlistUrls.isNotEmpty() || (sources.xtreamServer.isNotBlank() && sources.xtreamUsername.isNotBlank())

    fun configure(newSources: MacLiveTvSources) {
        sources = newSources
        refresh()
    }

    private fun xtream() = LiveTvXtreamSettings(sources.xtreamServer, sources.xtreamUsername, sources.xtreamPassword, isEnabled = true)

    fun refresh() {
        channelsJob?.cancel()
        guideJob?.cancel()
        if (!hasSources) {
            programs = emptyMap()
            _state.value = MacLiveTvState(emptyList(), false, null, false, false)
            return
        }
        _state.value = MacLiveTvState(_state.value.channels, true, null, false, false)
        val snapshot = sources
        channelsJob = scope.launch {
            val loaded = mutableListOf<LiveTvChannel>()
            val failures = mutableListOf<String>()
            val epgUrls = mutableListOf<String>()
            coroutineScope {
                val playlistJobs = snapshot.playlistUrls.mapIndexed { index, url ->
                    async {
                        val name = snapshot.playlistNames.getOrNull(index)?.ifBlank { null } ?: url
                        val playlist = LiveTvPlaylist("playlist:$index", name, LiveTvPlaylistType.Url, url)
                        runCatching {
                            val payload = httpGetText(url)
                            withContext(Dispatchers.Default) { parseM3uEpgUrls(payload) to parseM3uPlaylist(payload, playlist) }
                        }.onFailure { if (it is CancellationException) throw it; failures += name }.getOrNull()
                    }
                }
                val xtreamJob = if (snapshot.xtreamServer.isNotBlank() && snapshot.xtreamUsername.isNotBlank()) {
                    async {
                        runCatching { withContext(Dispatchers.Default) { fetchXtreamChannels(xtream()) } }
                            .onFailure { if (it is CancellationException) throw it; failures += "Xtream: ${describeProviderFailure(it)}" }
                            .getOrNull()
                    }
                } else null
                playlistJobs.awaitAll().filterNotNull().forEach { (urls, channels) -> epgUrls += urls; loaded += channels }
                xtreamJob?.await()?.let { loaded += it }
            }
            val channels = loaded.distinctBy { it.streamUrl }
            _state.value = MacLiveTvState(
                channels, false,
                when {
                    channels.isEmpty() && failures.isNotEmpty() -> "Could not load: ${failures.joinToString("; ")}"
                    channels.isEmpty() -> "No channels were found in these sources."
                    failures.isNotEmpty() -> "Some sources could not be loaded: ${failures.joinToString("; ")}"
                    else -> null
                },
                false, false,
            )
            if (channels.isNotEmpty()) refreshGuide(epgUrls.distinct())
        }
    }

    private fun refreshGuide(detected: List<String>) {
        guideJob?.cancel()
        val urls = linkedSetOf<String>().apply {
            addAll(sources.epgUrls)
            addAll(detected)
            if (sources.xtreamServer.isNotBlank() && sources.xtreamUsername.isNotBlank()) add(xtreamEpgUrl(xtream()))
        }
        if (urls.isEmpty()) return
        _state.value = MacLiveTvState(_state.value.channels, false, _state.value.error, true, false)
        guideJob = scope.launch {
            val now = nowMs()
            val guides = mutableListOf<LiveTvEpgGuide>()
            coroutineScope {
                urls.map { url ->
                    async { runCatching { withContext(Dispatchers.Default) { fetchXmltvGuide(url, now, null) } }.onFailure { if (it is CancellationException) throw it }.getOrNull() }
                }.awaitAll().filterNotNull().forEach { guides += it }
            }
            programs = withContext(Dispatchers.Default) { matchEpgToChannels(_state.value.channels, guides) }
            _state.value = MacLiveTvState(_state.value.channels, false, _state.value.error, false, programs.isNotEmpty())
        }
    }

    /** The guide window the grid should show: from a little before now to well ahead. */
    fun guideWindowStartMs(): Long = nowMs() - LIVE_TV_EPG_PAST_WINDOW_MILLIS
    fun guideWindowEndMs(): Long = nowMs() + LIVE_TV_EPG_FUTURE_WINDOW_MILLIS

    fun programsFor(channelId: String): List<MacProgram> =
        programs[channelId].orEmpty().map { MacProgram(it.title, it.startMillis, it.endMillis, it.description, it.category) }

    /** What is on now and what follows, for a channel. */
    fun nowAndNext(channelId: String): List<MacProgram> {
        val list = programs[channelId].orEmpty()
        val now = nowMs()
        val current = list.firstOrNull { it.isAiringAt(now) }
        val next = list.firstOrNull { it.startMillis > now }
        return listOfNotNull(current, next).map { MacProgram(it.title, it.startMillis, it.endMillis, it.description, it.category) }
    }

    fun toggleFavorite(channelId: String) {
        val updated = if (channelId in _favorites.value) _favorites.value - channelId else _favorites.value + channelId
        _favorites.value = updated
        defaults.setObject(updated.joinToString("\n"), forKey = "mac_live_favorites")
    }

    fun markWatched(channelId: String) {
        val updated = (listOf(channelId) + _recents.value.filterNot { it == channelId }).take(20)
        _recents.value = updated
        defaults.setObject(updated.joinToString("\n"), forKey = "mac_live_recents")
    }
}
