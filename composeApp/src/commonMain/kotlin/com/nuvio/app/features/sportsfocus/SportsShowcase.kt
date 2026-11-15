package com.nuvio.app.features.sportsfocus

import androidx.compose.ui.focus.focusProperties
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.rounded.Insights
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NativeTabBarScrollEffect
import com.nuvio.app.core.ui.NuvioScreenHeader
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.NuvioViewAllPill
import com.nuvio.app.core.ui.NuvioViewAllPillSize
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.livetv.LiveTvRepository
import com.nuvio.app.features.news.NewsArticle
import com.nuvio.app.features.sports.GameState
import com.nuvio.app.features.sports.Side
import com.nuvio.app.features.sports.Sport
import com.nuvio.app.features.sports.SportsCatalog
import com.nuvio.app.features.sports.SportsDates
import com.nuvio.app.features.sports.SportsEvent
import com.nuvio.app.features.sports.SportsFollows
import com.nuvio.app.features.sports.SportsReminders
import com.nuvio.app.features.sports.SportsRepository
import com.nuvio.app.features.sports.SportsWatch
import com.nuvio.app.features.sports.compat.LiveTvClock
import com.nuvio.app.features.sports.ui.LeagueMark
import com.nuvio.app.features.sports.ui.SportsActions
import com.nuvio.app.features.sports.ui.SportsLiveRed
import com.nuvio.app.features.sports.ui.TeamLogo
import com.nuvio.app.features.sports.ui.bandBase
import com.nuvio.app.features.sports.ui.cornerStatus
import com.nuvio.app.features.sports.ui.countdownLabel
import com.nuvio.app.features.sports.ui.dayWord
import com.nuvio.app.features.sports.ui.eventHeadline
import com.nuvio.app.features.sports.ui.isMine
import com.nuvio.app.features.sports.ui.leagueColor
import com.nuvio.app.features.sports.ui.progressOf
import com.nuvio.app.features.sports.ui.startLabel
import com.nuvio.app.features.sports.ui.use24h
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val HOUR = 60 * 60 * 1000L
private val SHELF_GAP = 18.dp

/**
 * The Balanced Sports tab, laid out like Home: a full-bleed hero carousel of the games that matter most right now,
 * then shelves — your teams, everything live (with sport filters), finals, later today and the top stories.
 */
