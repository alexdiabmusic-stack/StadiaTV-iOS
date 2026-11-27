package com.nuvio.app.mac

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.putSyncOriginClientId
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.profiles.AvatarCatalogItem
import com.nuvio.app.features.profiles.NuvioProfile
import com.nuvio.app.features.profiles.PinVerifyResult
import com.nuvio.app.features.profiles.avatarImageUrl
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import platform.Foundation.NSDate
import platform.Foundation.NSUserDefaults
import platform.Foundation.timeIntervalSince1970

// The wire formats below are the account backend's contract (the same rows the phone and TV apps read and write).

/** A resume point for one movie or episode. Times are milliseconds. */
@Serializable
data class MacProgress(
    @SerialName("content_id") val contentId: String,
    @SerialName("content_type") val contentType: String,
    @SerialName("video_id") val videoId: String,
    val season: Int? = null,
    val episode: Int? = null,
    val position: Long = 0,
    val duration: Long = 0,
    @SerialName("last_watched") val lastWatched: Long = 0,
    @SerialName("progress_key") val progressKey: String = "",
) {
    val fraction: Double get() = if (duration > 0) position.toDouble() / duration else 0.0
    val isComplete: Boolean get() = fraction >= 0.90
}

/** A title saved to the person's library. */
@Serializable
data class MacLibraryItem(
    @SerialName("content_id") val contentId: String,
    @SerialName("content_type") val contentType: String,
    val name: String = "",
    val poster: String? = null,
    @SerialName("poster_shape") val posterShape: String = "POSTER",
    val background: String? = null,
    val logo: String? = null,
    val description: String? = null,
    @SerialName("release_info") val releaseInfo: String? = null,
    @SerialName("imdb_rating") val imdbRating: Float? = null,
    val genres: List<String> = emptyList(),
    @SerialName("addon_base_url") val addonBaseUrl: String? = null,
    @SerialName("added_at") val addedAt: Long = 0,
)

/** A movie or episode marked as watched. */
@Serializable
data class MacWatched(
    @SerialName("content_id") val contentId: String,
    @SerialName("content_type") val contentType: String,
    val title: String = "",
    val season: Int? = null,
    val episode: Int? = null,
    @SerialName("watched_at") val watchedAt: Long = 0,
) {
    val key: String get() = progressKey(contentId, season, episode)
}

@Serializable
private data class HomeSettingsBlob(
    @SerialName("profile_id") val profileId: Int = 1,
    @SerialName("settings_json") val settingsJson: JsonObject = JsonObject(emptyMap()),
)

@Serializable
private data class LibraryKey(
    @SerialName("content_id") val contentId: String,
    @SerialName("content_type") val contentType: String,
)

@Serializable
private data class WatchedKey(
    @SerialName("content_id") val contentId: String,
    val season: Int? = null,
    val episode: Int? = null,
)

/** How one Home catalog is arranged on the person's other devices. */
class MacCatalogPref(val key: String, val enabled: Boolean, val order: Int, val customTitle: String)

/** The profile's Home arrangement, shared with the phone and TV apps. */
class MacHomeSettings(
    val catalogs: Map<String, MacCatalogPref> = emptyMap(),
    val rowOrder: List<String> = emptyList(),
    val showCatalogType: Boolean = true,
)

internal fun progressKey(contentId: String, season: Int?, episode: Int?): String =
    if (season != null && episode != null) "${contentId}_s${season}e${episode}" else contentId

internal fun nowMs(): Long = (NSDate().timeIntervalSince1970 * 1000).toLong()

/**
 * The signed-in person's profiles, watch progress, library and watched history for the active profile.
 *
 * Signed in: the backend is the source of truth and every change is pushed to it. Signed out (anonymous): everything
 * is kept on this Mac only. Either way the last known state is cached on disk so the app opens with it.
 */
object MacAccountData {
    private val scope = macScope()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val defaults get() = NSUserDefaults.standardUserDefaults

