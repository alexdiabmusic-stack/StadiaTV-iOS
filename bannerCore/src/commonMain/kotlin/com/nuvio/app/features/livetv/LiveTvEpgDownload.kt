package com.nuvio.app.features.livetv

/**
 * Where the platform's HTTP client cannot slow a download down to the speed of the reader (Apple platforms queue whatever
 * has arrived in memory, which for a large guide is most of the file), the guide is downloaded to a temporary
 * file first and handed to the sink in slices. The platform supplies the [Backend]; without one the response is read directly.
 */
object LiveTvEpgDownload {
    interface Backend {
        /** Streams the guide to [onChunk]; it returns false to stop early. */
        suspend fun streamGuideFromDisk(url: String, headers: Map<String, String>, onChunk: (bytes: ByteArray, count: Int) -> Boolean): Boolean
    }

    var backend: Backend? = null
}

/** Returns false, having done nothing, when the platform should read the response directly instead. */
suspend fun liveTvStreamGuideFromDisk(
    url: String,
    headers: Map<String, String>,
    onChunk: (bytes: ByteArray, count: Int) -> Boolean,
): Boolean = LiveTvEpgDownload.backend?.streamGuideFromDisk(url, headers, onChunk) ?: false