@Composable
fun SportsShowcaseHome(
    actions: SportsActions,
    onOpenNews: () -> Unit,
    onOpenArticle: (NewsArticle) -> Unit,
    onOpenFollowing: () -> Unit,
    onOpenLive: () -> Unit,
    onChooseTeams: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
    val repo = SportsRepository
    LaunchedEffect(Unit) { SportsReminders.start(); LiveTvRepository.ensureLoaded(); SportsNews.ensureLoaded() }
    DisposableEffect(Unit) {
        repo.setViewing(true)
        onDispose { repo.setViewing(false) }
    }
    val events by repo.events.collectAsStateWithLifecycle()
    val known by repo.known.collectAsStateWithLifecycle()
    val follows by repo.follows.collectAsStateWithLifecycle()
    val settings by repo.settings.collectAsStateWithLifecycle()
    val loading by repo.loading.collectAsStateWithLifecycle()
    val news by SportsNews.state.collectAsStateWithLifecycle()
    val finding by SportsWatch.finding.collectAsStateWithLifecycle()
    val now by produceState(LiveTvClock.nowMs()) { while (true) { value = LiveTvClock.nowMs(); delay(15_000) } }
    val minute = now / 60_000L
    val use24h = use24h()
    val hideScores = settings.hideScores
    var liveSport by rememberSaveable { mutableStateOf<String?>(null) }

    val all = remember(events, known) { (events + known).distinctBy { it.id } }
    val live = remember(all, follows, minute) { all.filter { it.state == GameState.LIVE }.sortedByDescending { isMine(it, follows) } }
    val dayStart = SportsDates.dayStart(0)
    val mineSoon = remember(all, follows, minute) {
        all.filter { isMine(it, follows) && it.state != GameState.LIVE && it.startMs in (now - 12 * HOUR)..(now + 36 * HOUR) }.sortedBy { it.startMs }
    }
    val later = remember(all, follows, minute) {
        all.filter { it.state == GameState.PRE && it.startMs in dayStart until dayStart + 24 * HOUR && !isMine(it, follows) }.sortedBy { it.startMs }
    }
    val finals = remember(all, minute) {
        all.filter { it.state == GameState.POST && it.startMs >= now - 18 * HOUR && it.sides.size == 2 }.sortedByDescending { it.startMs }
    }
    // The hero: your teams' live games, then their next ones, then the biggest live games, then what starts soonest.
    val heroes = remember(live, mineSoon, later, follows) {
        val liveMine = live.filter { isMine(it, follows) }
        val nextMine = mineSoon.filter { it.state == GameState.PRE }.take(2)
        (liveMine + nextMine + live + later.take(3)).distinctBy { it.id }.filter { it.sides.size == 2 }.take(6)
    }
    val liveSports = remember(live) { live.mapNotNull { SportsCatalog.league(it.leagueId)?.sport }.distinct() }
    val liveShown = remember(live, liveSport) {
        if (liveSport == null) live else live.filter { SportsCatalog.league(it.leagueId)?.sport?.name == liveSport }
    }
    val stories = remember(news) { SportsNews.merged(news).take(10) }

    // Look up streams for what is on screen first, so Watch is instant.
    LaunchedEffect(heroes.map { it.id }, live.take(4).map { it.id }) {
        (heroes + live.take(4)).filter { it.state == GameState.LIVE }.distinctBy { it.id }.forEach { SportsWatch.warm(it) }
    }

    val listState = rememberLazyListState()
    NativeTabBarScrollEffect(listState = listState, enabled = true)
    val open = { ev: SportsEvent -> actions.watchOrOpen(ev) }
    val details = { ev: SportsEvent -> actions.onOpenGame(ev) }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize().background(tokens.colors.background),
        contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
    ) {
        if (heroes.isNotEmpty()) {
            item(key = "hero") {
                SportsHeroCarousel(heroes, finding, hideScores, use24h, now, onWatch = open, onDetails = details)
            }
        } else {
            item(key = "title") { NuvioScreenHeader(title = "Sports", modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
        }
        item(key = "my-teams") { MyTeamsStrip(onChoose = onChooseTeams, modifier = Modifier.padding(top = 20.dp, bottom = SHELF_GAP)) }

        if (loading && all.isEmpty()) {
            item(key = "loading") {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    repeat(2) { com.nuvio.app.core.ui.SkeletonBlock(modifier = Modifier.width(272.dp), height = 150.dp, cornerRadius = 14.dp) }
                }
            }
        }

        if (mineSoon.isNotEmpty()) {
            item(key = "mine") {
                NuvioShelfSection(
                    title = "Your Teams",
                    entries = mineSoon.take(12),
                    modifier = Modifier.padding(bottom = SHELF_GAP),
                    headerHorizontalPadding = 16.dp,
                    rowContentPadding = PaddingValues(horizontal = 16.dp),
                    onViewAllClick = onOpenFollowing,
                    key = { "mine-" + it.id },
                ) { ev -> ScoreCard(ev, follows, now, use24h, hideScores, onClick = { open(ev) }, onDetails = { details(ev) }) }
            }
        }

        if (live.isNotEmpty()) {
            item(key = "live") {
                Column(Modifier.padding(bottom = SHELF_GAP), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        LiveDot()
                        Text("Live Now", style = MaterialTheme.typography.titleLarge, color = tokens.colors.textPrimary, modifier = Modifier.padding(start = 10.dp).weight(1f))
                        NuvioViewAllPill(onClick = onOpenLive, size = NuvioViewAllPillSize.Default)
                    }
                    if (liveSports.size > 1) {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            item(key = "all") { PillChip("All", selected = liveSport == null, onClick = { liveSport = null }) }
                            items(liveSports, key = { it.name }) { sport -> PillChip(sport.label, selected = liveSport == sport.name, onClick = { liveSport = sport.name }) }
                        }
                    }
                    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(liveShown.take(20), key = { "live-" + it.id }) { ev ->
                            ScoreCard(ev, follows, now, use24h, hideScores, onClick = { open(ev) }, onDetails = { details(ev) })
                        }
                    }
                }
            }
        }

        if (later.isNotEmpty()) {
            item(key = "later") {
                NuvioShelfSection(
                    title = "Later Today",
                    entries = later.take(20),
                    modifier = Modifier.padding(bottom = SHELF_GAP),
                    headerHorizontalPadding = 16.dp,
                    rowContentPadding = PaddingValues(horizontal = 16.dp),
                    key = { "later-" + it.id },
                ) { ev -> ScoreCard(ev, follows, now, use24h, hideScores, onClick = { open(ev) }, onDetails = { details(ev) }) }
            }
        }

        if (finals.isNotEmpty() && !hideScores) {
            item(key = "finals") {
                NuvioShelfSection(
                    title = "Final Scores",
                    entries = finals.take(20),
                    modifier = Modifier.padding(bottom = SHELF_GAP),
                    headerHorizontalPadding = 16.dp,
                    rowContentPadding = PaddingValues(horizontal = 16.dp),
                    key = { "final-" + it.id },
                ) { ev -> ScoreCard(ev, follows, now, use24h, hideScores, onClick = { details(ev) }, onDetails = { details(ev) }) }
            }
        }

        if (stories.isNotEmpty()) {
            item(key = "stories") {
                NuvioShelfSection(
                    title = "Top Stories",
                    entries = stories,
                    modifier = Modifier.padding(bottom = SHELF_GAP),
                    headerHorizontalPadding = 16.dp,
                    rowContentPadding = PaddingValues(horizontal = 16.dp),
                    onViewAllClick = onOpenNews,
                    key = { "story-" + it.id },
                ) { article -> StoryCard(article) { onOpenArticle(article) } }
            }
        }
    }
}

