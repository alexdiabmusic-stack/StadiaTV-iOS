package com.nuvio.app.core.build

object PlatformAppFeaturePolicy : AppFeaturePolicy.Values {
    override val pluginsEnabled: Boolean = true
    override val supportersContributorsPageEnabled: Boolean = true
    override val donationActionsEnabled: Boolean = true
    override val donationProgressEnabled: Boolean = false
    override val accountDeletionEnabled: Boolean = false
    override val personalMediaAddonCopyEnabled: Boolean = false
    override val p2pEnabled: Boolean = true
    override val trailerPlaybackMode: TrailerPlaybackMode = TrailerPlaybackMode.IN_APP
    override val heroTrailerPlaybackSupported: Boolean = true
    override val inAppUpdaterEnabled: Boolean = true
    override val imdbRatingLogoEnabled: Boolean = true
    override val mediaPlaybackForegroundServiceEnabled: Boolean = true
    override val downloadForegroundServiceEnabled: Boolean = true
    override val customServerConnectionsEnabled: Boolean = true
}
