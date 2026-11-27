package com.nuvio.app.features.personalization

import com.nuvio.app.features.playback.InMemoryPlaybackStateStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RatingConsolidatorTest {
    private fun r(source: String, key: String, v: Double, min: Double, max: Double, at: Long) = ExternalRating(source, key, v, min, max, at)

    @Test fun differentScalesNormalizeWithoutLosingTheOriginal() {
        val out = RatingConsolidator.consolidate(listOf(r("letterboxd", "m1", 4.0, 0.5, 5.0, 10), r("trakt", "m2", 8.0, 1.0, 10.0, 10)))
        assertEquals(0.7778, out.first { it.mediaKey == "m1" }.normalized, 0.001)
        assertEquals(4.0, out.first { it.mediaKey == "m1" }.chosen.value)
        assertEquals(0.7778, out.first { it.mediaKey == "m2" }.normalized, 0.001)
    }

    @Test fun conflictingRatingsResolveToTheNewestThenTheSourcePriority() {
        val a = RatingConsolidator.consolidate(listOf(r("trakt", "m", 2.0, 1.0, 10.0, 100), r("letterboxd", "m", 5.0, 0.5, 5.0, 200))).single()
        assertEquals("letterboxd", a.chosen.source)
        val tie = RatingConsolidator.consolidate(listOf(r("trakt", "m", 2.0, 1.0, 10.0, 100), r("simkl", "m", 9.0, 1.0, 10.0, 100)), listOf("simkl", "trakt")).single()
        assertEquals("simkl", tie.chosen.source)
        assertEquals(listOf("simkl", "trakt"), tie.sources)
    }

    @Test fun theSameRatingReportedTwiceIsOne_andBadScalesAreIgnored() {
        val out = RatingConsolidator.consolidate(listOf(r("trakt", "m", 8.0, 1.0, 10.0, 1), r("trakt", "m", 8.0, 1.0, 10.0, 1), r("x", "bad", 3.0, 5.0, 5.0, 1), r("y", "nan", Double.NaN, 0.0, 10.0, 1)))
        assertEquals(listOf("m"), out.map { it.mediaKey }); assertEquals(1, out.single().sources.size)
    }
}

class PreferenceFeedbackTest {
    private val now = 1_000L

    @Test fun reactionsFeedTasteButNotInterestedDoesNot_andProfilesAreIsolated() {
        val s = PreferenceFeedbackStore(InMemoryPlaybackStateStore())
        s.setReaction(1, "movie:a", PreferenceReaction.LOVE, now)
        s.setReaction(1, "movie:b", PreferenceReaction.NOT_FOR_ME, now)
        s.setNotInterested(1, "movie:c", true, now)
        assertEquals(setOf("movie:a" to 1.0, "movie:b" to -1.0), s.tasteSignals(1).toSet())
        assertTrue(s.isSuppressed(1, "movie:c")); assertFalse(s.isSuppressed(2, "movie:c"))
        assertTrue(s.tasteSignals(2).isEmpty())
    }

    @Test fun changingAndUndoingFeedbackWorks() {
        val s = PreferenceFeedbackStore(InMemoryPlaybackStateStore())
        s.setReaction(1, "m", PreferenceReaction.LIKE, now); s.setReaction(1, "m", PreferenceReaction.LOVE, now + 1)
        assertEquals(PreferenceReaction.LOVE, s.reactionFor(1, "m"))
        s.setReaction(1, "m", null, now + 2); assertNull(s.reactionFor(1, "m"))
        s.setNotInterested(1, "n", true, now); s.setNotInterested(1, "n", false, now + 1)
        assertFalse(s.isSuppressed(1, "n")); assertTrue(s.suppressedKeys(1).isEmpty())
    }

    @Test fun feedbackSurvivesARestartAndResetClearsIt() {
        val backing = InMemoryPlaybackStateStore()
        PreferenceFeedbackStore(backing).setNotInterested(1, "m", true, now)
        val reopened = PreferenceFeedbackStore(backing)
        assertTrue(reopened.isSuppressed(1, "m"))
        reopened.reset(1); assertFalse(reopened.isSuppressed(1, "m"))
    }
}

class RecommendationRefreshPolicyTest {
    private fun fp(rating: Double = 8.0, profile: Int = 1) =
        RecommendationRefreshPolicy.fingerprint(profile, mapOf("m1" to rating, "m2" to 6.0), setOf("w1"), setOf("l1"), emptyMap())

    @Test fun editingARatingChangesTheFingerprintEvenWhenTheCountIsUnchanged() {
        assertNotEquals(fp(8.0), fp(9.0))
    }