// ------------------------------------------------------------------ hero

@Composable
private fun SportsHeroCarousel(
    games: List<SportsEvent>,
    finding: Set<String>,
    hideScores: Boolean,
    use24h: Boolean,
    now: Long,
    onWatch: (SportsEvent) -> Unit,
    onDetails: (SportsEvent) -> Unit,
) {
    val pager = rememberPagerState { games.size }
    val scope = rememberCoroutineScope()
    // Moves on by itself every few seconds, like Home's hero, and waits while it is being swiped.
    LaunchedEffect(pager, games.size) {
        if (games.size < 2) return@LaunchedEffect
        while (true) {
            delay(8_000)
            if (!pager.isScrollInProgress) pager.animateScrollToPage((pager.currentPage + 1) % games.size)
        }
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        HorizontalPager(state = pager, modifier = Modifier.fillMaxWidth().focusProperties { canFocus = false }, key = { games[it].id }) { page ->
            val ev = games[page]
            SportsHeroPage(ev, ev.id in finding, hideScores, use24h, now, onWatch = { onWatch(ev) }, onDetails = { onDetails(ev) })
        }
        if (games.size > 1) {
            Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                repeat(games.size) { index ->
                    val active = pager.currentPage == index
                    Box(
                        Modifier
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.onBackground.copy(alpha = if (active) 0.92f else 0.35f))
                            .clickable { scope.launch { pager.animateScrollToPage(index) } }
                            .width(if (active) 32.dp else 8.dp)
                            .height(8.dp),
                    )
                }
            }
        }
    }
}

/** A team colour pushed dark enough to sit behind white text and logos. */
private fun deep(c: Color): Color = lerp(c, Color(0xFF07090D), if (c.luminance() > 0.5f) 0.62f else 0.38f)

