package com.nuvio.app.features.sportsfocus

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import com.nuvio.app.features.sports.ui.vector
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.NuvioInputField
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.InteractiveBackLayer
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.sports.FollowedTeam
import com.nuvio.app.features.sports.League
import com.nuvio.app.features.sports.LeagueKind
import com.nuvio.app.features.sports.Sport
import com.nuvio.app.features.sports.SportsCatalog
import com.nuvio.app.features.sports.SportsRepository
import com.nuvio.app.features.sports.TeamInfo
import com.nuvio.app.features.sports.ui.LeagueMark
import com.nuvio.app.features.sports.ui.SportsActions
import com.nuvio.app.features.sports.ui.TeamLogo
import com.nuvio.app.features.sports.ui.bandBase
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/** The leagues offered first, as pills; every other league is a tap away under "More". */
private val FEATURED_LEAGUES = listOf(
    "hockey/nhl", "basketball/nba", "football/nfl", "baseball/mlb", "soccer/usa.1", "football/cfl",
    "soccer/eng.1", "soccer/uefa.champions", "soccer/esp.1", "soccer/ita.1", "soccer/ger.1", "basketball/wnba",
)

private fun FollowedTeam.asTeamInfo() = TeamInfo(leagueId, teamId, name, name, abbr, null, color, null, logo)

/**
 * Pick Your Teams: the teams you follow along the top (tap one to let it go), a pill for each big league, and that
 * league's teams as a grid of crests in their own colours — tap a crest to follow it. Search finds any team or league.
 */
