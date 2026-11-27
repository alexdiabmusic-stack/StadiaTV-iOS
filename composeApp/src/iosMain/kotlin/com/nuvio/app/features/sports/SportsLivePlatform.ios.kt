package com.nuvio.app.features.sports

import com.nuvio.app.features.sports.SportsLivePlatformBackend

object IosSportsLive : SportsLivePlatformBackend {
    override val supported: Boolean = false
    override fun show(title: String, text: String, openUrl: String?): Boolean = false
    override fun stop() {}
    override fun openNotificationSettings() {}
}