@Composable
private fun SportsHeroPage(
    ev: SportsEvent,
    finding: Boolean,
    hideScores: Boolean,
    use24h: Boolean,
    now: Long,
    onWatch: () -> Unit,
    onDetails: () -> Unit,
) {
    val tokens = MaterialTheme.nuvio
    val league = SportsCatalog.league(ev.leagueId)
    val sides = ev.ordered(league?.sport ?: Sport.OTHER)
    val left = sides.getOrNull(0)
    val right = sides.getOrNull(1)
    val leftColor = deep(left?.let { bandBase(it.team) } ?: leagueColor(league))
    val rightColor = deep(right?.let { bandBase(it.team) } ?: leagueColor(league))
    val showScore = ev.hasScore && !hideScores
    val isLive = ev.state == GameState.LIVE
    Box(Modifier.fillMaxWidth().height(500.dp).clickable(onClick = onDetails)) {
        // The two teams' colours meeting on a diagonal, with their crests huge and faint behind everything.
        Box(Modifier.fillMaxSize().background(Brush.linearGradient(0f to leftColor, 0.5f to lerp(leftColor, rightColor, 0.5f), 1f to rightColor, start = Offset(0f, 0f), end = Offset(1400f, 1800f))))
        left?.team?.logo?.let {
            AsyncImage(it, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.size(320.dp).offset(x = (-110).dp, y = 70.dp).graphicsLayer { alpha = 0.16f; rotationZ = -10f })
        }
        right?.team?.logo?.let {
            AsyncImage(it, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.size(320.dp).align(Alignment.TopEnd).offset(x = 110.dp, y = 150.dp).graphicsLayer { alpha = 0.16f; rotationZ = 10f })
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.35f), 0.3f to Color.Transparent, 0.62f to Color.Transparent, 1f to tokens.colors.background),
            ),
        )
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LeagueMark(league, 20.dp)
                Text(
                    (league?.name ?: "").uppercase(),
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.White.copy(alpha = 0.85f),
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.2.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(18.dp))
            if (left != null && right != null) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    HeroTeam(left, Modifier.weight(1f), dim = ev.state == GameState.POST && right.winner)
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(min = 110.dp)) {
                        if (showScore) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text(left.score ?: "–", fontSize = 44.sp, lineHeight = 46.sp, fontWeight = FontWeight.Black, color = Color.White, maxLines = 1)
                                Text("–", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.5f))
                                Text(right.score ?: "–", fontSize = 44.sp, lineHeight = 46.sp, fontWeight = FontWeight.Black, color = Color.White, maxLines = 1)
                            }
                        } else {
                            Text(dayWord(ev.startMs, now), style = MaterialTheme.typography.titleSmall, color = Color.White.copy(alpha = 0.75f))
                            Text(startLabel(ev, use24h), fontSize = 30.sp, lineHeight = 32.sp, fontWeight = FontWeight.Black, color = Color.White, maxLines = 1)
                        }
                    }
                    HeroTeam(right, Modifier.weight(1f), dim = ev.state == GameState.POST && left.winner)
                }
            } else {
                Text(eventHeadline(ev, league), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = Color.White, textAlign = TextAlign.Center, maxLines = 3)
            }
            Spacer(Modifier.height(14.dp))
            // The state line: live with its clock, or how long until it starts.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (isLive) {
                    Text(
                        "LIVE",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Black,
                        color = Color.White,
                        modifier = Modifier.clip(RoundedCornerShape(4.dp)).background(SportsLiveRed).padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
                val line = when (ev.state) {
                    GameState.LIVE -> cornerStatus(ev, use24h, hideScores)
                    GameState.PRE -> if (ev.hasTime) countdownLabel(ev.startMs, now).replaceFirstChar { it.uppercase() } else ev.note.orEmpty()
                    else -> cornerStatus(ev, use24h, hideScores)
                }
                if (line.isNotBlank()) Text(line, style = MaterialTheme.typography.titleSmall, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
            }
            Spacer(Modifier.height(18.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.height(44.dp).clip(RoundedCornerShape(50)).background(Color.White).clickable(onClick = onWatch).padding(horizontal = 24.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (finding) CircularProgressIndicator(color = Color.Black, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                    else Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.Black, modifier = Modifier.size(24.dp))
                    Text(if (isLive) "Watch Live" else "Watch", color = Color.Black, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                }
                Row(
                    Modifier.height(44.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.22f)).clickable(onClick = onDetails).padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Rounded.Insights, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                    Text("Game Centre", color = Color.White, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                }
            }
        }
    }
}

@Composable
private fun HeroTeam(side: Side, modifier: Modifier, dim: Boolean) {
    Column(modifier.graphicsLayer { alpha = if (dim) 0.6f else 1f }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TeamLogo(side.team, 76.dp)
        Text(
            side.team.name,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        side.record?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.65f), maxLines = 1)
        }
    }
}

@Composable
private fun LiveDot() {
    Box(Modifier.size(10.dp).clip(CircleShape).background(SportsLiveRed))
}

// ------------------------------------------------------------------ cards

