package com.nuvio.app.mac

import com.nuvio.app.features.sports.ChannelMatch
import com.nuvio.app.features.sports.GameState
import com.nuvio.app.features.sports.League
import com.nuvio.app.features.sports.LeagueKind
import com.nuvio.app.features.sports.Side
import com.nuvio.app.features.sports.Sport
import com.nuvio.app.features.sports.SportsAddonSource
import com.nuvio.app.features.sports.SportsCatalog
import com.nuvio.app.features.sports.SportsEvent
import com.nuvio.app.features.sports.SportsFollows
import com.nuvio.app.features.sports.SportsLiveWatch
import com.nuvio.app.features.sports.SportsMatcher
import com.nuvio.app.features.sports.SportsRepository
import com.nuvio.app.features.sports.SportsRows
import com.nuvio.app.features.sports.SportsSettings
import com.nuvio.app.features.sports.SportsStreams
import com.nuvio.app.features.sports.StandingsView
import com.nuvio.app.features.sports.TeamInfo
import com.nuvio.app.features.sports.compat.LiveTvClock
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch

/** One side of a game, in the order people say it ("Bears at Lions", "Liverpool v Man City"). */
class MacSide(
    val name: String,
    val abbr: String,
    val logo: String?,
    val score: String?,
    val record: String?,
    val winner: Boolean,
    val isHome: Boolean,
    val colorHex: String?,
)

/** A line of a race result or leaderboard. */
class MacStandingLine(val pos: String, val name: String, val detail: String?)

class MacSportsGame(
    val id: String,
    val leagueId: String,
    val leagueName: String,
    val leagueShort: String,
    val sport: String,
    val startMs: Long,
    /** 0 when unknown. */
    val endMs: Long,
    val hasTime: Boolean,
    /** "pre", "live", "post" or "off". */
    val state: String,
    val title: String,
    val subtitle: String?,
    val status: String?,
    val sides: List<MacSide>,
    /** "at" for US sports (away first), "v" otherwise. */
    val separator: String,
    val broadcasts: List<String>,
    val situation: String?,
    val note: String?,
    /** 0...1 from the game clock, or -1 when the feed doesn't say. */
    val progress: Float,
    /** How many of your channels (and add-on streams) show it, as far as is known. */
    val streams: Int,
    val mine: Boolean,
    val hasScore: Boolean,
    val about: String?,
    val standings: List<MacStandingLine>,
)

class MacSportsStatus(
    val loading: Boolean,
    val matching: Boolean,
    val problem: String?,
    val updatedAt: Long,
    val hasChannels: Boolean,
    val followsAnything: Boolean,
    val hideScores: Boolean,
)

class MacSportsSection(val title: String, val games: List<MacSportsGame>)

/** The day page: which sports have games that day, and the day's games grouped. */
class MacSportsBrowse(val sports: List<String>, val sections: List<MacSportsSection>)

class MacSportsRow(val key: String, val title: String, val kind: String, val games: List<MacSportsGame>, val startIndex: Int, val teamLogo: String?)

class MacSportsPage(val hero: List<MacSportsGame>, val rows: List<MacSportsRow>)

class MacLeague(val id: String, val name: String, val abbr: String, val sport: String, val followed: Boolean, val hasTable: Boolean, val hasTeams: Boolean)

class MacTeam(val key: String, val leagueId: String, val id: String, val name: String, val fullName: String, val abbr: String, val logo: String?, val followed: Boolean)

class MacFollowedTeam(val key: String, val leagueId: String, val teamId: String, val name: String, val logo: String?)

class MacSportsFollows(val teams: List<MacFollowedTeam>, val leagues: List<MacLeague>, val words: List<String>)

class MacSportsStream(
    val key: String,
    val name: String,
    val logo: String?,
    val group: String,
    val source: String,
    val url: String,
    val headers: Map<String, String>,
    val quality: String?,
    val how: String,
    val sure: Boolean,
    val airing: String?,
    val isAddon: Boolean,
)

/** A game as it is now, with the streams found for it. */
class MacGameLive(val game: MacSportsGame?, val streams: List<MacSportsStream>, val replays: List<MacSportsStream>, val finding: Boolean)

