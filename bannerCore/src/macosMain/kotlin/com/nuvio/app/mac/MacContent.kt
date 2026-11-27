package com.nuvio.app.mac

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.httpGetTextWithHeaders
import com.nuvio.app.features.addons.supportsResource
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsParser
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.streams.StreamParser
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** The streams one add-on returned for a title (or why it returned none). */
class MacStreamGroup(
    val addonId: String,
    val addonName: String,
    val addonLogo: String?,
    val isLoading: Boolean,
    val error: String?,
    val streams: List<StreamItem>,
)

/**
 * Title details and playable sources, fetched from the installed add-ons with the same URL building and parsing the
 * phone apps use. Kept apart from [MacBridge] so each can grow on its own.
 */
object MacContent {
    private val scope = macScope()
    private val accept = mapOf("Accept" to "application/json")
    private const val TIMEOUT_MS = 25_000L

    private fun manifestsFor(resource: String, type: String, id: String): List<AddonManifest> =
        AddonRepository.uiState.value.addons.enabledAddons()
            .mapNotNull { it.manifest }
            .filter { it.supportsResource(resource, type, id) }

    /**
     * The add-ons that can serve [resource] for this title. Right after launch the list may still be loading, so when
     * nothing matches yet this waits (briefly) for add-ons that are still fetching their manifests.
     */
    private suspend fun awaitManifests(resource: String, type: String, id: String): List<AddonManifest> {
        AddonRepository.awaitManifestsLoaded()
        var waited = 0L
        while (waited < 8_000L) {
            val found = manifestsFor(resource, type, id)
            val stillLoading = AddonRepository.uiState.value.addons.enabledAddons().any { it.manifest == null && it.isRefreshing }
            if (found.isNotEmpty() && !stillLoading) return found
            if (found.isNotEmpty() && waited >= 1_500L) return found
            if (!stillLoading && waited >= 1_500L) return found
            kotlinx.coroutines.delay(250)
            waited += 250
        }
        return manifestsFor(resource, type, id)
    }

    private val metaCache = HashMap<String, MetaDetails>()

    fun clearCaches() { metaCache.clear() }

    /** A title's details from the first add-on that has them (cached for the session); `null` if none does. */
    suspend fun metaFor(type: String, requestedId: String): MetaDetails? {
        metaCache["$type:$requestedId"]?.let { return it }
        // Titles from TMDB-driven lists carry a "tmdb:<id>" id; the add-ons know them by IMDb id.
        val id = if (requestedId.startsWith("tmdb:", ignoreCase = true)) {
            requestedId.substringAfter(':').substringBefore(':').toIntOrNull()?.let { tmdb ->
                withTimeoutOrNull(TIMEOUT_MS) { TmdbService.tmdbToImdb(tmdb, type) }?.takeIf { it.isNotBlank() }
            } ?: requestedId
        } else requestedId
        for (manifest in awaitManifests("meta", type, id)) {
            val url = buildAddonResourceUrl(manifest.transportUrl, "meta", type, id)
            val meta = runCatching {
                withTimeoutOrNull(TIMEOUT_MS) { MetaDetailsParser.parse(httpGetTextWithHeaders(url, accept)) }
            }.onFailure { if (it is CancellationException) throw it }.getOrNull()
            if (meta != null) { metaCache["$type:$requestedId"] = meta; return meta }
        }
        return null
    }

    /** Loads a title's details; `null` if no installed add-on has them. */
    fun loadMeta(type: String, id: String, done: (MetaDetails?) -> Unit) {
        scope.launch { done(metaFor(type, id)) }
    }

    private var streamsJob: Job? = null

    /**
     * Asks every installed add-on that serves streams for this title, all at once, and reports the groups so far (in
     * the add-ons' own order) each time one answers.
     */
    fun loadStreams(type: String, videoId: String, onGroups: (List<MacStreamGroup>) -> Unit, onDone: () -> Unit) {
        streamsJob?.cancel()
        streamsJob = scope.launch {
            val manifests = awaitManifests("stream", type, videoId)
            val groups = LinkedHashMap<String, MacStreamGroup>()
            manifests.forEach { m ->
                groups[m.transportUrl] = MacStreamGroup(m.id, m.name, m.logoUrl, isLoading = true, error = null, streams = emptyList())
            }
            onGroups(groups.values.toList())
            coroutineScope {
                manifests.forEach { manifest ->
                    launch {
                        val url = buildAddonResourceUrl(manifest.transportUrl, "stream", type, videoId)
                        var failure: String? = null
                        val streams = try {
                            withTimeoutOrNull(TIMEOUT_MS) {
                                StreamParser.parse(
                                    payload = httpGetTextWithHeaders(url, accept),
                                    addonName = manifest.name,
                                    addonId = "addon:${manifest.id}",
                                    addonLogo = manifest.logoUrl,
                                )
                            } ?: run { failure = "Timed out"; emptyList() }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Throwable) {
                            failure = e.message ?: "Failed"
                            emptyList()
                        }
                        groups[manifest.transportUrl] = MacStreamGroup(manifest.id, manifest.name, manifest.logoUrl, false, failure, streams)
                        onGroups(groups.values.toList())
                    }
                }
            }
            onDone()
        }
    }

    fun cancelStreams() { streamsJob?.cancel() }
}
