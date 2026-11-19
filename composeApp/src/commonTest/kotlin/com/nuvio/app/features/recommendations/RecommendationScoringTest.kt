package com.nuvio.app.features.recommendations

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RecommendationScoringTest {
    private val now = 20_400L * DAY_MS

    private fun ev(
        id: Int,
        tv: Boolean = false,
        finished: Boolean = false,
        episodes: Int = 0,
        completed: Boolean = false,
        progress: Float? = null,
        saved: Boolean = false,
        rating: Int? = null,
        daysAgo: Int = 1,
        times: List<Int> = emptyList(),
    ) = ViewingEvidence(
        id, tv, "t$id", finished, episodes, completed, progress, saved, null, rating, now - daysAgo * DAY_MS,
        times.map { now - it * DAY_MS },
    )

    private fun meta(id: Int, vararg genres: Int, tv: Boolean = false, cast: List<Person> = emptyList()) =
        TitleMeta(id, tv, "t$id", genres = genres.toList(), cast = cast)

    @Test
    fun brieflyOpenedTitleSaysNothing() {
        assertEquals(0.0, RecommendationScoring.engagement(ev(1, progress = 0.05f), now))
    }

    @Test
    fun aLongSeriesCountsAsOneStrongTitleNotHundredsOfSignals() {
        val shark = RecommendationScoring.engagement(ev(1, tv = true, episodes = 332), now)
        val ten = RecommendationScoring.engagement(ev(2, tv = true, episodes = 10), now)
        val film = RecommendationScoring.engagement(ev(3, finished = true), now)
        assertTrue(shark <= 1.01 && shark > ten, "332 episodes should saturate around one finished title: $shark")
        assertTrue(film >= ten)
    }

    @Test
    fun abandonedSeriesBarelyCounts() {
        val abandoned = RecommendationScoring.engagement(ev(1, tv = true, episodes = 1, daysAgo = 200), now)
        assertTrue(abandoned < 0.2)
    }

    @Test
    fun dislikedTitleIsNotATasteSignal() {
        assertEquals(0.0, RecommendationScoring.engagement(ev(1, finished = true, rating = 3), now))
    }

    @Test
    fun seriesActivityIsSplitAcrossWindowsWithoutDoubleCounting() {
        val e = ev(1, tv = true, episodes = 4, times = listOf(5, 60, 200, 300))
        val shares = TasteProfile.windowShares(e, now, TasteRules())
        assertEquals(1.0, shares.values.sum(), 1e-9)
        assertEquals(0.25, shares[TasteWindow.Recent])
        assertEquals(0.25, shares[TasteWindow.MediumTerm])
        assertEquals(0.5, shares[TasteWindow.LongTerm])
    }

    @Test
    fun manyRecentTitlesCannotOutweighTheLongTermProfile() {
        // Ten comedy series over the last year, then eight action films logged this week.
        val history = (1..10).map { ev(it, tv = true, episodes = 10, times = (130..400 step 30).toList()) to meta(it, 35, tv = true) } +
            (11..18).map { ev(it, finished = true, daysAgo = 2, times = listOf(2)) to meta(it, 28) }
        val taste = TasteProfile.build(history, now)
        assertTrue(taste.genres.getValue(35) > taste.genres.getValue(28), taste.genres.toString())
        // Long-term 45 and recent 15 are renormalized (no medium or explicit evidence): 0.75 / 0.25.
        assertEquals(0.75, taste.effectiveWeights.getValue(TasteWindow.LongTerm), 1e-9)
        assertEquals(0.25, taste.effectiveWeights.getValue(TasteWindow.Recent), 1e-9)
    }

    @Test
    fun windowWithFewTitlesHandsWeightToTheOthers() {
        val history = (1..6).map { ev(it, finished = true, daysAgo = 300, times = listOf(300)) to meta(it, 18) } +
            listOf(ev(7, finished = true, daysAgo = 2, times = listOf(2)) to meta(7, 27))
        val w = TasteProfile.build(history, now).effectiveWeights
        // Recent has one title of the four needed for full confidence: 0.15 * 0.25 before renormalizing.
        assertTrue(w.getValue(TasteWindow.Recent) < 0.1, w.toString())
    }

    @Test
    fun keywordsAndCreatorsNeedToRepeat() {
        val history = (1..6).map { i ->
            ev(i, finished = true, daysAgo = 200) to meta(i, 18).copy(keywords = if (i <= 2) listOf(100) else listOf(200 + i))
        }
        val taste = TasteProfile.build(history, now)
        assertTrue(100 in taste.keywords)
        assertTrue(203 !in taste.keywords)
    }

    @Test
    fun actorAffinityCountsDistinctTitlesNotEpisodes() {
        val star = Person(1, "Star", 0)
        val seriesCast = Person(2, "Series Regular", 0)
        val history = listOf(
            ev(1, finished = true) to meta(1, 18, cast = listOf(star)),
            ev(2, finished = true) to meta(2, 35, cast = listOf(star)),
            ev(3, tv = true, episodes = 300) to meta(3, 35, tv = true, cast = listOf(seriesCast)),
        )
        val actors = ActorAffinities.compute(history, now)
        assertEquals(listOf("Star"), actors.map { it.person.name })
    }

    @Test
    fun actorsSeenOnlyInOneFranchiseRankBelowVersatileOnes() {
        val hero = Person(1, "Franchise Hero", 0)
        val versatile = Person(2, "Versatile", 1)
        val history = (1..4).map { ev(it, finished = true) to meta(it, 28, cast = listOf(hero)).copy(collectionId = 99) } +
            listOf(
                ev(5, finished = true) to meta(5, 35, cast = listOf(versatile)),
                ev(6, finished = true) to meta(6, 18, cast = listOf(versatile)),
            )
        val actors = ActorAffinities.compute(history, now, franchiseOf = { m -> m.collectionId?.let { "coll:$it" } })
        // Four films in one franchise rank below two different standalone titles.
        assertEquals(listOf("Versatile", "Franchise Hero"), actors.map { it.person.name })
        assertEquals(setOf("coll:99"), actors.last().groups)
    }

    @Test
    fun seedAgreementHasDiminishingReturns() {
        val m = meta(1, 28)
        val one = Candidate(m, setOf(CandidateSource.Recommended), listOf(SeedHit("a", "A", 0.1, 0, false)))
        val six = one.copy(hits = (1..6).map { SeedHit("s$it", "S$it", 0.1, 0, false) })
        val ratio = CandidateScoring.collaborative(six) / CandidateScoring.collaborative(one)
        assertTrue(ratio < 2.0, "six agreeing seeds should be worth less than two independent ones: $ratio")
    }

    @Test
    fun mmrSpreadsGenres() {
        val items = (1..6).map { meta(it, 28) } + (7..9).map { meta(it, 35) }
        val picked = Diversity.mmr(items, 4, { if (it.genres.first() == 28) 0.9 else 0.7 }, { a, b -> Diversity.jaccard(a.genres, b.genres) })
        assertTrue(picked.any { 35 in it.genres }, picked.map { it.genres }.toString())
    }

    @Test
    fun franchisePenaltyIsSoft() {
        val franchise: (TitleMeta) -> String? = { if (it.tmdbId < 100) "mcu" else null }
        val penalty = Diversity.franchisePenalty(size = 20, maxShare = 0.25, franchiseOf = franchise)
        val picked = (1..5).map { meta(it, 28) }
        assertTrue(penalty(meta(6, 28), picked) > 0.0)
        assertEquals(0.0, penalty(meta(200, 28), picked))
        // Below the cap there's no penalty at all.
        assertEquals(0.0, penalty(meta(7, 28), picked.take(2)))
    }
}