class MacPlay(val clock: String, val period: String, val team: String?, val headline: String, val detail: String?, val scoreAfter: String?, val scoring: Boolean)
class MacLeader(val category: String, val name: String, val team: String?, val value: String)
class MacStat(val label: String, val away: String, val home: String, val awayShare: Double)
class MacForm(val team: String, val results: List<String>)
class MacMeeting(val dateMs: Long, val text: String)
class MacLineup(val team: String, val formation: String?, val players: List<String>)
class MacTableRow(val pos: String, val team: String, val a: String, val b: String, val c: String, val mine: Boolean)

class MacGameDetail(
    val scoring: List<MacPlay>,
    val plays: List<MacPlay>,
    val leaders: List<MacLeader>,
    val stats: List<MacStat>,
    val form: List<MacForm>,
    val meetings: List<MacMeeting>,
    val lineups: List<MacLineup>,
    val info: List<String>,
    val homeWin: Double,
    val awayWin: Double,
    val draw: Double,
    val tableTitle: String?,
    val tableHead: List<String>,
    val table: List<MacTableRow>,
)

class MacStandingsRow(val pos: Int, val name: String, val abbr: String, val logo: String?, val values: List<String>, val form: String?, val zoneLabel: String?, val zoneColor: String?, val teamId: String, val mine: Boolean)
class MacStandingsGroup(val name: String, val rows: List<MacStandingsRow>)
class MacStandingsTable(val leagueName: String, val season: String?, val columns: List<String>, val groups: List<MacStandingsGroup>, val source: String)

class MacSportsSettings(
    val region: String,
    val regionName: String,
    val chooseStream: Boolean,
    val sdOnly: Boolean,
    val hideScores: Boolean,
    val onlyOnMyChannels: Boolean,
)

/**
 * Sports for the Mac: the shared Sports hub (ESPN feeds, your channels and add-ons matched to each game, tables, follows)
 * with flat result types for SwiftUI. Games are matched against the Mac app's own Live TV playlists and guide.
 */
object MacSports {
    private val scope = macScope()
    private val repo get() = SportsRepository
    private val teamCache = HashMap<String, TeamInfo>()

    // ------------------------------------------------------------------ lifecycle

    fun start() {
        repo.start()
    }

    /** Whether the Sports page is on screen: the hub checks scores far more often while it is. */
    fun setViewing(on: Boolean) = repo.setViewing(on)

    fun refresh() = repo.refreshNow()

    fun daysBack(): Int = SportsRepository.DAYS_BACK
    fun daysAhead(): Int = SportsRepository.DAYS_AHEAD

    @OptIn(FlowPreview::class)
    fun watchStatus(onChange: (MacSportsStatus) -> Unit): MacWatch {
        val flows = listOf<kotlinx.coroutines.flow.Flow<Any?>>(
            repo.events, repo.known, repo.matches, repo.follows, repo.settings, repo.loading, repo.matching, repo.problem, repo.updatedAt,
        )
        return MacWatch(scope.launch {
            combine(flows) { it.size }.debounce(150).collect { onChange(status()) }
        })
    }

    private fun status(): MacSportsStatus {
        val s = repo.settings.value
        return MacSportsStatus(
            loading = repo.loading.value, matching = repo.matching.value, problem = repo.problem.value, updatedAt = repo.updatedAt.value,
            hasChannels = repo.channelsReady, followsAnything = !repo.follows.value.isEmpty, hideScores = s.hideScores,
        )
    }

    // ------------------------------------------------------------------ pages

