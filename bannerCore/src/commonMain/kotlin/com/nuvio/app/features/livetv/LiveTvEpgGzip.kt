package com.nuvio.app.features.livetv

/** Decompresses gzip data (XMLTV guides are often served as .gz). The platform supplies the [Backend]. */
object LiveTvGzip {
    interface Backend { fun gunzip(bytes: ByteArray, maxOutputBytes: Int): ByteArray }
    var backend: Backend? = null
}

fun liveTvGunzip(bytes: ByteArray, maxOutputBytes: Int): ByteArray =
    (LiveTvGzip.backend ?: error("No gzip backend registered")).gunzip(bytes, maxOutputBytes)