    private val _profiles = MutableStateFlow<List<NuvioProfile>>(emptyList())
    val profiles: StateFlow<List<NuvioProfile>> = _profiles
    private val _profilesLoaded = MutableStateFlow(false)
    val profilesLoaded: StateFlow<Boolean> = _profilesLoaded

    private val _avatars = MutableStateFlow<Map<String, String>>(emptyMap())
    /** Avatar id to image URL, from the backend's avatar catalog. */
    val avatars: StateFlow<Map<String, String>> = _avatars

    suspend fun loadAvatars() {
        runCatching {
            SupabaseProvider.client.postgrest.rpc("get_avatar_catalog").decodeList<AvatarCatalogItem>()
        }.onSuccess { items ->
            _avatars.value = items.mapNotNull { item -> avatarImageUrl(item)?.let { item.id to it } }.toMap()
        }.onFailure { if (it is CancellationException) throw it }
    }

    private val _homeSettings = MutableStateFlow(MacHomeSettings())
    val homeSettings: StateFlow<MacHomeSettings> = _homeSettings
    private var homeSettingsJson: JsonObject = JsonObject(emptyMap())

    private suspend fun pullHomeSettings(profile: Int) {
        val blob = SupabaseProvider.client.postgrest.rpc("sync_pull_home_catalog_settings", buildJsonObject {
            put("p_profile_id", profile); put("p_platform", "home_catalog_shared")
        }).decodeList<HomeSettingsBlob>().firstOrNull()
        homeSettingsJson = blob?.settingsJson ?: JsonObject(emptyMap())
        val items = (homeSettingsJson["items"] as? JsonArray).orEmpty().mapNotNull { element ->
            val o = element as? JsonObject ?: return@mapNotNull null
            val key = o["key"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            MacCatalogPref(
                key = key,
                enabled = o["enabled"]?.jsonPrimitive?.booleanOrNull ?: true,
                order = o["order"]?.jsonPrimitive?.intOrNull ?: 0,
                customTitle = o["custom_title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            )
        }
        _homeSettings.value = MacHomeSettings(
            catalogs = items.associateBy { it.key },
            rowOrder = (homeSettingsJson["row_order"] as? JsonArray).orEmpty().mapNotNull { it.jsonPrimitive.contentOrNull },
            showCatalogType = homeSettingsJson["show_catalog_type"]?.jsonPrimitive?.booleanOrNull ?: true,
        )
    }

    /** Saves the Home row order for the profile (and so for its other devices), keeping every other Home setting as is. */
    fun saveRowOrder(order: List<String>) {
        val profile = activeProfileIndex
        _homeSettings.value = MacHomeSettings(_homeSettings.value.catalogs, order, _homeSettings.value.showCatalogType)
        defaults.setObject(order.joinToString("\n"), forKey = "mac_roworder_${owner()}_$profile")
        push {
            pullHomeSettings(profile) // start from the latest settings so nothing another device changed is lost
            val merged = JsonObject(homeSettingsJson + ("row_order" to JsonArray(order.map { JsonPrimitive(it) })))
            SupabaseProvider.client.postgrest.rpc("sync_push_home_catalog_settings", buildJsonObject {
                put("p_profile_id", profile)
                put("p_platform", "home_catalog_shared")
                put("p_settings_json", merged)
                putSyncOriginClientId()
            })
            homeSettingsJson = merged
            _homeSettings.value = MacHomeSettings(_homeSettings.value.catalogs, order, _homeSettings.value.showCatalogType)
        }
    }

    private val _progress = MutableStateFlow<List<MacProgress>>(emptyList())
    val progress: StateFlow<List<MacProgress>> = _progress
    private val _library = MutableStateFlow<List<MacLibraryItem>>(emptyList())
    val library: StateFlow<List<MacLibraryItem>> = _library
    private val _watched = MutableStateFlow<List<MacWatched>>(emptyList())
    val watched: StateFlow<List<MacWatched>> = _watched

    var activeProfileIndex: Int
        get() = defaults.integerForKey("mac_active_profile").toInt().takeIf { it > 0 } ?: 1
        private set(value) { defaults.setInteger(value.toLong(), forKey = "mac_active_profile") }

    val activeProfile: NuvioProfile? get() = _profiles.value.firstOrNull { it.profileIndex == activeProfileIndex }

    val isSynced: Boolean
        get() = (AuthRepository.state.value as? AuthState.Authenticated)?.let { !it.isAnonymous } == true

    // ---- profiles -----------------------------------------------------------------------------------------------

    suspend fun pullProfiles(): String? = try {
        if (!isSynced) {
            _profiles.value = listOf(localProfile())
        } else {
            val list = SupabaseProvider.client.postgrest.rpc("sync_pull_profiles").decodeList<NuvioProfile>()
            _profiles.value = list.sortedBy { it.profileIndex }
            defaults.setObject(json.encodeToString(_profiles.value), forKey = "mac_profiles_${owner()}")
            loadAvatars()
        }
        _profilesLoaded.value = true
        null
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        // Offline or the backend is unreachable: fall back to the profiles last seen for this account.
        val cached = defaults.stringForKey("mac_profiles_${owner()}")
            ?.let { runCatching { json.decodeFromString<List<NuvioProfile>>(it) }.getOrNull() }.orEmpty()
        if (cached.isNotEmpty()) _profiles.value = cached
        _profilesLoaded.value = true
        if (cached.isNotEmpty()) null else (e.message ?: "Unable to load profiles")
    }

    /** Checks a profile's PIN with the backend: `null` on success, otherwise the message to show. */
    suspend fun verifyPin(profileIndex: Int, pin: String): String? = try {
        val result = SupabaseProvider.client.postgrest.rpc("verify_profile_pin", buildJsonObject {
            put("p_profile_id", profileIndex); put("p_pin", pin)
        }).decodeSingle<PinVerifyResult>()
        when {
            result.unlocked -> null
            result.retryAfterSeconds > 0 -> "Too many attempts. Try again in ${result.retryAfterSeconds} seconds."
            else -> result.message ?: "Incorrect PIN"
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        "Unable to check the PIN right now"
    }

    private fun localProfile() = NuvioProfile(id = "local", profileIndex = 1, name = "Me")

    /** Makes [index] the active profile: switches add-ons, loads its cached data, then refreshes from the backend. */
    suspend fun selectProfile(index: Int) {
        activeProfileIndex = index
        AddonRepository.onProfileChanged(index)
        AddonRepository.initialize()
        loadLocal()
        if (isSynced) {
            runCatching { AddonRepository.pullFromServer(index) }
            refreshAll()
        }
    }

    fun clearForSignOut() {
        _profiles.value = emptyList()
        _profilesLoaded.value = false
        _avatars.value = emptyMap()
        _progress.value = emptyList(); _library.value = emptyList(); _watched.value = emptyList()
        _homeSettings.value = MacHomeSettings()
        homeSettingsJson = JsonObject(emptyMap())
        MacContent.clearCaches()
    }

    /** Removes everything this Mac kept for the account that is signing out (cached data and its add-on list). */
    fun wipeLocalData(accountUserId: String?) {
        val owner = accountUserId ?: owner()
        val keys = defaults.dictionaryRepresentation().keys.map { it.toString() }
        keys.filter { it.startsWith("mac_") && it.contains("_${owner}_") || it == "mac_profiles_$owner" ||
            (it.startsWith("installed_manifest_") && it.contains("_${owner}_")) }
            .forEach { defaults.removeObjectForKey(it) }
        defaults.removeObjectForKey("mac_active_profile")
        clearForSignOut()
    }

    // ---- local cache ---------------------------------------------------------------------------------------------

    /** Cached data belongs to one account (or to "local" when there is none), so another person signing in never sees it. */
    internal fun owner(): String = (AuthRepository.state.value as? AuthState.Authenticated)?.userId ?: "local"

    private fun cacheKey(kind: String) = "mac_${kind}_${owner()}_${activeProfileIndex}"

    private inline fun <reified T> readCache(kind: String): List<T> =
        defaults.stringForKey(cacheKey(kind))?.let { runCatching { json.decodeFromString<List<T>>(it) }.getOrNull() }.orEmpty()

    private inline fun <reified T> writeCache(kind: String, value: List<T>) {
        defaults.setObject(json.encodeToString(value), forKey = cacheKey(kind))
    }

    fun loadLocal() {
        val savedOrder = defaults.stringForKey("mac_roworder_${owner()}_${activeProfileIndex}")?.split("\n")?.filter { it.isNotBlank() }.orEmpty()
        if (savedOrder.isNotEmpty() && !isSynced) _homeSettings.value = MacHomeSettings(rowOrder = savedOrder)
        _progress.value = readCache<MacProgress>("progress")
        _library.value = readCache<MacLibraryItem>("library")
        _watched.value = readCache<MacWatched>("watched")
    }

    // ---- backend ---------------------------------------------------------------------------------------------------

    /** Pulls progress, library and watched for the active profile and replaces the local copy. */
    suspend fun refreshAll(): String? {
        if (!isSynced) return null
        val profile = activeProfileIndex
        val account = owner()
        // The person may switch profile or account while this runs; a late answer is dropped rather than shown under the wrong one.
        fun current() = profile == activeProfileIndex && account == owner()
        return try {
            val progress = SupabaseProvider.client.postgrest
                .rpc("sync_pull_watch_progress", buildJsonObject { put("p_profile_id", profile) })
                .decodeList<MacProgress>().sortedByDescending { it.lastWatched }

            val library = buildList {
                var offset = 0
                while (true) {
                    val page = SupabaseProvider.client.postgrest.rpc("sync_pull_library", buildJsonObject {
                        put("p_profile_id", profile); put("p_limit", 500); put("p_offset", offset)
                    }).decodeList<MacLibraryItem>()
                    addAll(page)
                    if (page.size < 500) break
                    offset += 500
                }
            }.sortedByDescending { it.addedAt }

            val watched = buildList {
                var page = 1
                while (true) {
                    val items = SupabaseProvider.client.postgrest.rpc("sync_pull_watched_items", buildJsonObject {
                        put("p_profile_id", profile); put("p_page", page); put("p_page_size", 1000)
                    }).decodeList<MacWatched>()
                    addAll(items)
                    if (items.size < 1000) break
                    page += 1
                }
            }
            if (!current()) return null
            _progress.value = progress; writeCache("progress", progress)
            _library.value = library; writeCache("library", library)
            _watched.value = watched; writeCache("watched", watched)
            runCatching { pullHomeSettings(profile) }.onFailure { if (it is CancellationException) throw it }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (AuthRepository.signOutIfSessionInvalid(e, "Account data pull")) "Signed out" else e.message ?: "Unable to refresh"
        }
    }

    private fun push(block: suspend () -> Unit) {
        if (!isSynced) return
        scope.launch { runCatching { block() }.onFailure { if (it is CancellationException) throw it } }
    }

    fun recordProgress(entry: MacProgress) {
        val keyed = entry.copy(progressKey = progressKey(entry.contentId, entry.season, entry.episode), lastWatched = nowMs())
        _progress.value = (listOf(keyed) + _progress.value.filterNot { it.progressKey == keyed.progressKey })
            .sortedByDescending { it.lastWatched }
        writeCache("progress", _progress.value)
        val profile = activeProfileIndex
        push {
            SupabaseProvider.client.postgrest.rpc("sync_push_watch_progress", buildJsonObject {
                put("p_profile_id", profile)
                put("p_entries", json.encodeToJsonElement(listOf(keyed)))
                putSyncOriginClientId()
            })
        }
    }

    fun removeProgress(contentId: String) {
        val gone = _progress.value.filter { it.contentId == contentId }
        if (gone.isEmpty()) return
        _progress.value = _progress.value.filterNot { it.contentId == contentId }
        writeCache("progress", _progress.value)
        val profile = activeProfileIndex
        push {
            SupabaseProvider.client.postgrest.rpc("sync_delete_watch_progress", buildJsonObject {
                put("p_profile_id", profile)
                put("p_keys", json.encodeToJsonElement(gone.map { it.progressKey }))
                putSyncOriginClientId()
            })
        }
    }

    fun isInLibrary(contentId: String, contentType: String): Boolean =
        _library.value.any { it.contentId == contentId && it.contentType == contentType }

    fun setSaved(item: MacLibraryItem, saved: Boolean) {
        val profile = activeProfileIndex
        if (saved) {
            val stamped = item.copy(addedAt = nowMs())
            _library.value = listOf(stamped) + _library.value.filterNot { it.contentId == item.contentId && it.contentType == item.contentType }
            push {
                SupabaseProvider.client.postgrest.rpc("sync_push_library_items", buildJsonObject {
                    put("p_profile_id", profile)
                    put("p_items", json.encodeToJsonElement(listOf(stamped)))
                    putSyncOriginClientId()
                })
            }
        } else {
            _library.value = _library.value.filterNot { it.contentId == item.contentId && it.contentType == item.contentType }
            push {
                SupabaseProvider.client.postgrest.rpc("sync_delete_library_items", buildJsonObject {
                    put("p_profile_id", profile)
                    put("p_keys", json.encodeToJsonElement(listOf(LibraryKey(item.contentId, item.contentType))))
                    putSyncOriginClientId()
                })
            }
        }
        writeCache("library", _library.value)
    }

    /** Saves several titles to My List in one request. The first gets the latest time, so the list keeps the order given. */
    fun saveAll(items: List<MacLibraryItem>) {
        if (items.isEmpty()) return
        val profile = activeProfileIndex
        val base = nowMs()
        val stamped = items.mapIndexed { i, it -> it.copy(addedAt = base - i * 1_000L) }
        val keys = stamped.map { it.contentId to it.contentType }.toSet()
        _library.value = stamped + _library.value.filterNot { (it.contentId to it.contentType) in keys }
        push {
            SupabaseProvider.client.postgrest.rpc("sync_push_library_items", buildJsonObject {
                put("p_profile_id", profile)
                put("p_items", json.encodeToJsonElement(stamped))
                putSyncOriginClientId()
            })
        }
        writeCache("library", _library.value)
    }

    fun isWatched(contentId: String, season: Int?, episode: Int?): Boolean =
        _watched.value.any { it.key == progressKey(contentId, season, episode) }

    /** [keepDates]: the items carry the time they were really watched (an import) and must not be re-stamped with now. */
    fun setWatched(items: List<MacWatched>, watched: Boolean, keepDates: Boolean = false) {
        if (items.isEmpty()) return
        val profile = activeProfileIndex
        val keys = items.map { it.key }.toSet()
        if (watched) {
            val stamped = if (keepDates) items else items.map { it.copy(watchedAt = nowMs()) }
            _watched.value = stamped + _watched.value.filterNot { it.key in keys }
            push {
                SupabaseProvider.client.postgrest.rpc("sync_push_watched_items", buildJsonObject {
                    put("p_profile_id", profile)
                    put("p_items", json.encodeToJsonElement(stamped))
                    putSyncOriginClientId()
                })
            }
        } else {
            _watched.value = _watched.value.filterNot { it.key in keys }
            push {
                SupabaseProvider.client.postgrest.rpc("sync_delete_watched_items", buildJsonObject {
                    put("p_profile_id", profile)
                    put("p_keys", json.encodeToJsonElement(items.map { WatchedKey(it.contentId, it.season, it.episode) }))
                    putSyncOriginClientId()
                })
            }
        }
        writeCache("watched", _watched.value)
    }
}
