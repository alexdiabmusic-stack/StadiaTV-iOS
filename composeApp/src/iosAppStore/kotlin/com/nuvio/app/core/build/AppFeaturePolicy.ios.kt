package com.nuvio.app.core.build

object PlatformAppFeaturePolicy : AppFeaturePolicy.Values {
    override val pluginsEnabled: Boolean = false
    override val supportersContributorsPageEnabled: Boolean = false
    override val donationActionsEnabled: Boolean = false
    override val donationProgressEnabled: Boolean = true
    override val accountDeletionEnabled: Boolean = true
    override val personalMediaAddonCopyEnabled: Boolean = true
    override val p2pEnabled: Boolean = false
    override val trailerPlaybackMode: TrailerPlaybackMode = TrailerPlaybackMode.EXTERNAL
    override val heroTrailerPlaybackSupported: Boolean = false
    override val inAppUpdaterEnabled: Boolean = false
    override val imdbRatingLogoEnabled: Boolean = false
    override val mediaPlaybackForegroundServiceEnabled: Boolean = false
    override val downloadForegroundServiceEnabled: Boolean = false
    override val customServerConnectionsEnabled: Boolean = false
}