    /** The games of one day ([dayOffset] 0 = today), optionally one sport, grouped the way the phone's All Events page groups them. */
    fun browse(dayOffset: Int, sport: String?): MacSportsBrowse {
        if (dayOffset < -1) repo.wantPast()
        val now = LiveTvClock.nowMs()
        val settings = repo.settings.value
        val follows = repo.follows.value
        val matches = repo.matches.value
        val dayStart = repo.dayStart(dayOffset)
        val dayEnd = repo.dayStart(dayOffset + 1)
        val active = repo.activeLeagues(settings, follows).map { it.id }.toSet() + SportsMatcher.OTHER_ID
        val filterToChannels = settings.onlyOnMyChannels && repo.channelsReady && matches.isNotEmpty()
        val dayEvents = repo.events.value.filter { ev ->
            val onDay = when {
                ev.state == GameState.POST -> {
                    val finished = if (ev.hasTime) ev.startMs else minOf(ev.endMs ?: ev.startMs, now)
                    finished in dayStart until dayEnd
                }
                ev.hasTime -> ev.startMs in dayStart until dayEnd
                ev.state == GameState.PRE -> ev.startMs in dayStart until dayEnd
                else -> dayEnd > now && ev.startMs < dayEnd && (ev.endMs ?: (ev.startMs + 1)) >= dayStart
            }
            ev.leagueId in active && onDay &&
                (!filterToChannels || ev.state == GameState.POST || SportsLiveWatch.isMine(ev, follows) || matches[ev.id]?.isNotEmpty() == true)
        }
        val order = SportsCatalog.sportsOrder(settings)
        val sports = dayEvents.mapNotNull { SportsCatalog.league(it.leagueId)?.sport }.distinct()
            .sortedBy { order.indexOf(it).let { i -> if (i < 0) 99 else i } }
        val shown = if (sport == null) dayEvents else dayEvents.filter { SportsCatalog.league(it.leagueId)?.sport?.label == sport }
        val leagueRank = SportsCatalog.ordered(settings).mapIndexed { i, l -> l.id to i }.toMap()
        fun rank(ev: SportsEvent) = leagueRank[ev.leagueId] ?: 999
        fun mine(ev: SportsEvent) = SportsLiveWatch.isMine(ev, follows)
        fun airingNow(ev: SportsEvent): Boolean = matches[ev.id]?.any { m -> m.program?.let { now >= it.startMs && now < it.stopMs } == true } == true
        val weekLong = shown.filter { !it.hasTime && it.state == GameState.LIVE && !airingNow(it) }
        val weekIds = weekLong.mapTo(HashSet()) { it.id }
        val live = shown.filter { it.state == GameState.LIVE && it.id !in weekIds }
            .sortedWith(compareByDescending<SportsEvent> { mine(it) }.thenByDescending { matches[it.id]?.isNotEmpty() == true }.thenBy { rank(it) }.thenBy { it.startMs })
        val upcoming = shown.filter { it.state == GameState.PRE || it.state == GameState.OFF }
            .sortedWith(compareBy<SportsEvent> { if (it.hasTime) it.startMs else Long.MIN_VALUE }.thenByDescending { mine(it) }.thenBy { rank(it) })
        val finished = shown.filter { it.state == GameState.POST }.sortedWith(compareByDescending<SportsEvent> { it.startMs }.thenBy { rank(it) })
        val sections = buildList {
            if (live.isNotEmpty()) add(MacSportsSection("Live now", live.map { game(it, follows, matches) }))
            if (weekLong.isNotEmpty()) add(MacSportsSection("On this week", weekLong.map { game(it, follows, matches) }))
            if (upcoming.isNotEmpty()) add(MacSportsSection("Upcoming", upcoming.map { game(it, follows, matches) }))
            if (finished.isNotEmpty()) add(MacSportsSection("Finished", finished.map { game(it, follows, matches) }))
        }
        return MacSportsBrowse(sports.map { it.label }, sections)
    }

    /** My Sports: what is on now and next across everything followed, then a row per team and league. */
    fun mine(): MacSportsPage {
        val follows = repo.follows.value
        val matches = repo.matches.value
        val page = SportsRows.build(repo.known.value, follows, LiveTvClock.nowMs()) { SportsLiveWatch.isMine(it, follows) }
        return MacSportsPage(
            hero = page.heroes.map { game(it, follows, matches) },
            rows = page.rows.map { r ->
                MacSportsRow(r.key, r.title, r.kind.name.lowercase(), r.events.map { game(it, follows, matches) }, r.startIndex, r.team?.logo)
            },
        )
    }

    // ------------------------------------------------------------------ one game

    fun game(id: String): MacSportsGame? = repo.eventById(id)?.let { game(it, repo.follows.value, repo.matches.value) }

