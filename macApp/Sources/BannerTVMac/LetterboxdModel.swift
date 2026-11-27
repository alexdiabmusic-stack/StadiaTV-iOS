import BannerCore
import Foundation
import SwiftUI

/// The Letterboxd screens' state. Everything shown (status line, switches, counts, wording) comes from the shared core's
/// `LetterboxdScreenState`; this class only holds the few transient messages a screen shows after an action, and the sign-in step.
@MainActor
final class LetterboxdModel: ObservableObject {
    @Published private(set) var state: LetterboxdScreenState?
    @Published private(set) var importedCount = 0
    @Published var importNote: String?
    @Published var importing = false
    @Published var markingWatched = false
    @Published var watchlistNote: String?
    @Published var watchlistBusy = false
    @Published var verifyNote: String?
    @Published var verifying = false
    @Published var signInError: String?
    @Published var connecting = false
    @Published var showSignIn = false
    @Published var askUsername = false
    @Published var typedUsername = ""
    @Published private(set) var activity: [MacLetterboxdEvent] = []
    @Published private(set) var journal: [MacLetterboxdViewing] = []

    private var screenWatch: MacWatch?
    private var activityWatch: MacWatch?
    private var journalWatch: MacWatch?
    /// The session just signed in with, kept only while the member is asked for a username the page did not give.
    private var pending: (cookies: [String: String], agent: String)?

    init() { start() }

    /// Follows the active profile's state. Call again after a profile switch.
    func start() {
        screenWatch?.cancel()
        screenWatch = MacLetterboxd.shared.watchScreen { [weak self] s in
            self?.state = s
            self?.importedCount = Int(MacLetterboxd.shared.importedFilmCount())
        }
    }

    func watchActivity() {
        activityWatch?.cancel()
        activityWatch = MacLetterboxd.shared.watchActivity { [weak self] events in self?.activity = events }
    }
    func stopWatchingActivity() { activityWatch?.cancel(); activityWatch = nil }

    func watchJournal() {
        journalWatch?.cancel()
        journalWatch = MacLetterboxd.shared.watchJournal { [weak self] films in self?.journal = films }
    }
    func stopWatchingJournal() { journalWatch?.cancel(); journalWatch = nil }

    // MARK: sign-in

    func signedIn(cookies: [String: String], agent: String, username: String?) {
        pending = (cookies, agent)
        finishSignIn(username: username)
    }

    func submitTypedUsername() { finishSignIn(username: typedUsername.trimmingCharacters(in: .whitespaces)) }

    func cancelUsername() { pending = nil; askUsername = false }

    private func finishSignIn(username: String?) {
        guard let pending, !connecting else { return }
        connecting = true; signInError = nil
        MacLetterboxd.shared.connect(cookies: pending.cookies, userAgent: pending.agent, username: username ?? state?.username) { [weak self] result in
            guard let self else { return }
            self.connecting = false
            switch result.status {
            case "connected": self.pending = nil; self.askUsername = false; self.typedUsername = ""
            case "needsUsername": self.askUsername = true
            default: self.pending = nil; self.askUsername = false; self.signInError = result.message ?? "Letterboxd did not finish signing in. Try again."
            }
        }
    }

    // MARK: actions

    func syncNow() { MacLetterboxd.shared.syncNow { } }

    /// Reads the diary (and, when asked, marks those films watched in BannerTV), then the watchlist.
    func importHistory(markWatched: Bool) {
        guard !importing else { return }
        importing = true; importNote = nil
        MacLetterboxd.shared.importHistory(markWatched: markWatched) { [weak self] sentence in self?.importing = false; self?.importNote = sentence }
    }

    func markImportedWatched() {
        guard !markingWatched else { return }
        markingWatched = true
        MacLetterboxd.shared.markImportedWatched { [weak self] sentence in self?.markingWatched = false; self?.importNote = sentence }
    }

    func setSyncWatchlist(_ on: Bool) {
        guard !watchlistBusy else { return }
        watchlistBusy = true; watchlistNote = nil
        MacLetterboxd.shared.setSyncWatchlist(on: on) { [weak self] note in self?.watchlistBusy = false; self?.watchlistNote = note }
    }

    func verify() {
        guard !verifying else { return }
        verifying = true
        MacLetterboxd.shared.verifyConnection { [weak self] note in self?.verifying = false; self?.verifyNote = note }
    }

    func disconnect(deleteLocalHistory: Bool) {
        MacLetterboxd.shared.disconnect(deleteLocalHistory: deleteLocalHistory) { [weak self] in self?.start() }
    }

    func retryFailed() { MacLetterboxd.shared.retryFailed() }
    func setLogFilms(_ on: Bool) { MacLetterboxd.shared.setLogFilms(on: on) }
    func setSyncRatings(_ on: Bool) { MacLetterboxd.shared.setSyncRatings(on: on) }
    func setLogRewatches(_ on: Bool) { MacLetterboxd.shared.setLogRewatches(on: on) }
    func setSyncFavorites(_ on: Bool) { MacLetterboxd.shared.setSyncFavorites(on: on) }
    func setCompletionPercent(_ percent: Int) { MacLetterboxd.shared.setCompletionPercent(percent: Int32(percent)) }
    func watchlist() -> MacLetterboxdWatchlist? { MacLetterboxd.shared.watchlist() }
}
