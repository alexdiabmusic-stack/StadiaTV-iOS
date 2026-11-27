package com.nuvio.app.features.recommendations

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SampleSelectionTest {
    private val day = 86_400_000L
    private fun film(i: Int, daysAgo: Int, rating: Int? = null) = AppEvidence(
        "movie", "tt$i",
        ViewingEvidence(tmdbId = 0, tv = false, name = "Film $i", finishedMovie = true, rating = rating, lastActivityEpochMs = 1_000_000_000_000L - daysAgo * day),
    )

    @Test fun aSmallHistoryIsLookedUpInFull() {
        val history = (1..50).map { film(it, it) }
        assertEquals(50, SampleSelection.history(history).size)
    }

    @Test fun aBigHistoryKeepsTheNewestTheLovedAndASpreadInBetween() {
        // 1,800 films, one older than the last, the ones rated 4.5+ scattered through the old half.
        val history = (1..1800).map { i -> film(i, daysAgo = i, rating = if (i > 900 && i % 45 == 0) 10 else if (i % 7 == 0) 6 else null) }
        val sample = SampleSelection.history(history)
        val ids = sample.map { it.appId }.toSet()
        assertTrue(sample.size <= SampleSelection.RECENT + SampleSelection.LOVED + SampleSelection.SPREAD, "sample is capped: ${sample.size}")
        assertEquals(sample.size, ids.size, "no title twice")
        // The newest 100 are all there.
        assertTrue((1..SampleSelection.RECENT).all { "tt$it" in ids })
        // Loved films from far back are included even though they are not recent.
        val lovedOld = history.filter { (it.evidence.rating ?: 0) >= SampleSelection.LOVED_RATING }
        assertTrue(lovedOld.isNotEmpty() && lovedOld.take(SampleSelection.LOVED).all { it.appId in ids } || lovedOld.count { it.appId in ids } == SampleSelection.LOVED)
        // The spread reaches into the oldest part of the history.
        assertTrue(sample.any { it.evidence.lastActivityEpochMs < 1_000_000_000_000L - 1500 * day }, "sample reaches the oldest films")
        // And the middle of it: not just the two ends.
        assertTrue(sample.any { val d = (1_000_000_000_000L - it.evidence.lastActivityEpochMs) / day; d in 600..900 })
    }

    @Test fun trimmedDetailsKeepWhatTheEngineReadsAndDropTheRest() {
        val raw = Json.parseToJsonElement(
            """{"id":603,"title":"The Matrix","overview":"long text","poster_path":"/p.jpg","backdrop_path":"/b.jpg","adult":false,
               "genres":[{"id":28,"name":"Action"}],"release_date":"1999-03-30","vote_average":8.2,"vote_count":20000,"popularity":90.1,
               "production_companies":[{"id":1,"name":"X"}],"belongs_to_collection":{"id":2344,"name":"The Matrix Collection"},
               "keywords":{"keywords":[{"id":1,"name":"k"}]},
               "credits":{"cast":[${(1..20).joinToString(",") { """{"id":$it,"name":"A$it","order":$it,"profile_path":"/x"}""" }}],
                          "crew":[{"id":900,"name":"Dir","job":"Director","department":"Directing"},{"id":901,"name":"Cam","job":"Camera"}]},
               "recommendations":{"results":[${(1..30).joinToString(",") { """{"id":${1000 + it},"title":"R$it","overview":"o","poster_path":"/r.jpg","genre_ids":[28],"vote_count":100}""" }}]},
               "similar":{"results":[{"id":2000,"title":"S","poster_path":"/s.jpg","genre_ids":[878]}]}}""",
        ).jsonObject
        val trimmed = TmdbRecommendationData.trimDetails(raw, tv = false)
        assertEquals(603, trimmed["id"]!!.toString().toInt())
        assertFalse("production_companies" in trimmed, "heavy fields are dropped")
        assertFalse("overview" in trimmed)
        assertTrue("belongs_to_collection" in trimmed && "keywords" in trimmed && "genres" in trimmed)
        val cast = trimmed["credits"]!!.jsonObject["cast"]!!.jsonArray
        assertEquals(12, cast.size)
        assertFalse("profile_path" in cast[0].jsonObject)
        val crew = trimmed["credits"]!!.jsonObject["crew"]!!.jsonArray
        assertEquals(1, crew.size, "only the director is kept")
        val recs = trimmed["recommendations"]!!.jsonObject["results"] as JsonArray
        assertEquals(20, recs.size)
        assertFalse("overview" in (recs[0] as JsonObject))
        assertTrue("poster_path" in (recs[0] as JsonObject) && "genre_ids" in (recs[0] as JsonObject))
        assertTrue(trimmed.toString().length < raw.toString().length)
    }
}