    /** Starts looking for channels that show the game and keeps reporting what is found, until cancelled. */
    fun watchGame(id: String, onChange: (MacGameLive) -> Unit): MacWatch {
        val ev = repo.eventById(id)
        if (ev != null) repo.openGame(ev)
        val flows = listOf<kotlinx.coroutines.flow.Flow<Any?>>(repo.events, repo.known, repo.matches, repo.vodMatches, repo.matching, repo.settings, repo.follows)
        val job: Job = scope.launch {
            combine(flows) { it.size }.debounce(100).collect { onChange(gameLive(id)) }
        }
        return MacWatch(job)
    }

    /** The game page was left. */
    fun closeGame(id: String) = repo.closeGame(id)

    private fun gameLive(id: String): MacGameLive {
        val follows = repo.follows.value
        val settings = repo.settings.value
        val matches = repo.matches.value
        val ev = repo.eventById(id)
        val ordered = SportsStreams.ordered(matches[id].orEmpty(), settings)
        val replays = repo.vodMatches.value[id].orEmpty()
        return MacGameLive(
            game = ev?.let { game(it, follows, matches) },
            streams = ordered.map(::stream),
            replays = replays.map(::stream),
            finding = repo.matching.value,
        )
    }

    /** Looks for this one game's channels now (Play does not wait for the day's whole round). */
    fun findStreams(id: String, done: (List<MacSportsStream>) -> Unit) {
        val ev = repo.eventById(id)
        if (ev == null) { done(emptyList()); return }
        scope.launch {
            val found = runCatching { repo.matchNow(ev) }.getOrDefault(emptyList())
            done(SportsStreams.ordered(found, repo.settings.value).map(::stream))
        }
    }

    fun loadDetail(id: String, done: (MacGameDetail?) -> Unit) {
        val ev = repo.eventById(id)
        if (ev == null) { done(null); return }
        scope.launch {
            val centre = runCatching { repo.gameCentre(ev) }.getOrNull()
            val extras = runCatching { repo.gameExtras(ev) }.getOrNull()
            val plays = if (centre == null || centre.scoring.isEmpty()) runCatching { repo.scoringPlays(ev) }.getOrDefault(emptyList()) else emptyList()
            if (centre == null && extras == null && plays.isEmpty()) { done(null); return@launch }
            val tableRows = extras?.table.orEmpty()
            done(MacGameDetail(
                scoring = centre?.scoring.orEmpty().map { play(it) } + plays.map {
                    MacPlay(it.clock, "", it.teamAbbr, it.text, null, listOfNotNull(it.awayScore, it.homeScore).takeIf { s -> s.size == 2 }?.joinToString(" – "), true)
                },
                plays = centre?.plays.orEmpty().filter { !it.scoring }.map { play(it) },
                leaders = centre?.leaders.orEmpty().map { MacLeader(it.category, it.name, it.teamAbbr, it.value) },
                stats = extras?.stats.orEmpty().map { s ->
                    val a = s.awayValue ?: 0.0
                    val h = s.homeValue ?: 0.0
                    MacStat(s.label, s.away, s.home, if (a + h > 0) a / (a + h) else 0.5)
                },
                form = extras?.form.orEmpty().map { MacForm(it.team, it.results) },
                meetings = extras?.meetings.orEmpty().map { MacMeeting(it.dateMs ?: 0L, it.text) },
                lineups = extras?.lineups.orEmpty().map { MacLineup(it.team, it.formation, it.players) },
                info = buildList {
                    val venue = extras?.venue ?: centre?.venue
                    val city = extras?.city ?: centre?.city
                    if (venue != null) add(listOfNotNull(venue, city).joinToString(", "))
                    extras?.conditions?.let { c -> add(listOfNotNull(c, extras.tempF?.let { "$it°F" }).joinToString(", ")) }
                    (extras?.referee ?: centre?.officials?.firstOrNull()?.let { "${it.role}: ${it.name}" })?.let { add(it) }
                    (extras?.attendance ?: centre?.attendance)?.let { add("Attendance $it") }
                },
                homeWin = extras?.homeWin ?: -1.0,
                awayWin = extras?.awayWin ?: -1.0,
                draw = extras?.draw ?: -1.0,
                tableTitle = extras?.tableTitle,
                tableHead = extras?.tableHead.orEmpty(),
                table = tableRows.map { MacTableRow(it.pos, it.team, it.a, it.b, it.c, it.mine) },
            ))
        }
    }

