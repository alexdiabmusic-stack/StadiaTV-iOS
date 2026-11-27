package com.nuvio.app.mac

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.text.CoreText
import com.nuvio.app.features.addons.AddAddonResult
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.home.stableKey
import com.nuvio.app.features.home.HomeRowIds
import com.nuvio.app.features.home.HomeRowOrder
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.buildHomeCatalogDefinitions
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/** A running observation of a core value; call [cancel] when the Swift view goes away. */
class MacWatch internal constructor(private val job: Job) {
    fun cancel() = job.cancel()
}

/** What the Mac UI needs to know about the account, without Kotlin's sealed types leaking into Swift. */
class MacAccount(val phase: String, val userId: String?, val email: String?, val isAnonymous: Boolean)

/** One Home row: a titled catalog from an add-on. */
class MacHomeRow(val key: String, val rowId: String, val title: String, val addonName: String, val items: List<MetaPreview>)

/**
 * The surface the SwiftUI app talks to. Observations are delivered on the main thread; one-shot calls report back
 * with `null` for success or the message to show the person.
 */
object MacBridge {
    private val scope = macScope()

    private fun <T> Flow<T>.watch(onEach: (T) -> Unit): MacWatch =
        MacWatch(scope.launch { collect { value -> onEach(value) } })

    fun watchAccount(onChange: (MacAccount) -> Unit): MacWatch {
        AuthRepository.initialize()
        return AuthRepository.state.watch { state ->
            onChange(
                when (state) {
                    AuthState.Loading -> MacAccount("loading", null, null, false)
                    AuthState.Unauthenticated -> MacAccount("signedOut", null, null, false)
                    is AuthState.Authenticated -> MacAccount("signedIn", state.userId, state.email, state.isAnonymous)
                },
            )
        }
    }

    fun watchAccountError(onChange: (String?) -> Unit): MacWatch = AuthRepository.error.watch(onChange)

    fun watchAddons(onChange: (List<ManagedAddon>) -> Unit): MacWatch {
        AddonRepository.initialize()
        return AddonRepository.uiState.watch { onChange(it.addons) }
    }

    fun signIn(email: String, password: String, done: (String?) -> Unit) {
        scope.launch {
            val result = AuthRepository.signInWithEmail(email.trim(), password)
            done(result.exceptionOrNull()?.message)
        }
    }

    fun signOut(done: (String?) -> Unit) {
        scope.launch {
            val result = AuthRepository.signOut()
            AddonRepository.clearLocalState()
            MacAccountData.clearForSignOut()
            done(result.exceptionOrNull()?.message)
        }
    }

