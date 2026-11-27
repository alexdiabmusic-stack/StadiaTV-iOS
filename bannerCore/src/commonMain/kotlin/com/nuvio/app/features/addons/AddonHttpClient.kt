package com.nuvio.app.features.addons

suspend fun fetchAddonResponseText(
    url: String,
    forceRefresh: Boolean = false,
): String =
    if (forceRefresh) {
        httpGetTextWithHeaders(
            url = url,
            headers = mapOf("Cache-Control" to "no-cache"),
        )
    } else {
        httpGetText(url)
    }