    private fun play(e: com.nuvio.app.features.sports.CentreEvent) =
        MacPlay(e.clock.orEmpty(), e.periodHeading, e.teamAbbr, e.headline, e.detail, e.scoreAfter, e.scoring)

    // ------------------------------------------------------------------ tables

    fun loadStandings(leagueId: String, force: Boolean, done: (MacStandingsTable?) -> Unit) {
        scope.launch {
            val table = runCatching { repo.standings(leagueId, force) }.getOrNull()
            if (table == null) { done(null); return@launch }
            val follows = repo.follows.value
            val groups = table.view(StandingsView.DIVISION, null).let { if (table.hasDivisions) table.groups else it }
            done(MacStandingsTable(
                leagueName = SportsCatalog.league(leagueId)?.name ?: leagueId,
                season = table.season,
                columns = table.columns.map { it.label },
                groups = groups.map { g ->
                    MacStandingsGroup(g.name, g.rows.map { r ->
                        MacStandingsRow(
                            pos = r.pos, name = r.name, abbr = r.abbr, logo = r.logo,
                            values = table.columns.map { c -> r.values[c.key].orEmpty() },
                            form = r.form, zoneLabel = r.zone?.label, zoneColor = r.zone?.let { hex(it.color) },
                            teamId = r.id, mine = follows.followsTeam(leagueId, r.id),
                        )
                    })
                },
                source = table.source,
            ))
        }
    }

    /** Every known game of one league, in date order (results first, then what is on and what is next). */
    fun leagueGames(leagueId: String): List<MacSportsGame> {
        val follows = repo.follows.value
        val matches = repo.matches.value
        val now = LiveTvClock.nowMs()
        val all = repo.known.value.filter { it.leagueId == leagueId }.distinctBy { it.id }.sortedBy { it.startMs }
        val done = all.filter { it.state == GameState.POST }.takeLast(10)
        val ahead = all.filter { it.state != GameState.POST && (it.state == GameState.LIVE || it.startMs >= now - 3 * 3_600_000L) }.take(60)
        return (done + ahead).map { game(it, follows, matches) }
    }

    fun hasTable(leagueId: String): Boolean = SportsCatalog.league(leagueId)?.let { repo.mayHaveTable(it) } == true

    // ------------------------------------------------------------------ leagues, teams, follows

    /** Every league the hub knows, in the order it would show them, with whether it is followed. */
    fun leagues(): List<MacLeague> {
        val follows = repo.follows.value
        return SportsCatalog.ordered(repo.settings.value).map { league(it, follows) }
    }

    fun league(id: String): MacLeague? = SportsCatalog.league(id)?.let { league(it, repo.follows.value) }

    private fun league(l: League, f: SportsFollows) = MacLeague(
        id = l.id, name = l.name, abbr = l.short, sport = l.sport.label,
        followed = l.id in f.leagues || l.id in f.pins, hasTable = repo.mayHaveTable(l), hasTeams = l.kind == LeagueKind.TEAMS && !l.guideOnly,
    )

    fun loadTeams(leagueId: String, done: (List<MacTeam>) -> Unit) {
        val league = SportsCatalog.league(leagueId)
        if (league == null) { done(emptyList()); return }
        scope.launch {
            val follows = repo.follows.value
            val teams = runCatching { repo.teams(league) }.getOrDefault(emptyList())
            teams.forEach { teamCache[it.key] = it }
            done(teams.map { MacTeam(it.key, it.leagueId, it.id, it.name, it.fullName, it.abbr, it.logo, follows.followedTeam(it) != null) })
        }
    }

    fun loadTeamGames(leagueId: String, teamId: String, done: (List<MacSportsGame>) -> Unit) {
        val team = teamCache["$leagueId:$teamId"]
        if (team == null) { done(emptyList()); return }
        scope.launch {
            val follows = repo.follows.value
            val matches = repo.matches.value
            done(runCatching { repo.teamGames(team) }.getOrDefault(emptyList()).map { game(it, follows, matches) })
        }
    }

