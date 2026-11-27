package com.nuvio.app.features.sports

import com.nuvio.app.features.sports.compat.LiveTvFiles
import com.nuvio.app.features.sports.compat.LiveTvTimeZones
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The Sports hub's saved formats and platform seams: what the phone writes, the Mac must read (and the other way round). */
class SportsCoreTest {
    @Test
    fun followsSurviveASaveAndLoad() {
        val follows = SportsFollows(
            teams = listOf(FollowedTeam("soccer/eng.1", "349", "AFC Bournemouth", "BOU", null, "https://example.test/349.png")),
            words = listOf("Luke Littler"),
            setUp = true,
            pins = listOf("soccer/eng.1"),
            order = listOf("t:soccer/eng.1:349"),
        )
        val back = SportsFollows.fromJson(follows.toJson())
        assertEquals(follows.teams, back.teams)
        assertEquals(follows.words, back.words)
        assertEquals(follows.pins, back.pins)
        assertEquals(follows.order, back.order)
        assertTrue(back.setUp)
        assertTrue(back.followsTeam("soccer/eng.1", "349"))
        assertFalse(back.followsTeam("soccer/eng.1", "1"))
    }

    @Test
    fun aTeamWithNoColourIsWrittenAndReadBack() {
        val team = FollowedTeam("football/nfl", "8", "Detroit Lions", "DET", null, null)
        val back = SportsFollows.fromJson(SportsFollows(teams = listOf(team)).toJson()).teams.single()
        assertNull(back.color)
        assertNull(back.logo)
    }

    @Test
    fun settingsSurviveASaveAndLoad() {
        val settings = SportsSettings(region = "UK", choosePlayStream = true, hideScores = true, onlyOnMyChannels = true, hiddenLeagues = setOf("football/nfl"))
        val back = SportsSettings.fromJson(settings.toJson())
        assertEquals("UK", back.region)
        assertTrue(back.choosePlayStream && back.hideScores && back.onlyOnMyChannels)
        assertEquals(setOf("football/nfl"), back.hiddenLeagues)
    }

    @Test
    fun nothingSavedMeansDefaults() {
        assertTrue(SportsFollows.fromJson(null).isEmpty)
        assertEquals(SportsSettings(), SportsSettings.fromJson(""))
    }

    @Test
    fun filesBeforeAnyPlatformIsInstalledAreKeptInMemory() {
        LiveTvFiles.writeSmall("test", "note.txt", "hello")
        assertTrue(LiveTvFiles.exists("test", "note.txt"))
        assertEquals("hello", LiveTvFiles.readSmall("test", "note.txt"))
    }

    @Test
    fun utcNeedsNoPlatformZoneDatabase() {
        assertEquals(0L, LiveTvTimeZones.offsetMs("UTC", 1_700_000_000_000))
        assertTrue(LiveTvTimeZones.isKnown(LiveTvTimeZones.SYSTEM))
    }
}