    @Test fun theOrderEntriesAreListedInDoesNotMatter_butTheProfileDoes() {
        val a = RecommendationRefreshPolicy.fingerprint(1, mapOf("a" to 1.0, "b" to 2.0), setOf("x", "y"), emptySet(), emptyMap())
        val b = RecommendationRefreshPolicy.fingerprint(1, mapOf("b" to 2.0, "a" to 1.0), setOf("y", "x"), emptySet(), emptyMap())
        assertEquals(a, b); assertNotEquals(fp(profile = 1), fp(profile = 2))
    }

    @Test fun refreshOnlyOnRealChangeDebouncedAndOnExpiry() {
        val min = 60_000L
        assertEquals(RefreshDecision.SKIP_UNCHANGED, RecommendationRefreshPolicy.decide(5, 5, 0, 10 * min))
        assertEquals(RefreshDecision.REFRESH, RecommendationRefreshPolicy.decide(5, 6, 0, 10 * min))
        assertEquals(RefreshDecision.WAIT_DEBOUNCE, RecommendationRefreshPolicy.decide(5, 6, 0, 10_000L))
        assertEquals(RefreshDecision.REFRESH, RecommendationRefreshPolicy.decide(5, 5, 0, 7 * 60 * min)) // cache too old
        assertEquals(RefreshDecision.REFRESH, RecommendationRefreshPolicy.decide(null, 5, null, 0))
    }
}

class EndlessRowAndHeroTest {
    @Test fun appendedTitlesFollowTheSameRulesAndTheRowEndsWhenNothingQualifies() {
        data class T(val id: String, val ok: Boolean)
        val pool = listOf(T("a", true), T("b", false), T("c", true), T("a", true), T("d", true), T("e", true))
        val page = EndlessRowPolicy.nextPage(pool, { it.id }, shown = setOf("c"), excluded = setOf("e"), eligible = { it.ok }, pageSize = 5)
        assertEquals(listOf("a", "d"), page.map { it.id }) // no repeats, no ineligible, no excluded, no already shown
        assertTrue(EndlessRowPolicy.nextPage(pool, { it.id }, setOf("a", "c", "d"), setOf("e"), { it.ok }, 5).isEmpty())
    }

    private fun c(key: String, genre: String, franchise: String? = null, rel: Double = 0.5, art: Boolean = true) = HeroCandidate(key, listOf(genre), franchise, rel, hasSuitableArtwork = art)

    @Test fun noGenreOrFranchiseCanFillTheHero() {
        val pool = (1..10).map { c("act$it", "Action", rel = 0.9) } + (1..4).map { c("dra$it", "Drama", rel = 0.5) } +
            (1..3).map { c("hor$it", "Horror", rel = 0.4) } + listOf(c("m1", "Comedy", "mcu", 0.8), c("m2", "Comedy", "mcu", 0.8))
        val hero = HeroSelector.select(pool, size = 6, dayEpoch = 100, profileId = 1)
        assertTrue(hero.count { it.genres.first() == "Action" } <= 2)
        assertTrue(hero.count { it.franchiseKey == "mcu" } <= 1)
        assertEquals(6, hero.size)
        // With too little variety the selector returns fewer rather than break the caps.
        assertEquals(2, HeroSelector.select((1..10).map { c("x$it", "Action") }, size = 6, dayEpoch = 1, profileId = 1).size)
    }

    @Test fun theHeroIsStableForADayAndSkipsTitlesWithoutArtwork() {
        val pool = (1..8).map { c("t$it", "G$it", rel = 0.5) } + c("noart", "X", rel = 1.0, art = false)
        val a = HeroSelector.select(pool, dayEpoch = 5, profileId = 1).map { it.key }
        assertEquals(a, HeroSelector.select(pool.reversed(), dayEpoch = 5, profileId = 1).map { it.key })
        assertFalse("noart" in a)
        assertNotEquals(a, HeroSelector.select(pool, dayEpoch = 6, profileId = 1).map { it.key }) // ties reshuffle on another day
    }

    @Test fun aColdStartProfileStillGetsAVariedSetAndRecentTitlesRankLower() {
        val pool = (1..12).map { c("t$it", listOf("A", "B", "C", "D", "E", "F")[it % 6], rel = 0.0) }
        assertTrue(HeroSelector.select(pool, dayEpoch = 1, profileId = 9).map { it.genres.first() }.toSet().size >= 3)
        val recent = HeroSelector.select(pool, dayEpoch = 1, profileId = 9, recentlyShown = setOf("t1", "t2", "t3", "t4", "t5", "t6")).map { it.key }
        assertTrue(recent.none { it in setOf("t1", "t2", "t3", "t4", "t5", "t6") })
    }
}

class MatchAndOrderTest {
    private val spread = (1..100).map { it / 100.0 }

    @Test fun sparseEvidenceGetsNoPercentageAndNoLabel() {
        assertNull(MatchPresentation.percent(0.9, spread, evidenceCount = 3))
        assertEquals(MatchLabel.NONE, MatchPresentation.label(0.9, spread, evidenceCount = 2))
        assertNull(MatchPresentation.percent(0.9, listOf(0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5), 100)) // no spread
    }

