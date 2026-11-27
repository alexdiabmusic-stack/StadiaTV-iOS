package com.nuvio.app.features.sports.compat

import android.content.Context
import android.content.SharedPreferences

object AndroidSportsKeyValue : SportsKeyValueBackend {
    private var store: SharedPreferences? = null

    fun initialize(context: Context) { store = context.applicationContext.getSharedPreferences("sports_hub", Context.MODE_PRIVATE) }

    override fun getString(key: String): String? = store?.getString(key, null)
    override fun putString(key: String, value: String?) { store?.edit()?.apply { if (value == null) remove(key) else putString(key, value) }?.apply() }
}