/**
 * A scoreboard card for a shelf: league and state on top, the two teams with their colour as a slim bar and the
 * score on the right, and the game's progress along the bottom. A tap watches; holding it, or the stats icon,
 * opens the Game Centre.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ScoreCard(
    ev: SportsEvent,
    follows: SportsFollows,
    now: Long,
    use24h: Boolean,
    hideScores: Boolean,
    onClick: () -> Unit,
    onDetails: () -> Unit,
    modifier: Modifier = Modifier.width(272.dp),
) {
    val tokens = MaterialTheme.nuvio
    val league = SportsCatalog.league(ev.leagueId)
    val sides = ev.ordered(league?.sport ?: Sport.OTHER)
    val showScore = ev.hasScore && !hideScores
    val isLive = ev.state == GameState.LIVE
    val tint = sides.firstOrNull()?.let { deep(bandBase(it.team)) } ?: deep(leagueColor(league))
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(tokens.colors.surface)
            .background(Brush.linearGradient(0f to tint.copy(alpha = 0.55f), 0.65f to Color.Transparent, start = Offset.Zero, end = Offset(700f, 500f)))
            .combinedClickable(onClick = onClick, onLongClick = onDetails)
            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LeagueMark(league, 16.dp)
            Text(
                league?.short ?: league?.name.orEmpty(),
                style = MaterialTheme.typography.labelMedium,
                color = tokens.colors.textSecondary,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            when (ev.state) {
                GameState.LIVE -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(SportsLiveRed))
                    Text(
                        if (showScore) cornerStatus(ev, use24h, hideScores) else "Live",
                        style = MaterialTheme.typography.labelMedium,
                        color = SportsLiveRed,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                    )
                }
                GameState.PRE -> Text(
                    (if (dayWord(ev.startMs, now) == "Today") "" else dayWord(ev.startMs, now) + " ") + startLabel(ev, use24h),
                    style = MaterialTheme.typography.labelMedium,
                    color = tokens.colors.textPrimary,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                )
                else -> Text(cornerStatus(ev, use24h, hideScores), style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted, fontWeight = FontWeight.Bold, maxLines = 1)
            }
        }
        if (sides.size == 2) {
            val loser = if (ev.state == GameState.POST && sides.any { it.winner }) sides.firstOrNull { !it.winner } else null
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                sides.forEach { side ->
                    ScoreLine(side, showScore, followed = follows.followsTeam(ev.leagueId, side.team.id), dim = loser === side)
                }
            }
        } else {
            Text(
                eventHeadline(ev, league),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.height(64.dp),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f)) {
                if (isLive) {
                    val progress = progressOf(ev, now)
                    Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.14f))) {
                        Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(SportsLiveRed))
                    }
                } else {
                    val note = when (ev.state) {
                        GameState.PRE -> if (ev.hasTime) countdownLabel(ev.startMs, now).replaceFirstChar { it.uppercase() } else ev.note.orEmpty()
                        else -> dayWord(ev.startMs, now)
                    }
                    Text(note, style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted, maxLines = 1)
                }
            }
            Icon(
                Icons.Rounded.Insights,
                contentDescription = "Game Centre",
                tint = tokens.colors.textMuted,
                modifier = Modifier.size(28.dp).clip(CircleShape).clickable(onClick = onDetails).padding(5.dp),
            )
        }
    }
}

@Composable
private fun ScoreLine(side: Side, showScore: Boolean, followed: Boolean, dim: Boolean) {
    val tokens = MaterialTheme.nuvio
    val color = bandBase(side.team)
    Row(
        Modifier.graphicsLayer { alpha = if (dim) 0.55f else 1f },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.width(3.dp).height(26.dp).clip(RoundedCornerShape(2.dp)).background(lerp(color, Color.White, 0.15f)))
        TeamLogo(side.team, 28.dp)
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Text(
                side.team.name,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = if (side.winner) FontWeight.Black else FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (followed) Icon(Icons.Filled.Star, contentDescription = null, tint = Color(0xFFF5C400), modifier = Modifier.padding(start = 4.dp).size(12.dp))
        }
        if (showScore) {
            Text(side.score ?: "–", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black, color = tokens.colors.textPrimary, maxLines = 1)
        } else {
            side.record?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted, maxLines = 1) }
        }
    }
}

/** A story, shaped like Home's wide cards: the photo with the headline over its lower half. */
@Composable
private fun StoryCard(article: NewsArticle, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Box(
        Modifier.width(270.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(12.dp)).background(tokens.colors.surface).clickable(onClick = onClick),
    ) {
        article.imageUrl?.let { AsyncImage(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.3f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.88f))))
        Text(
            listOfNotNull(article.leagueShort, article.publisher).distinct().joinToString(" · ").uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            modifier = Modifier.align(Alignment.TopStart).padding(10.dp).clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 8.dp, vertical = 4.dp),
        )
        Text(
            article.headline,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomStart).padding(12.dp),
        )
    }
}
