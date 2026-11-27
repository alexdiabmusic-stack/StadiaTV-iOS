import BannerCore
import Foundation
import SwiftUI

/// The Serializd screens' state. Everything shown (status line, switches, counts, wording) comes from the shared core's
/// `SerializdScreenState`; this class only holds the few transient messages a screen shows after an action.
@MainActor
final class SerializdModel: ObservableObject {
    @Published private(set) var state: SerializdScreenState?
    @Published var importNote: String?
    @Published var importing = false
    @Published var watchlistNote: String?
    @Published var watchlistBusy = false
    @Published var verifyNote: String?
    @Published var verifying = false
    @Published var setupWorking = false
    @Published var historyNote: String?
    @Published var sendingHistory = false
    @Published var connectError: String?
    @Published var connecting = false
    @Published private(set) var activity: [MacSerializdEvent] = []

    private var screenWatch: MacWatch?
    private var activityWatch: MacWatch?

    init() { start() }

    /// Follows the active profile's state. Call again after a profile switch.
    func start() {
        screenWatch?.cancel()
        screenWatch = MacSerializd.shared.watchScreen { [weak self] s in self?.state = s }
    }

    func watchActivity() {
        activityWatch?.cancel()
        activityWatch = MacSerializd.shared.watchActivity { [weak self] events in self?.activity = events }
    }

    func stopWatchingActivity() { activityWatch?.cancel(); activityWatch = nil }

    // MARK: actions

    func connect(email: String, password: String, reconnect: Bool, done: @escaping () -> Void) {
        guard !connecting else { return }
        connecting = true; connectError = nil
        MacSerializd.shared.connect(email: email, password: password, reconnect: reconnect) { [weak self] message in
            self?.connecting = false
            self?.connectError = message
            if message == nil { done() }
        }
    }

    func syncNow() { MacSerializd.shared.syncNow { } }

    func importNow() {
        guard !importing else { return }
        importing = true; importNote = nil
        MacSerializd.shared.importNow { [weak self] sentence in self?.importing = false; self?.importNote = sentence }
    }

    func setSyncWatchlist(_ on: Bool) {
        guard !watchlistBusy else { return }
        watchlistBusy = true; watchlistNote = nil
        MacSerializd.shared.setSyncWatchlist(on: on) { [weak self] note in self?.watchlistBusy = false; self?.watchlistNote = note }
    }

    func verify() {
        guard !verifying else { return }
        verifying = true
        MacSerializd.shared.verifyConnection { [weak self] note in self?.verifying = false; self?.verifyNote = note }
    }

    func completeSetup(recommended: Bool) {
        guard !setupWorking else { return }
        setupWorking = true
        MacSerializd.shared.completeSetup(recommended: recommended) { [weak self] in self?.setupWorking = false }
    }

    func sendHistory(days: Int, withDiary: Bool) {
        guard !sendingHistory else { return }
        sendingHistory = true; historyNote = nil
        MacSerializd.shared.sendHistory(days: Int32(days), withDiary: withDiary) { [weak self] note in self?.sendingHistory = false; self?.historyNote = note }
    }

    func disconnect(deleteLocalHistory: Bool) {
        MacSerializd.shared.disconnect(deleteLocalHistory: deleteLocalHistory) { [weak self] in self?.start() }
    }

    func retryFailed() { MacSerializd.shared.retryFailed() }
    func setTrackEpisodes(_ on: Bool) { MacSerializd.shared.setTrackEpisodes(on: on) }
    func setSyncRatings(_ on: Bool) { MacSerializd.shared.setSyncRatings(on: on) }
    func setCreateDiaryEntries(_ on: Bool) { MacSerializd.shared.setCreateDiaryEntries(on: on) }
    func setLogRewatches(_ on: Bool) { MacSerializd.shared.setLogRewatches(on: on) }
    func setSyncFavorites(_ on: Bool) { MacSerializd.shared.setSyncFavorites(on: on) }
    func setImportWatchedHistory(_ on: Bool) { MacSerializd.shared.setImportWatchedHistory(on: on) }
    func setCompletionPercent(_ percent: Int) { MacSerializd.shared.setCompletionPercent(percent: Int32(percent)) }
    func watchlist() -> MacSerializdWatchlist? { MacSerializd.shared.watchlist() }
}
