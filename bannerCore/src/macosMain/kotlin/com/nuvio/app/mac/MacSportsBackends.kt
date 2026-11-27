package com.nuvio.app.mac

import com.nuvio.app.features.addons.httpGetTextWithHeaders
import com.nuvio.app.features.sports.SportsAccents
import com.nuvio.app.features.sports.SportsPlatform
import com.nuvio.app.features.sports.SportsPlatformBackend
import com.nuvio.app.features.sports.compat.LiveTvFiles
import com.nuvio.app.features.sports.compat.LiveTvFilesBackend
import com.nuvio.app.features.sports.compat.LiveTvTimeZones
import com.nuvio.app.features.sports.compat.LiveTvTimeZonesBackend
import com.nuvio.app.features.sports.compat.SportsKeyValue
import com.nuvio.app.features.sports.compat.SportsKeyValueBackend
import com.nuvio.app.features.sports.compat.SportsLiveTvHost
import com.nuvio.app.features.sports.compat.SportsLiveTvSnapshot
import com.nuvio.app.features.sports.compat.SportsLiveTvSource
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSBundle
import platform.Foundation.NSDate
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileModificationDate
import platform.Foundation.NSLocale
import platform.Foundation.NSLocaleCountryCode
import platform.Foundation.NSLocaleLanguageCode
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSString
import platform.Foundation.NSThread
import platform.Foundation.NSTimeZone
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.currentLocale
import platform.Foundation.dateWithTimeIntervalSince1970
import platform.Foundation.knownTimeZoneNames
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.systemTimeZone
import platform.Foundation.timeIntervalSince1970
import platform.Foundation.timeZoneWithName
import platform.Foundation.writeToFile

/** What the Sports hub needs from this Mac, handed to the shared core at launch. */
internal fun installMacSports() {
    SportsPlatform.backend = MacSportsPlatform
    SportsKeyValue.backend = MacSportsKeyValue
    LiveTvFiles.backend = MacLiveTvFiles
    LiveTvTimeZones.backend = MacLiveTvTimeZones
    SportsLiveTvHost.source = MacSportsLiveTvSource
}

private object MacSportsPlatform : SportsPlatformBackend {
    private val feedHeaders = mapOf(
        "Accept" to "application/json",
        "User-Agent" to "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    )

    override suspend fun get(url: String): String = httpGetTextWithHeaders(url, feedHeaders)
    override fun countryCode(): String = (NSLocale.currentLocale.objectForKey(NSLocaleCountryCode) as? String).orEmpty().uppercase()
    override fun languageCode(): String =
        (NSLocale.currentLocale.objectForKey(NSLocaleLanguageCode) as? String)?.lowercase()?.ifBlank { null } ?: "en"
    override fun pause(ms: Long) { if (ms > 0) NSThread.sleepForTimeInterval(ms / 1000.0) }
    override fun foldAccents(text: String): String = SportsAccents.fold(text)
}

private object MacSportsKeyValue : SportsKeyValueBackend {
    private val defaults get() = NSUserDefaults.standardUserDefaults
    override fun getString(key: String): String? = defaults.stringForKey("sports_hub.$key")
    override fun putString(key: String, value: String?) {
        if (value == null) defaults.removeObjectForKey("sports_hub.$key") else defaults.setObject(value, "sports_hub.$key")
    }
}

/** Small files under ~/Library/Application Support/<app id>/sports-hub: saved feeds, tables, what you follow. */
@OptIn(ExperimentalForeignApi::class)
private object MacLiveTvFiles : LiveTvFilesBackend {
    private fun path(dir: String, name: String): String {
        val root = (NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, true).firstOrNull() as? String).orEmpty()
        val app = NSBundle.mainBundle.bundleIdentifier ?: "tv.banner.mac"
        val folder = "$root/$app/sports-hub/$dir"
        NSFileManager.defaultManager.createDirectoryAtPath(folder, withIntermediateDirectories = true, attributes = null, error = null)
        return "$folder/$name"
    }

    override fun exists(dir: String, name: String): Boolean = NSFileManager.defaultManager.fileExistsAtPath(path(dir, name))

    override fun lastModified(dir: String, name: String): Long {
        val attrs = NSFileManager.defaultManager.attributesOfItemAtPath(path(dir, name), error = null) ?: return 0L
        val date = attrs[NSFileModificationDate] as? NSDate ?: return 0L
        return (date.timeIntervalSince1970 * 1000).toLong()
    }

    override fun readSmall(dir: String, name: String): String? =
        NSString.stringWithContentsOfFile(path(dir, name), encoding = NSUTF8StringEncoding, error = null)

    override fun writeSmall(dir: String, name: String, text: String) {
        (text as NSString).writeToFile(path(dir, name), atomically = true, encoding = NSUTF8StringEncoding, error = null)
    }
}

private object MacLiveTvTimeZones : LiveTvTimeZonesBackend {
    override fun isKnown(zoneId: String): Boolean =
        zoneId == LiveTvTimeZones.SYSTEM || NSTimeZone.knownTimeZoneNames.any { it == zoneId } || NSTimeZone.timeZoneWithName(zoneId) != null

    override fun offsetMs(zone: String, epochMs: Long): Long {
        val tz = if (zone == LiveTvTimeZones.SYSTEM) NSTimeZone.systemTimeZone else NSTimeZone.timeZoneWithName(zone) ?: return 0L
        return tz.secondsFromGMTForDate(NSDate.dateWithTimeIntervalSince1970(epochMs / 1000.0)) * 1000L
    }
}

/** The Mac's own Live TV (its playlists and guide), as the Sports hub reads it to find a game's channels. */
private object MacSportsLiveTvSource : SportsLiveTvSource {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    override val snapshot: StateFlow<SportsLiveTvSnapshot> = MacLiveTv.state
        .map { SportsLiveTvSnapshot(it.channels, it.isLoading, it.isGuideLoading, MacLiveTv.programsSnapshot()) }
        .stateIn(scope, SharingStarted.Eagerly, SportsLiveTvSnapshot())

    override fun ensureLoaded() {}
}
