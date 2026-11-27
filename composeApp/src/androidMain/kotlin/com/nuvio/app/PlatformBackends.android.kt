package com.nuvio.app

import com.nuvio.app.core.auth.AuthStorage
import com.nuvio.app.core.auth.PlatformAuthStorage
import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.build.PlatformAppFeaturePolicy
import com.nuvio.app.core.logging.InAppLogClock
import com.nuvio.app.core.logging.platformInAppLogTimestamp
import com.nuvio.app.core.network.DnsPlatform
import com.nuvio.app.core.network.PlatformDnsPlatform
import com.nuvio.app.core.network.PlatformHttpEngine
import com.nuvio.app.core.network.PlatformServerConfigurationStorage
import com.nuvio.app.core.network.ServerConfigurationStorage
import com.nuvio.app.core.network.platformHttpEngineImpl
import com.nuvio.app.core.sync.PlatformSyncClientIdentityStorage
import com.nuvio.app.core.sync.SyncClientIdentityStorage
import com.nuvio.app.features.addons.AddonHttp
import com.nuvio.app.features.livetv.LiveTvGzip
import com.nuvio.app.features.livetv.PlatformLiveTvGzip
import com.nuvio.app.features.addons.AddonStorage
import com.nuvio.app.features.addons.PlatformAddonHttp
import com.nuvio.app.features.addons.PlatformAddonStorage
import com.nuvio.app.features.sports.AndroidSportsLive
import com.nuvio.app.features.sports.AndroidSportsPlatform
import com.nuvio.app.features.sports.SportsLivePlatform
import com.nuvio.app.features.sports.SportsPlatform
import com.nuvio.app.features.sports.compat.AndroidLiveTvFiles
import com.nuvio.app.features.sports.compat.AndroidLiveTvTimeZones
import com.nuvio.app.features.sports.compat.AndroidSportsAlarms
import com.nuvio.app.features.sports.compat.AndroidSportsKeyValue
import com.nuvio.app.features.sports.compat.LiveTvFiles
import com.nuvio.app.features.sports.compat.LiveTvTimeZones
import com.nuvio.app.features.sports.compat.SportsAlarmPlatform
import com.nuvio.app.features.sports.compat.SportsKeyValue

internal actual fun registerPlatformBackends() {
    AuthStorage.backend = PlatformAuthStorage
    ServerConfigurationStorage.backend = PlatformServerConfigurationStorage
    SyncClientIdentityStorage.backend = PlatformSyncClientIdentityStorage
    AddonStorage.backend = PlatformAddonStorage
    AddonHttp.backend = PlatformAddonHttp
    LiveTvGzip.backend = PlatformLiveTvGzip
    DnsPlatform.backend = PlatformDnsPlatform
    PlatformHttpEngine.factory = ::platformHttpEngineImpl
    InAppLogClock.timestamp = ::platformInAppLogTimestamp
    AppFeaturePolicy.values = PlatformAppFeaturePolicy
    SportsPlatform.backend = AndroidSportsPlatform
    SportsLivePlatform.backend = AndroidSportsLive
    SportsKeyValue.backend = AndroidSportsKeyValue
    LiveTvFiles.backend = AndroidLiveTvFiles
    LiveTvTimeZones.backend = AndroidLiveTvTimeZones
    SportsAlarmPlatform.backend = AndroidSportsAlarms
}
