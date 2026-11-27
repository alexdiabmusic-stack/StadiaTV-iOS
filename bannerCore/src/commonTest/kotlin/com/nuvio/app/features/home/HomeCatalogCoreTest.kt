package com.nuvio.app.features.home

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.catalog.buildCatalogUrl
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class HomeCatalogCoreTest {
    private fun addon(vararg catalogs: AddonCatalog, enabled: Boolean = true) = ManagedAddon(
        manifestUrl = "https://example.test/abc/manifest.json",
        enabled = enabled,
        manifest = AddonManifest(
            id = "org.example",
            name = "Example",
            description = "",
            version = "1.0.0",
            resources = listOf(AddonResource("catalog", listOf("movie"))),
            types = listOf("movie"),
            catalogs = catalogs.toList(),
            transportUrl = "https://example.test/abc",
        ),
    )

    @Test
    fun catalogsThatNeedAnInputAreNotHomeRows() {
        val popular = AddonCatalog("movie", "top", "Popular")
        val search = AddonCatalog("movie", "search", "Search", extra = listOf(AddonExtraProperty("search", isRequired = true)))
        val genre = AddonCatalog("movie", "genre", "By Genre", extra = listOf(AddonExtraProperty("genre", isRequired = false)))
        val keys = buildHomeCatalogDefinitions(listOf(addon(popular, search, genre))).map { it.catalogId }
        assertEquals(listOf("top", "genre"), keys)
    }

    @Test
    fun disabledAddonsContributeNothing() {
        val definitions = buildHomeCatalogDefinitions(listOf(addon(AddonCatalog("movie", "top", "Popular"), enabled = false)))
        assertTrue(definitions.isEmpty())
    }

    @Test
    fun rowTitleCarriesTheContentType() {
        val definition = buildHomeCatalogDefinitions(listOf(addon(AddonCatalog("movie", "top", "Popular")))).single()
        assertEquals("Popular - Movies", definition.defaultTitle)
        assertEquals("Popular", definition.titleFor(showCatalogType = false))
        assertEquals("org.example:movie:top", definition.key)
    }

    @Test
    fun catalogUrlsFollowTheAddonProtocol() {
        val base = "https://example.test/abc/manifest.json?token=1"
        assertEquals(
            "https://example.test/abc/catalog/movie/top.json?token=1",
            buildCatalogUrl(base, "movie", "top", genre = null, search = null, skip = null),
        )
        assertEquals(
            "https://example.test/abc/catalog/movie/top/genre=Sci-Fi&skip=100.json?token=1",
            buildCatalogUrl(base, "movie", "top", genre = "Sci-Fi", search = null, skip = 100),
        )
    }

    @Test
    fun parsingKeepsOrderAndDropsDuplicates() {
        val payload = """{"metas":[
            {"id":"tt1","type":"movie","name":"One","poster":"https://img/1.jpg"},
            {"id":"tt1","type":"movie","name":"One again"},
            {"id":"tt2","type":"movie","name":"Two"}]}"""
        val parsed = HomeCatalogParser.parseCatalogResponse(payload)
        assertEquals(listOf("One", "Two"), parsed.items.map { it.name })
        assertEquals(3, parsed.rawItemCount)
    }
}