    @Test fun percentagesAreSpreadSoOnlyTheBestReachTheNineties() {
        val pct = spread.map { MatchPresentation.percent(it, spread, 100)!! }
        assertTrue(pct.count { it >= 95 } <= 15) // not nearly every title
        assertTrue(pct.min() >= 50 && pct.max() <= 98)
        assertEquals(MatchLabel.STRONG_MATCH, MatchPresentation.label(0.97, spread, 100))
        assertEquals(MatchLabel.RECOMMENDED_FOR_YOU, MatchPresentation.label(0.7, spread, 100))
        assertEquals(MatchLabel.NONE, MatchPresentation.label(0.2, spread, 100))
    }

    @Test fun explanationsOnlyComeFromRealEvidence() {
        assertNull(RecommendationExplainer.explain(emptyList()))
        assertNull(RecommendationExplainer.explain(listOf(ReasonEvidence(ReasonKind.BECAUSE_YOU_WATCHED, "", 0.9), ReasonEvidence(ReasonKind.SIMILAR_GENRE, "Crime", 0.0))))
        val best = RecommendationExplainer.explain(listOf(ReasonEvidence(ReasonKind.SIMILAR_GENRE, "Crime", 0.3), ReasonEvidence(ReasonKind.BECAUSE_YOU_WATCHED, "Arrival", 0.8)))
        assertEquals("Arrival", best?.subject)
    }

    private val rows = listOf(
        HomeRowEntry("hero", anchorOrder = 0), HomeRowEntry("cw", anchorOrder = 1), HomeRowEntry("top10", anchorOrder = 2),
        HomeRowEntry("rec", anchorOrder = 3), HomeRowEntry("explore", anchorOrder = 4),
        HomeRowEntry("a", relevance = 0.2, manualIndex = 1), HomeRowEntry("b", relevance = 0.9, manualIndex = 2),
        HomeRowEntry("c", relevance = 0.5, manualIndex = 0), HomeRowEntry("empty", relevance = 1.0, available = false),
    )

    @Test fun anchorsStayFixedAndTheViewersOwnOrderWinsOverAdaptiveOrder() {
        assertEquals(listOf("hero", "cw", "top10", "rec", "explore", "c", "a", "b"), AdaptiveHomeOrder.order(rows, adaptiveEnabled = true, userCustomizedOrder = true).map { it.id })
        assertEquals(listOf("hero", "cw", "top10", "rec", "explore", "b", "c", "a"), AdaptiveHomeOrder.order(rows, adaptiveEnabled = true, userCustomizedOrder = false).map { it.id })
        assertEquals(listOf("c", "a", "b"), AdaptiveHomeOrder.order(rows, adaptiveEnabled = false, userCustomizedOrder = false).drop(5).map { it.id })
    }

    @Test fun theOrderDoesNotChangeWhileScrolling() {
        assertEquals(listOf(1, 2), AdaptiveHomeOrder.keepWhileScrolling(listOf(1, 2), listOf(2, 1), isScrolling = true))
        assertEquals(listOf(2, 1), AdaptiveHomeOrder.keepWhileScrolling(listOf(1, 2), listOf(2, 1), isScrolling = false))
    }
}

class ArtworkSelectorTest {
    private fun poster(url: String, lang: String?, w: Int = 1000, h: Int = 1500, v: Double = 5.0, n: Int = 10) = ArtworkOption(url, ArtworkKind.POSTER, lang, w, h, v, n)

    @Test fun languageThenResolutionDecideAndWrongShapesAreIgnored() {
        val opts = listOf(poster("en-hi", "en", 2000, 3000), poster("fr", "fr", 2000, 3000), poster("en-lo", "en", 500, 750), poster("wide", "en", 3000, 1000))
        assertEquals("en-hi", ArtworkSelector.select(opts, ArtworkKind.POSTER, "en", "p1|t1|home"))
        assertEquals("fr", ArtworkSelector.select(opts, ArtworkKind.POSTER, "fr", "p1|t1|home"))
    }

    @Test fun theChoiceIsStableForTheSameSeedAndAViewersOverrideAlwaysWins() {
        val opts = listOf(poster("a", "en"), poster("b", "en"))
        val first = ArtworkSelector.select(opts, ArtworkKind.POSTER, "en", "p1|t1|home")
        assertEquals(first, ArtworkSelector.select(opts.reversed(), ArtworkKind.POSTER, "en", "p1|t1|home"))
        assertEquals("custom", ArtworkSelector.select(opts, ArtworkKind.POSTER, "en", "p1|t1|home", userOverrideUrl = "custom"))
        assertNull(ArtworkSelector.select(emptyList(), ArtworkKind.POSTER, "en", "s"))
    }
}
