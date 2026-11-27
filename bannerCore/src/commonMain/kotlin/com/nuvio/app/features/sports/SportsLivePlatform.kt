package com.nuvio.app.features.sports

/**
 * The live-score notice while a team you follow is playing: on Android a quiet notification
 * that stays at the top with the score and keeps the app checking in the background.
 */
interface SportsLivePlatformBackend {
    /** Whether this device can do it (and show Game Alerts at all). */
    val supported: Boolean

    /** Shows (or updates) the live-score notice; tapping it opens [openUrl]. False when the phone wouldn't allow it right now. */
    fun show(title: String, text: String, openUrl: String?): Boolean

    /** Takes the live-score notice down. */
    fun stop()

    /** Opens this app's notification settings in the phone's settings. */
    fun openNotificationSettings()
}

object SportsLivePlatform {
    /** Devices without a live-score notice (iOS, the Mac) keep this default. */
    var backend: SportsLivePlatformBackend = object : SportsLivePlatformBackend {
        override val supported: Boolean = false
        override fun show(title: String, text: String, openUrl: String?): Boolean = false
        override fun stop() {}
        override fun openNotificationSettings() {}
    }

    val supported: Boolean get() = backend.supported
    fun show(title: String, text: String, openUrl: String?): Boolean = backend.show(title, text, openUrl)
    fun stop() = backend.stop()
    fun openNotificationSettings() = backend.openNotificationSettings()
}