@Composable
internal fun TeamPickerScreen(actions: SportsActions, onDone: () -> Unit, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    val repo = SportsRepository
    val haptics = LocalHapticFeedback.current
    val follows by repo.follows.collectAsStateWithLifecycle()
    val known by repo.known.collectAsStateWithLifecycle()
    val featured = remember { FEATURED_LEAGUES.mapNotNull { SportsCatalog.league(it) } }
    var extraLeague by rememberSaveable { mutableStateOf<String?>(null) }
    val startLeague = remember { follows.teams.firstOrNull()?.leagueId?.takeIf { id -> featured.any { it.id == id } } ?: featured.first().id }
    var leagueId by rememberSaveable { mutableStateOf(startLeague) }
    var query by rememberSaveable { mutableStateOf("") }
    var browsingAll by rememberSaveable { mutableStateOf(false) }
    val teamsByLeague = remember { mutableStateMapOf<String, List<TeamInfo>>() }
    val league = SportsCatalog.league(leagueId) ?: featured.first()
    val pills = remember(extraLeague) { (listOfNotNull(extraLeague?.let { SportsCatalog.league(it) }) + featured).distinctBy { it.id } }

    LaunchedEffect(league.id) {
        if (league.id !in teamsByLeague) teamsByLeague[league.id] = runCatching { repo.teams(league) }.getOrDefault(emptyList())
    }
    val q = query.trim()
    // Searching looks through every featured league's teams (fetched once) and the games already known.
    LaunchedEffect(q.length >= 2) {
        if (q.length < 2) return@LaunchedEffect
        coroutineScope {
            featured.filter { it.id !in teamsByLeague }.map { l ->
                async { l.id to runCatching { repo.teams(l) }.getOrDefault(emptyList()) }
            }.awaitAll().forEach { (id, list) -> teamsByLeague[id] = list }
        }
    }
    val toggle = { t: TeamInfo ->
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        repo.toggleTeam(t)
    }

    val main: @Composable () -> Unit = {
    Column(modifier.fillMaxSize().background(tokens.colors.background).statusBarsPadding()) {
        // Header: back, the title, and Done.
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onDone) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back", tint = tokens.colors.textPrimary) }
            Spacer(Modifier.weight(1f))
            Text(
                "Done",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = tokens.colors.background,
                modifier = Modifier.padding(end = 52.dp).clip(RoundedCornerShape(50)).background(tokens.colors.textPrimary)
                    .clickable(onClick = onDone).padding(horizontal = 18.dp, vertical = 8.dp),
            )
        }
        Text("Pick Your Teams", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = tokens.colors.textPrimary, modifier = Modifier.padding(horizontal = 16.dp))
        Text(
            "Their games come first, with alerts when they play.",
            style = MaterialTheme.typography.bodyMedium,
            color = tokens.colors.textMuted,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp),
        )
        NuvioInputField(
            value = query,
            onValueChange = { query = it },
            placeholder = "Search any team or league",
            shape = RoundedCornerShape(50),
            leadingContent = { Icon(Icons.Rounded.Search, contentDescription = null, tint = tokens.colors.textMuted) },
            trailingContent = if (query.isNotEmpty()) ({
                IconButton(onClick = { query = "" }) { Icon(Icons.Rounded.Close, contentDescription = "Clear", tint = tokens.colors.textMuted) }
            }) else null,
            modifier = Modifier.padding(horizontal = 16.dp),
        )

        BoxWithConstraints(Modifier.weight(1f)) {
            val columns = if (maxWidth > 600.dp) 5 else 3
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 16.dp, bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s24)),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (follows.teams.isNotEmpty() && q.length < 2) {
                    item(key = "mine") {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text("Following", style = MaterialTheme.typography.titleMedium, color = tokens.colors.textPrimary, modifier = Modifier.padding(horizontal = 16.dp))
                            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                items(follows.teams, key = { it.key }) { team -> FollowingBadge(team) { toggle(team.asTeamInfo()) } }
                            }
                        }
                    }
                }

                if (q.length >= 2) {
                    val leagues = SportsCatalog.all.filter { l ->
                        l.kind == LeagueKind.TEAMS && !l.guideOnly &&
                            (l.name.contains(q, true) || l.short.contains(q, true) || l.guideWords.any { it.contains(q, true) })
                    }.take(8)
                    val teams = (teamsByLeague.values.flatten() + known.flatMap { it.sides }.map { it.team })
                        .filter { it.fullName.contains(q, true) || it.name.contains(q, true) || it.abbr.equals(q, true) || (it.location?.contains(q, true) == true) }
                        .distinctBy { SportsCatalog.teamFamily(it.leagueId) + "|" + it.id }
                        .take(30)
                    if (leagues.isNotEmpty()) item(key = "s-leagues") {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(leagues, key = { it.id }) { l ->
                                LeaguePill(l, selected = false) {
                                    if (featured.none { it.id == l.id }) extraLeague = l.id
                                    leagueId = l.id
                                    query = ""
                                }
                            }
                        }
                    }
                    if (teams.isEmpty()) {
                        item(key = "s-empty") {
                            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text("No teams called “$q” yet.", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted)
                                if (q.length >= 3 && follows.words.none { it.equals(q, true) }) {
                                    PillChip("Follow “$q” as a name", selected = false, onClick = { repo.addWord(q); query = "" })
                                }
                            }
                        }
                    } else {
                        teamGrid(teams, columns, { follows.followedTeam(it) != null }, showLeague = true, onToggle = toggle)
                    }
                } else {
                    item(key = "pills") {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(pills, key = { it.id }) { l -> LeaguePill(l, selected = l.id == league.id) { leagueId = l.id } }
                            item(key = "more") { PillChip("More leagues", selected = false, onClick = { browsingAll = true }) }
                        }
                    }
                    item(key = "league-row") {
                        val followedLeague = league.id in follows.pins || league.id in follows.leagues
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            LeagueMark(league, 26.dp)
                            Text(league.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, modifier = Modifier.padding(start = 10.dp).weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            PillChip(if (followedLeague) "Following league" else "Follow league", selected = followedLeague, onClick = { repo.togglePin(league.id) })
                        }
                    }
                    val list = teamsByLeague[league.id]
                    when {
                        list == null -> item(key = "loading") {
                            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                repeat(columns) { com.nuvio.app.core.ui.SkeletonBlock(modifier = Modifier.weight(1f), height = 128.dp, cornerRadius = 16.dp) }
                            }
                        }
                        list.isEmpty() -> item(key = "none") {
                            Text("No teams to show for ${league.name}.", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, modifier = Modifier.padding(horizontal = 16.dp))
                        }
                        else -> teamGrid(list.sortedBy { it.fullName }, columns, { follows.followedTeam(it) != null }, showLeague = false, onToggle = toggle)
                    }
                }
            }
        }
    }
    }
    // "All Leagues" opens over the picker; the back swipe drags it away and shows the picker underneath.
    if (browsingAll) {
        InteractiveBackLayer(onBack = { browsingAll = false }, behind = main) {
            AllLeaguesPage(
                onBack = { browsingAll = false },
                onPick = { l ->
                    browsingAll = false
                    if (l.kind == LeagueKind.TEAMS && !l.guideOnly) {
                        if (featured.none { it.id == l.id }) extraLeague = l.id
                        leagueId = l.id
                    } else actions.onOpenLeague(l)
                },
                followed = { it.id in follows.pins || it.id in follows.leagues },
                onToggleLeague = { repo.togglePin(it.id) },
                modifier = modifier,
            )
        }
    } else main()
}

