package com.nuvio.app.features.livetv

fun parseM3uEpgUrls(payload: String): List<String> {
    val header = payload.lineSequence()
        .map(String::trim)
        .firstOrNull(String::isNotBlank)
        ?: return emptyList()
    if (!header.startsWith("#EXTM3U", ignoreCase = true)) return emptyList()
    return listOf("url-tvg", "x-tvg-url", "tvg-url")
        .mapNotNull { key -> readM3uAttribute(header, key) }
        .flatMap { value -> value.split(',') }
        .map(String::trim)
        .filter { it.startsWith("http://", ignoreCase = true) || it.startsWith("https://", ignoreCase = true) }
        .distinct()
}

fun parseM3uPlaylist(
    payload: String,
    playlist: LiveTvPlaylist? = null,
): List<LiveTvChannel> {
    val channels = mutableListOf<LiveTvChannel>()
    var pendingInfo: M3uInfo? = null

    payload.lineSequence()
        .map(String::trim)
        .filter(String::isNotBlank)
        .forEach { line ->
            when {
                line.startsWith("#EXTINF", ignoreCase = true) -> {
                    pendingInfo = parseExtInf(line)
                }
                line.startsWith("#") -> Unit
                else -> {
                    val streamUrl = line
                    val info = pendingInfo
                    val name = info?.name?.takeIf(String::isNotBlank)
                        ?: streamUrl.substringAfterLast('/').substringBefore('?').ifBlank { "Channel" }
                    channels += LiveTvChannel(
                        id = stableChannelId(streamUrl, channels.size),
                        name = name,
                        streamUrl = streamUrl,
                        logoUrl = info?.logoUrl?.takeIf(String::isNotBlank),
                        group = info?.group?.takeIf(String::isNotBlank),
                        playlistId = playlist?.id,
                        playlistName = playlist?.name,
                        epgId = info?.epgId?.takeIf(String::isNotBlank),
                    )
                    pendingInfo = null
                }
            }
        }

    return channels.distinctBy { it.streamUrl }
}

private data class M3uInfo(
    val name: String,
    val logoUrl: String?,
    val group: String?,
    val epgId: String? = null,
)

private fun parseExtInf(line: String): M3uInfo {
    val name = line.substringAfter(',', missingDelimiterValue = "")
        .trim()
        .ifBlank {
            readM3uAttribute(line, "tvg-name").orEmpty()
        }
    return M3uInfo(
        name = name,
        logoUrl = readM3uAttribute(line, "tvg-logo"),
        group = readM3uAttribute(line, "group-title"),
        epgId = readM3uAttribute(line, "tvg-id"),
    )
}

private fun readM3uAttribute(line: String, key: String): String? {
    val marker = "$key=\""
    val start = line.indexOf(marker, ignoreCase = true)
    if (start < 0) return null
    val valueStart = start + marker.length
    val valueEnd = line.indexOf('"', startIndex = valueStart).takeIf { it >= 0 } ?: return null
    return line.substring(valueStart, valueEnd).trim()
}


fun stableChannelId(streamUrl: String, index: Int): String =
    "live:${streamUrl.hashCode().toUInt().toString(16)}:$index"