    /** Loads the signed-in account's add-ons for the given profile into the local list. */
    fun pullAddons(profileId: Int, done: (String?) -> Unit) {
        scope.launch {
            try {
                AddonRepository.onProfileChanged(profileId)
                AddonRepository.initialize()
                AddonRepository.pullFromServer(profileId)
                done(null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                done(e.message ?: "Unable to load add-ons")
            }
        }
    }

    fun addAddon(url: String, done: (String?) -> Unit) {
        scope.launch {
            when (val result = AddonRepository.addAddon(url)) {
                is AddAddonResult.Success -> done(null)
                is AddAddonResult.Error -> done(result.message)
            }
        }
    }

    fun removeAddon(manifestUrl: String) = AddonRepository.removeAddon(manifestUrl)

    fun setAddonEnabled(manifestUrl: String, enabled: Boolean) = AddonRepository.setAddonEnabled(manifestUrl, enabled)

    fun refreshAddons() = AddonRepository.refreshAll()

    private var homeJob: Job? = null

    /**
     * Fetches the enabled add-ons' catalogs for Home, six at a time, and reports the rows loaded so far (in the add-ons'
     * own order) as each one arrives. Uses the same definitions and fetch/parse code as the phone apps.
     */
    /** What is left of a Home row after the first screenful, and where to ask for the next page (rows are endless). */
    private class RowPager(val definition: com.nuvio.app.features.home.HomeCatalogDefinition) {
        val buffer = ArrayDeque<MetaPreview>()
        val seen = HashSet<String>()
        var nextSkip: Int? = null
        var duplicatePages = 0
        var loading = false
    }

    private val rowPagers = HashMap<String, RowPager>()

    /**
     * The next titles of a Home row: from what the last page already held, or from the add-on's next page. [done] gets
     * the titles and whether more can still be asked for.
     */
    fun loadMoreHome(key: String, count: Int, done: (List<MetaPreview>, Boolean) -> Unit) {
        val pager = rowPagers[key]
        if (pager == null || pager.loading) { done(emptyList(), pager != null); return }
        pager.loading = true
        scope.launch {
            var guard = 0
            while (pager.buffer.size < count && pager.nextSkip != null && guard < 3) {
                guard++
                val skip = pager.nextSkip ?: break
                val page = runCatching {
                    withTimeoutOrNull(30_000) {
                        fetchCatalogPage(pager.definition.manifestUrl, pager.definition.type, pager.definition.catalogId, skip = skip)
                    }
                }.getOrNull()
                if (page == null) break
                val fresh = page.items.filter { pager.seen.add(it.stableKey()) }
                fresh.forEach { pager.buffer.addLast(it) }
                val state = com.nuvio.app.features.catalog.nextCatalogPaginationState(
                    supportsPagination = pager.definition.supportsPagination, requestedSkip = skip, page = page,
                    loadedNewItems = fresh.isNotEmpty(), consecutiveDuplicatePages = pager.duplicatePages,
                )
                pager.nextSkip = state.nextSkip
                pager.duplicatePages = state.consecutiveDuplicatePages
            }
            val out = ArrayList<MetaPreview>()
            while (out.size < count && pager.buffer.isNotEmpty()) out += pager.buffer.removeFirst()
            pager.loading = false
            done(out, pager.buffer.isNotEmpty() || pager.nextSkip != null)
        }
    }

    /** More titles for one of Home's TMDB rows (curated, personal, recommended); [shownIds] are the ids already on Home. */
    fun loadMoreCurated(key: String, shownIds: List<String>, done: (List<MetaPreview>) -> Unit) {
        scope.launch {
            val rec = com.nuvio.app.features.recommendations.RecommendationEngine.state.value
            val trending = com.nuvio.app.features.home.HomeTrendingRepository.state.value
            val base = when {
                key == "recommended" -> rec.items
                else -> trending.rows.firstOrNull { it.key == key }?.items
                    ?: rec.rows.firstOrNull { HomeRowIds.personal(it.kind.name) == key }?.items
                    ?: emptyList()
            }
            val more = if (base.isEmpty()) emptyList() else runCatching {
                com.nuvio.app.features.home.HomeTrendingRepository.loadMore(key, base, shownIds.toSet())
            }.getOrDefault(emptyList())
            done(more)
        }
    }

    fun loadHome(previewLimit: Int, onRows: (List<MacHomeRow>) -> Unit, onDone: () -> Unit) {
        homeJob?.cancel()
        rowPagers.clear()
        homeJob = scope.launch {
            AddonRepository.awaitManifestsLoaded()
            val settings = MacAccountData.homeSettings.value
            val definitions = buildHomeCatalogDefinitions(AddonRepository.uiState.value.addons.enabledAddons())
                .filter { it.manifestUrl.isNotBlank() && settings.catalogs[it.key]?.enabled != false }
                .sortedBy { settings.catalogs[it.key]?.order ?: Int.MAX_VALUE }
            val loaded = HashMap<String, MacHomeRow>()
            val permits = Semaphore(6)
            fun publish() = onRows(definitions.mapNotNull { loaded[it.key] })
            kotlinx.coroutines.coroutineScope {
                definitions.forEach { definition ->
                    launch {
                        val page = permits.withPermit {
                            runCatching {
                                withTimeoutOrNull(30_000) {
                                    fetchCatalogPage(
                                        manifestUrl = definition.manifestUrl,
                                        type = definition.type,
                                        catalogId = definition.catalogId,
                                    )
                                }
                            }.getOrNull()
                        }
                        if (page != null && page.items.isNotEmpty()) {
                            // The first screenful is shown; the rest of the page and the pages after it feed the endless row.
                            val pager = RowPager(definition)
                            page.items.forEach { pager.seen.add(it.stableKey()) }
                            page.items.drop(previewLimit).forEach { pager.buffer.addLast(it) }
                            pager.nextSkip = if (definition.supportsPagination) page.nextSkip else null
                            rowPagers[definition.key] = pager
                            loaded[definition.key] = MacHomeRow(
                                key = definition.key,
                                rowId = HomeRowIds.catalog(definition.key),
                                title = settings.catalogs[definition.key]?.customTitle?.takeIf { it.isNotBlank() }
                                    ?: definition.titleFor(settings.showCatalogType),
                                addonName = definition.addonName,
                                items = page.items.take(previewLimit),
                            )
                            publish()
                        }
                    }
                }
            }
            onDone()
        }
    }

    // ---- profiles and account data -------------------------------------------------------------------------------

    fun watchProfiles(onChange: (List<com.nuvio.app.features.profiles.NuvioProfile>) -> Unit): MacWatch =
        MacAccountData.profiles.watch(onChange)

    fun watchAvatars(onChange: (Map<String, String>) -> Unit): MacWatch = MacAccountData.avatars.watch(onChange)

    fun continueAnonymously() = AuthRepository.signInAnonymously()

    fun clearAccountData() = MacAccountData.clearForSignOut()

    fun watchProfilesLoaded(onChange: (Boolean) -> Unit): MacWatch = MacAccountData.profilesLoaded.watch(onChange)

    fun pullProfiles(done: (String?) -> Unit) { scope.launch { done(MacAccountData.pullProfiles()) } }

    fun selectProfile(index: Int, done: () -> Unit) { scope.launch { MacAccountData.selectProfile(index); done() } }

    val activeProfileIndex: Int get() = MacAccountData.activeProfileIndex

    fun refreshAccountData(done: (String?) -> Unit) { scope.launch { done(MacAccountData.refreshAll()) } }

    fun watchHomeSettings(onChange: (MacHomeSettings) -> Unit): MacWatch = MacAccountData.homeSettings.watch(onChange)
    fun saveRowOrder(order: List<String>) = MacAccountData.saveRowOrder(order)

    /** [ids] in the person's saved order (rows the order does not mention keep their place). */
    fun orderRows(ids: List<String>, saved: List<String>): List<String> = HomeRowOrder.apply(ids, saved) { it }

    /** The order to store after the person arranged [visible], preserving rows only other devices know. */
    fun rowOrderToSave(saved: List<String>, visible: List<String>): List<String> = HomeRowOrder.toSave(saved, visible)
    fun exploreRowId(): String = HomeRowIds.EXPLORE

    fun startDiscovery() = MacDiscovery.start()
    fun watchDiscovery(onChange: (MacDiscoveryState) -> Unit): MacWatch = MacDiscovery.watch(onChange)

    fun markLiveWatched(channelId: String) = MacLiveTv.markWatched(channelId)

    fun watchLiveTv(onChange: (MacLiveTvState) -> Unit): MacWatch = MacLiveTv.state.watch(onChange)
    fun watchLiveFavorites(onChange: (Set<String>) -> Unit): MacWatch = MacLiveTv.favorites.watch(onChange)
    fun watchLiveRecents(onChange: (List<String>) -> Unit): MacWatch = MacLiveTv.recents.watch(onChange)

    fun watchContinue(onChange: (List<MacContinueItem>) -> Unit): MacWatch = MacContinue.watch(onChange)
    fun watchProgress(onChange: (List<MacProgress>) -> Unit): MacWatch = MacAccountData.progress.watch(onChange)
    fun verifyPin(index: Int, pin: String, done: (String?) -> Unit) { scope.launch { done(MacAccountData.verifyPin(index, pin)) } }
    fun watchLibrary(onChange: (List<MacLibraryItem>) -> Unit): MacWatch = MacAccountData.library.watch(onChange)
    fun watchWatched(onChange: (List<MacWatched>) -> Unit): MacWatch = MacAccountData.watched.watch(onChange)

    fun recordProgress(
        contentId: String, contentType: String, videoId: String, season: Int?, episode: Int?, positionMs: Long, durationMs: Long,
    ) {
        MacAccountData.recordProgress(MacProgress(contentId, contentType, videoId, season, episode, positionMs, durationMs))
    }

    fun removeFromContinue(contentId: String) = MacAccountData.removeProgress(contentId)

    fun isSaved(contentId: String, contentType: String): Boolean = MacAccountData.isInLibrary(contentId, contentType)

    fun setSaved(
        contentId: String, contentType: String, name: String, poster: String?, background: String?, logo: String?,
        description: String?, releaseInfo: String?, imdbRating: String?, genres: List<String>, saved: Boolean,
    ) {
        MacAccountData.setSaved(
            MacLibraryItem(contentId, contentType, name, poster, "POSTER", background, logo, description, releaseInfo,
                imdbRating?.toFloatOrNull(), genres),
            saved,
        )
    }

    fun setWatched(contentId: String, contentType: String, title: String, season: Int?, episode: Int?, watched: Boolean) {
        MacAccountData.setWatched(listOf(MacWatched(contentId, contentType, title, season, episode)), watched)
    }

    fun signedInForSync(): Boolean = MacAccountData.isSynced

    private var searchJob: Job? = null

    /**
     * Searches every installed add-on catalog that accepts a search, reporting one row per catalog that found
     * something (in the add-ons' own order) as results arrive.
     */
    fun search(query: String, onRows: (List<MacHomeRow>) -> Unit, onDone: () -> Unit) {
        searchJob?.cancel()
        val text = query.trim()
        if (text.isEmpty()) { onRows(emptyList()); onDone(); return }
        searchJob = scope.launch {
            AddonRepository.awaitManifestsLoaded()
            data class Target(val manifestUrl: String, val addon: String, val type: String, val id: String, val name: String)
            val targets = AddonRepository.uiState.value.addons.enabledAddons().flatMap { addon ->
                val manifest = addon.manifest ?: return@flatMap emptyList<Target>()
                manifest.catalogs
                    .filter { c -> c.extra.any { it.name == "search" } && c.extra.none { it.isRequired && it.name != "search" } }
                    .map { c -> Target(addon.manifestUrl, addon.displayTitle, c.type, c.id, c.name) }
            }
            val found = HashMap<String, MacHomeRow>()
            val permits = Semaphore(6)
            kotlinx.coroutines.coroutineScope {
                targets.forEach { t ->
                    launch {
                        val page = permits.withPermit {
                            runCatching {
                                withTimeoutOrNull(20_000) {
                                    fetchCatalogPage(manifestUrl = t.manifestUrl, type = t.type, catalogId = t.id, search = text, maxItems = 30)
                                }
                            }.getOrNull()
                        }
                        if (page != null && page.items.isNotEmpty()) {
                            val key = "${t.manifestUrl}|${t.type}|${t.id}"
                            found[key] = MacHomeRow(key, "search:$key", "${t.name} - ${CoreText.mediaTypeLabel(t.type)}", t.addon, page.items)
                            onRows(targets.mapNotNull { x -> found["${x.manifestUrl}|${x.type}|${x.id}"] })
                        }
                    }
                }
            }
            onDone()
        }
    }
}
