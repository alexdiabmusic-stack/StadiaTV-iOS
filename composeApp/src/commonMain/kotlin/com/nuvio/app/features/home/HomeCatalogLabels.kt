package com.nuvio.app.features.home

import com.nuvio.app.core.i18n.localizedMediaTypeLabel

internal fun String.displayLabel(): String = localizedMediaTypeLabel(this)
