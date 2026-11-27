package com.nuvio.app.features.sports.ui

import com.nuvio.app.features.sports.League
import com.nuvio.app.features.sports.SportsEvent
import com.nuvio.app.features.sports.compat.EpgProgram
import com.nuvio.app.features.sports.compat.LiveChannel

/** What the Sports hub does outside itself: plays channels, opens pages. */
data class SportsActions(
    val onPlay: (LiveChannel, nowTitle: String?) -> Unit,
    val onPlayCatchup: (LiveChannel, EpgProgram) -> Unit,
    val onOpenGame: (SportsEvent) -> Unit,
    val onOpenLeague: (League) -> Unit,
)