private fun androidx.compose.foundation.lazy.LazyListScope.teamGrid(
    teams: List<TeamInfo>,
    columns: Int,
    isFollowed: (TeamInfo) -> Boolean,
    showLeague: Boolean,
    onToggle: (TeamInfo) -> Unit,
) {
    val rows = teams.chunked(columns)
    items(rows.size, key = { "row-$it-" + rows[it].first().key }) { index ->
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            rows[index].forEach { t ->
                TeamTile(t, followed = isFollowed(t), showLeague = showLeague, modifier = Modifier.weight(1f)) { onToggle(t) }
            }
            repeat(columns - rows[index].size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

/** A team as a tile in its own colours: crest, name, and a check once followed. */
@Composable
private fun TeamTile(team: TeamInfo, followed: Boolean, showLeague: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val base = bandBase(team)
    val deep = lerp(base, Color(0xFF07090D), if (base.luminance() > 0.5f) 0.6f else 0.35f)
    val ring by animateColorAsState(if (followed) Color.White else Color.White.copy(alpha = 0.06f))
    val checkScale by animateFloatAsState(if (followed) 1f else 0f)
    Box(
        modifier
            .height(132.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(tokens.colors.surface)
            .background(Brush.verticalGradient(listOf(deep.copy(alpha = if (followed) 0.95f else 0.7f), deep.copy(alpha = 0.25f))))
            .border(if (followed) 2.dp else 1.dp, ring, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(10.dp),
    ) {
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            TeamLogo(team, 56.dp)
            Spacer(Modifier.height(8.dp))
            Text(
                team.name,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (showLeague) {
                Text(SportsCatalog.league(team.leagueId)?.short.orEmpty(), style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.6f), maxLines = 1)
            }
        }
        Box(
            Modifier.align(Alignment.TopEnd).size(22.dp).graphicsLayer { scaleX = checkScale; scaleY = checkScale }
                .clip(CircleShape).background(Color.White),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Check, contentDescription = if (followed) "Following" else null, tint = Color.Black, modifier = Modifier.size(15.dp))
        }
    }
}

/** A followed team along the top: its crest with a small × to stop following. */
@Composable
private fun FollowingBadge(team: FollowedTeam, onRemove: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Column(Modifier.width(64.dp).clickable(onClick = onRemove), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box {
            TeamLogo(team.asTeamInfo(), 56.dp)
            Box(
                Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-2).dp).size(20.dp).clip(CircleShape)
                    .background(tokens.colors.surfaceElevated).border(1.5.dp, tokens.colors.background, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.Close, contentDescription = "Stop following ${team.name}", tint = tokens.colors.textPrimary, modifier = Modifier.size(12.dp))
            }
        }
        Text(team.name, style = MaterialTheme.typography.labelSmall, color = tokens.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun LeaguePill(league: League, selected: Boolean, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val background by animateColorAsState(if (selected) tokens.colors.textPrimary else tokens.colors.textPrimary.copy(alpha = 0.12f))
    val content by animateColorAsState(if (selected) tokens.colors.background else tokens.colors.textPrimary)
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(background).clickable(onClick = onClick).padding(start = 8.dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LeagueMark(league, 22.dp)
        Text(league.short.ifBlank { league.name }, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = content, maxLines = 1)
    }
}

/** Every league, by sport: tap one with teams to pick from them, the + follows the whole league. */
@Composable
private fun AllLeaguesPage(
    onBack: () -> Unit,
    onPick: (League) -> Unit,
    followed: (League) -> Boolean,
    onToggleLeague: (League) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
        Column(modifier.fillMaxSize().background(tokens.colors.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back", tint = tokens.colors.textPrimary) }
            Text("All Leagues", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = tokens.colors.textPrimary)
        }
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s24)),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Sport.entries.forEach { sport ->
                val leagues = SportsCatalog.all.filter { it.sport == sport }
                if (leagues.isEmpty()) return@forEach
                item(key = "h-" + sport.name) {
                    Row(Modifier.padding(top = 14.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(sport.vector, contentDescription = null, tint = tokens.colors.textPrimary, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(sport.label, style = MaterialTheme.typography.titleMedium, color = tokens.colors.textPrimary)
                    }
                }
                items(leagues, key = { "l-" + it.id }) { l ->
                    val on = followed(l)
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tokens.colors.surface).clickable { onPick(l) }.padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        LeagueMark(l, 30.dp)
                        Column(Modifier.weight(1f)) {
                            Text(l.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            val sub = l.regions.takeIf { it.isNotEmpty() }?.joinToString(", ") { SportsCatalog.regionName(it) }.orEmpty()
                            if (sub.isNotBlank()) Text(sub, style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Box(
                            Modifier.size(32.dp).clip(CircleShape).background(if (on) tokens.colors.textPrimary else tokens.colors.textPrimary.copy(alpha = 0.12f)).clickable { onToggleLeague(l) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(if (on) Icons.Rounded.Check else Icons.Rounded.Add, contentDescription = if (on) "Following" else "Follow", tint = if (on) tokens.colors.background else tokens.colors.textPrimary, modifier = Modifier.size(18.dp))
                        }
                        if (l.kind == LeagueKind.TEAMS && !l.guideOnly) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = tokens.colors.textMuted)
                    }
                }
            }
        }
    }
}