    fun toggleTeam(leagueId: String, teamId: String) {
        teamCache["$leagueId:$teamId"]?.let { repo.toggleTeam(it) }
    }

    fun toggleLeague(leagueId: String) = repo.toggleLeague(leagueId)
    fun addWord(word: String) = repo.addWord(word)
    fun removeWord(word: String) = repo.removeWord(word)

    fun follows(): MacSportsFollows {
        val f = repo.follows.value
        return MacSportsFollows(
            teams = f.teams.map { MacFollowedTeam(it.key, it.leagueId, it.teamId, it.name, it.logo) },
            leagues = (f.pins + f.leagues).distinct().mapNotNull { SportsCatalog.league(it)?.let { l -> league(l, f) } },
            words = f.words,
        )
    }

    // ------------------------------------------------------------------ settings

    fun settings(): MacSportsSettings {
        val s = repo.settings.value
        val region = SportsCatalog.regionOf(s)
        return MacSportsSettings(region, SportsCatalog.regionName(region), s.choosePlayStream, s.sdOnly, s.hideScores, s.onlyOnMyChannels)
    }

    fun regions(): List<List<String>> = SportsCatalog.regions.map { listOf(it.first, it.second) }

    fun setRegion(code: String) = repo.updateSettings { it.copy(region = code) }
    fun setChooseStream(on: Boolean) = repo.updateSettings { it.copy(choosePlayStream = on) }
    fun setSdOnly(on: Boolean) = repo.updateSettings { it.copy(sdOnly = on) }
    fun setHideScores(on: Boolean) = repo.updateSettings { it.copy(hideScores = on) }
    fun setOnlyOnMyChannels(on: Boolean) = repo.updateSettings { it.copy(onlyOnMyChannels = on) }

    /** Remembers [streamKey] as the channel for this game, so Play picks it next time. */
    fun pickStream(gameId: String, streamKey: String) {
        repo.eventById(gameId)?.let { repo.pickChannel(it, streamKey, forNetworks = false) }
    }

    // ------------------------------------------------------------------ mapping

    private fun hex(color: Long?): String? = color?.let { "#" + (it and 0xFFFFFF).toString(16).padStart(6, '0') }

    private fun side(s: Side) = MacSide(
        name = s.team.name, abbr = s.team.abbr, logo = s.team.logo, score = s.score, record = s.record, winner = s.winner,
        isHome = s.home, colorHex = hex(s.team.color),
    )

    private fun game(ev: SportsEvent, f: SportsFollows, matches: Map<String, List<ChannelMatch>>): MacSportsGame {
        val league = SportsCatalog.league(ev.leagueId)
        val sport = league?.sport ?: Sport.OTHER
        return MacSportsGame(
            id = ev.id, leagueId = ev.leagueId, leagueName = league?.name ?: "Sport", leagueShort = league?.short ?: "", sport = sport.label,
            startMs = ev.startMs, endMs = ev.endMs ?: 0L, hasTime = ev.hasTime, state = ev.state.name.lowercase(),
            title = ev.title, subtitle = ev.subtitle, status = ev.status,
            sides = ev.ordered(sport).map(::side), separator = if (sport.homeFirst) "v" else "at",
            broadcasts = ev.broadcasts, situation = ev.situation, note = ev.note, progress = ev.progress ?: -1f,
            streams = matches[ev.id]?.size ?: 0, mine = SportsLiveWatch.isMine(ev, f), hasScore = ev.hasScore, about = ev.about,
            standings = ev.standings.map { MacStandingLine(it.pos, it.name, it.detail) },
        )
    }

    private fun stream(m: ChannelMatch) = MacSportsStream(
        key = m.channel.key, name = m.channel.name, logo = m.channel.logo, group = m.channel.group, source = m.channel.sourceName,
        url = m.channel.url, headers = m.channel.headers, quality = m.quality, how = m.how, sure = m.sure,
        airing = m.program?.title, isAddon = m.channel.sourceId == SportsAddonSource.SOURCE_ID,
    )
}
