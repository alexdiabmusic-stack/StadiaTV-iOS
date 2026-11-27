package com.nuvio.app.features.player

/** Which engine plays video on iOS. The Swift hybrid player reads the same stored value when a player is created. */
enum class IosPlaybackEngine(val storageValue: String, val label: String, val description: String) {
    Automatic("automatic", "Automatic (recommended)", "AetherEngine for supported streams, libmpv for what it cannot play. Falls back to libmpv if AetherEngine fails."),
    Aether("aether", "AetherEngine", "Native, energy-efficient playback. A failure is reported instead of switching engines (unless the switch option below is on)."),
    Libmpv("mpv", "libmpv", "The original player, unchanged."),
    ;

    companion object {
        fun fromStorage(value: String?): IosPlaybackEngine = entries.firstOrNull { it.storageValue == value } ?: Automatic
    }
}

/** Persists the iOS Playback Engine choice. Only iOS has a choice; other platforms report it as unavailable. */
internal expect object IosPlaybackEngineSettingsStorage {
    val isAvailable: Boolean
    fun loadEngine(): IosPlaybackEngine
    fun saveEngine(engine: IosPlaybackEngine)
    /** "Switch to libmpv if AetherEngine fails", honoured even when AetherEngine is chosen explicitly. */
    fun loadEmergencyFallback(): Boolean
    fun saveEmergencyFallback(enabled: Boolean)
}
