package com.nuvio.app

import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.build.PlatformAppFeaturePolicy

internal actual fun registerAppFeaturePolicy() {
    AppFeaturePolicy.values = PlatformAppFeaturePolicy
}
