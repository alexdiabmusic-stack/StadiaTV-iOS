package com.nuvio.app

import com.nuvio.app.core.build.AppVersionConfig
import com.nuvio.app.core.network.SupabaseConfig
import com.nuvio.app.core.i18n.localizedMediaTypeLabel
import com.nuvio.app.core.platform.AccountDataWiper
import com.nuvio.app.core.platform.CoreConfig
import com.nuvio.app.core.platform.CoreRuntime
import com.nuvio.app.core.platform.ProfileContext
import com.nuvio.app.core.storage.LocalAccountDataCleaner
import com.nuvio.app.core.text.CoreText
import com.nuvio.app.core.network.createApiHttpClient
import com.nuvio.app.features.home.HomeCatalogExtras
import com.nuvio.app.features.livetv.LiveTvHttp
import com.nuvio.app.features.music.data.MusicStorage
import com.nuvio.app.features.tmdb.CoreClock
import com.nuvio.app.features.tmdb.CoreKeyValue
import com.nuvio.app.features.tmdb.TmdbRuntime
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.servers.ServerCatalog
import nuvio.composeapp.generated.resources.*
import org.jetbrains.compose.resources.StringResource
import org.jetbrains.compose.resources.getString

/** Registers this platform's storage, HTTP and feature policy with the shared core (bannerCore). */
internal expect fun registerPlatformBackends()

private var coreInstalled = false

/**
 * Connects the shared core to this app: build configuration, the active profile, local data wiping, the string resources
 * and the platform backends. Safe to call more than once; must run before the core is used.
 */
fun installBannerCore() {
    if (coreInstalled) return
    coreInstalled = true
    CoreRuntime.config = CoreConfig(
        supabaseUrl = SupabaseConfig.URL,
        supabaseAnonKey = SupabaseConfig.ANON_KEY,
        supabaseFallbackUrl = SupabaseConfig.FALLBACK_URL,
        appVersionName = AppVersionConfig.VERSION_NAME,
    )
    CoreRuntime.profileContext = object : ProfileContext {
        override val activeProfileId: Int get() = ProfileRepository.activeProfileId
        override val usesPrimaryAddonsFromSecondaryProfile: Boolean
            get() = ProfileRepository.state.value.activeProfile
                ?.let { it.profileIndex != 1 && it.usesPrimaryAddons } == true
    }
    CoreRuntime.accountDataWiper = AccountDataWiper { userId -> LocalAccountDataCleaner.wipe(userId) }
    CoreText.resolver = { string, args ->
        coreStringResources[string.id]?.let { resource -> getString(resource, *args.toTypedArray()) }
    }
    LiveTvHttp.clientFactory = ::createApiHttpClient
    TmdbRuntime.apiKey = { TmdbSettingsRepository.effectiveApiKey() }
    TmdbRuntime.language = { TmdbSettingsRepository.snapshot().language }
    CoreClock.todayProvider = { CurrentDateProvider.todayIsoDate() }
    CoreKeyValue.backend = object : CoreKeyValue.Backend {
        override fun getString(store: String, key: String): String? = MusicStorage.getString(store, key)
        override fun putString(store: String, key: String, value: String) { MusicStorage.putString(store, key, value) }
    }
    CoreText.mediaTypeResolver = ::localizedMediaTypeLabel
    HomeCatalogExtras.provider = { ServerCatalog.homeDefinitions() }
    registerPlatformBackends()
    installSportsHost()
}

private val coreStringResources: Map<String, StringResource> = mapOf(
    "auth_sign_up_failed" to Res.string.auth_sign_up_failed,
    "auth_sign_in_failed" to Res.string.auth_sign_in_failed,
    "auth_sign_out_failed" to Res.string.auth_sign_out_failed,
    "auth_account_deletion_failed" to Res.string.auth_account_deletion_failed,
    "generic_addon" to Res.string.generic_addon,
    "addons_manifest_missing_field" to Res.string.addons_manifest_missing_field,
    "profile_primary_addons_required" to Res.string.profile_primary_addons_required,
    "addon_invalid_url" to Res.string.addon_invalid_url,
    "addon_already_installed" to Res.string.addon_already_installed,
    "addon_load_manifest_failed" to Res.string.addon_load_manifest_failed,
    "addons_error_enter_url" to Res.string.addons_error_enter_url,
    "catalog_load_failed" to Res.string.catalog_load_failed,
    "updates_github_api_error" to Res.string.updates_github_api_error,
    "home_catalog_default_title" to Res.string.home_catalog_default_title,
    "generic_trailer" to Res.string.generic_trailer,
    "source_embedded" to Res.string.source_embedded,
    "details_runtime_hours_minutes" to Res.string.details_runtime_hours_minutes,
    "details_runtime_hours_only" to Res.string.details_runtime_hours_only,
    "details_runtime_minutes_only" to Res.string.details_runtime_minutes_only,
    "network_request_failed_http" to Res.string.network_request_failed_http,
    "network_empty_response_body" to Res.string.network_empty_response_body,
)
