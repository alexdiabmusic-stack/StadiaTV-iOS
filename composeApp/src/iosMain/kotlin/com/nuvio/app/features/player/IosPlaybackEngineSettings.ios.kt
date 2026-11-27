package com.nuvio.app.features.player

import platform.Foundation.NSUserDefaults

// Plain, device-wide keys: the Swift hybrid player reads exactly these (PlaybackEngineChoice.defaultsKey and
// emergencyFallbackKey) when a player is created, with no Kotlin in between.
internal actual object IosPlaybackEngineSettingsStorage {
    actual val isAvailable: Boolean = true
    private const val engineKey = "playback.engine"
    private const val emergencyFallbackKey = "playback.engine.emergencyFallback"

    actual fun loadEngine(): IosPlaybackEngine =
        IosPlaybackEngine.fromStorage(NSUserDefaults.standardUserDefaults.stringForKey(engineKey))

    actual fun saveEngine(engine: IosPlaybackEngine) {
        NSUserDefaults.standardUserDefaults.setObject(engine.storageValue, forKey = engineKey)
    }

    actual fun loadEmergencyFallback(): Boolean = NSUserDefaults.standardUserDefaults.boolForKey(emergencyFallbackKey)

    actual fun saveEmergencyFallback(enabled: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(enabled, forKey = emergencyFallbackKey)
    }
}
