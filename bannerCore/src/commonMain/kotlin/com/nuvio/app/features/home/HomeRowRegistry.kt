package com.nuvio.app.features.home

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A Home row as the arrange screen lists it. */
data class HomeRowInfo(val id: String, val title: String)

/**
 * The Home rows below Continue Watching that this profile can see right now, in their default order (before the user's
 * order is applied). Home publishes them each time it is built, so the arrange screen always lists exactly the rows on
 * screen, with their current titles, and applies the saved order itself.
 */
object HomeRowRegistry {
    private val _rows = MutableStateFlow<List<HomeRowInfo>>(emptyList())
    val rows: StateFlow<List<HomeRowInfo>> = _rows.asStateFlow()

    fun publish(rows: List<HomeRowInfo>) {
        if (_rows.value != rows) _rows.value = rows
    }
}
