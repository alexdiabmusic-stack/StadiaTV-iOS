package com.nuvio.app.core.text

/**
 * A user-facing message the shared core can produce (an error from sign-in, an add-on that failed to load...).
 * Each carries its English text; the host app may translate it by registering a [CoreText.resolver] keyed on [id]
 * (the iPhone and Android apps resolve these from their string resources, the Mac app uses the English text).
 * Placeholders are written `%1$s` / `%1$d`.
 */
class CoreString(val id: String, val english: String)

object CoreStrings {
    val authSignUpFailed = CoreString("auth_sign_up_failed", "Sign-up failed")
    val authSignInFailed = CoreString("auth_sign_in_failed", "Sign-in failed")
    val authSignOutFailed = CoreString("auth_sign_out_failed", "Sign-out failed")
    val authAccountDeletionFailed = CoreString("auth_account_deletion_failed", "Account deletion failed")
    val genericAddon = CoreString("generic_addon", "Addon")
    val addonsManifestMissingField = CoreString("addons_manifest_missing_field", "Manifest missing \"%1\$s\"")
    val profilePrimaryAddonsRequired = CoreString("profile_primary_addons_required", "This profile uses primary addons.")
    val addonInvalidUrl = CoreString("addon_invalid_url", "Enter a valid addon URL")
    val addonAlreadyInstalled = CoreString("addon_already_installed", "That addon is already installed.")
    val addonLoadManifestFailed = CoreString("addon_load_manifest_failed", "Unable to load manifest")
    val addonsErrorEnterUrl = CoreString("addons_error_enter_url", "Enter an addon URL.")
    val catalogLoadFailed = CoreString("catalog_load_failed", "Unable to load catalog items.")
    val updatesGithubApiError = CoreString("updates_github_api_error", "GitHub releases API error: %1\$d")
    val homeCatalogDefaultTitle = CoreString("home_catalog_default_title", "%1\$s - %2\$s")
    val genericTrailer = CoreString("generic_trailer", "Trailer")
    val sourceEmbedded = CoreString("source_embedded", "Embedded")
    val detailsRuntimeHoursMinutes = CoreString("details_runtime_hours_minutes", "%1\$dh %2\$dm")
    val detailsRuntimeHoursOnly = CoreString("details_runtime_hours_only", "%1\$dh")
    val detailsRuntimeMinutesOnly = CoreString("details_runtime_minutes_only", "%1\$dm")
    val networkRequestFailedHttp = CoreString("network_request_failed_http", "Request failed with HTTP %1\$d")
    val networkEmptyResponseBody = CoreString("network_empty_response_body", "The server returned an empty response")
}

object CoreText {
    /** Returns the translated text for [string] with the arguments already applied, or null to use the English text. */
    var resolver: (suspend (CoreString, List<Any>) -> String?)? = null

    suspend fun get(string: CoreString, vararg args: Any): String =
        resolver?.invoke(string, args.toList()) ?: format(string.english, args.toList())

    /** Translates a content type (movie, series...) for display; the host app may replace it with its localized labels. */
    var mediaTypeResolver: ((String) -> String)? = null

    fun mediaTypeLabel(type: String): String {
        mediaTypeResolver?.let { return it(type) }
        return when (type.trim().lowercase()) {
            "movie" -> "Movies"
            "series" -> "Series"
            "anime" -> "Anime"
            "channel" -> "Channels"
            "tv" -> "TV"
            else -> type.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        }
    }

    fun format(template: String, args: List<Any>): String {
        if (args.isEmpty()) return template
        var out = template
        args.forEachIndexed { index, arg ->
            out = out.replace("%${index + 1}\$s", arg.toString()).replace("%${index + 1}\$d", arg.toString())
        }
        return out
    }
}
