import BannerCore
import SwiftUI

// The Letterboxd settings on the Mac: the same two pages as Serializd (a short main page and an Advanced page), built from the same
// components and drawn from the shared core's state, whose wording matches Serializd's. Only what is Letterboxd's own differs: its web
// sign-in, the Watch Journal, and the film-specific choices.

private struct LetterboxdMark: View {
    var size: CGFloat = 56
    var body: some View {
        IntegrationIcon(name: "letterboxd_icon", size: size).accessibilityLabel("Letterboxd")
    }
}

/// The page's way in while nothing is connected, or when the saved session has to be replaced.
private struct LetterboxdConnectCard: View {
    @ObservedObject var model: LetterboxdModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LetterboxdMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Letterboxd").font(.jb(20, .semibold))
                    Text("Log films to your diary, rate and review.").foregroundStyle(Theme.textSecondary).font(.jb(14))
                }
            }
            Text("You sign in on Letterboxd's own page. BannerTV never sees your password. Only the session is kept, in this Mac's Keychain, for this profile, and Disconnect removes it.")
                .font(.jb(12)).foregroundStyle(Theme.textMuted)
            if let error = model.signInError { Text(error).font(.jb(13)).foregroundStyle(toneColor(SerializdTone.problem)) }
            Button { model.signInError = nil; model.showSignIn = true } label: {
                HStack { if model.connecting { ProgressView().controlSize(.small) }; Text(model.connecting ? "Connecting…" : "Connect Letterboxd") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 46)).disabled(model.connecting)
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Sign-in, and the one question the page may leave: the username, when Letterboxd's page did not give it.
private struct LetterboxdSignInFlow: ViewModifier {
    @ObservedObject var model: LetterboxdModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showSignIn) {
                LetterboxdSignInSheet { cookies, agent, name in model.signedIn(cookies: cookies, agent: agent, username: name) }
            }
            .sheet(isPresented: $model.askUsername) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your Letterboxd username").font(.jb(22, .bold))
                    Text("You are signed in, but the username could not be read from Letterboxd. Type it exactly as it appears in your profile address.").font(.jb(14)).foregroundStyle(Theme.textSecondary)
                    TextField("Username", text: $model.typedUsername).textFieldStyle(.plain).fieldStyle()
                    HStack {
                        Spacer()
                        Button("Cancel") { model.cancelUsername() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                        Button("Continue") { model.submitTypedUsername() }.buttonStyle(PillButtonStyle(kind: .primary, height: 40)).disabled(model.typedUsername.count < 2 || model.connecting)
                    }
                }
                .padding(26).frame(width: 480).background(Theme.background)
            }
    }
}

private extension View {
    func letterboxdSignIn(_ model: LetterboxdModel) -> some View { modifier(LetterboxdSignInFlow(model: model)) }
}

// MARK: - Main page

struct LetterboxdPage: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var account: AccountModel
    @StateObject private var model = LetterboxdModel()
    @State private var showJournal = false
    @State private var showWatchlist = false
    @State private var askImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Letterboxd").font(.jb(34, .bold))
                if let s = model.state {
                    if !s.connected {
                        LetterboxdConnectCard(model: model)
                        IntegrationSection(title: "Automatic tracking", footer: "Connect your Letterboxd account to use these.") { trackingRows(s, enabled: false) }
                    } else {
                        accountCard(s)
                        IntegrationSection(title: "Automatic tracking", footer: model.watchlistNote) { trackingRows(s, enabled: true) }
                        dataCard(s)
                        IntegrationSection(title: "") {
                            NavRow(symbol: "slider.horizontal.3", title: "Advanced settings", detail: "Tracking, imports, sync rules and more.") { router.path.append(.letterboxdAdvanced) }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 96).padding(.bottom, 60)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: account.activeProfile?.name) { _, _ in model.start() }
        .onAppear { if DebugHarness.openLetterboxdSignIn { model.showSignIn = true } }
        .sheet(isPresented: $showJournal) { WatchJournalSheet(model: model) }
        .sheet(isPresented: $showWatchlist) { LetterboxdWatchlistSheet(model: model) }
        .letterboxdSignIn(model)
        .confirmationDialog("Import your Letterboxd films", isPresented: $askImport, titleVisibility: .visible) {
            Button("Import and mark as watched") { model.importHistory(markWatched: true) }
            Button("Import to Watch Journal only") { model.importHistory(markWatched: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your diary and every film you have marked watched on Letterboxd go into the Watch Journal. Do you also want those films marked as watched in BannerTV? That keeps their watched badges and hides them from recommendations. It is saved to your BannerTV account but not sent to Trakt or Simkl. A big library takes about ten minutes; keep this page open until it finishes (progress is saved, so running it again continues where it stopped).")
        }
    }

    private func accountCard(_ s: LetterboxdScreenState) -> some View {
        IntegrationSection(title: "Letterboxd") {
            Button { router.path.append(.letterboxdAdvanced) } label: {
                HStack(spacing: 14) {
                    LetterboxdMark(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.username ?? "").font(.jb(20, .semibold)).lineLimit(1).truncationMode(.tail)
                        HStack(spacing: 6) {
                            Image(systemName: s.connectionTone.name == "Good" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(toneColor(s.connectionTone))
                            Text(s.connectionLabel).font(.jb(14)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 18).padding(.vertical, 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(s.username ?? ""), \(s.connectionLabel). Opens advanced settings.")
            RowDivider().padding(.leading, 18)
            HStack(spacing: 14) {
                Circle().fill(Color.white.opacity(0.10)).frame(width: 44, height: 44)
                    .overlay { if s.busy { ProgressView().controlSize(.small) } else { Image(systemName: s.syncTone.name == "Good" ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle").foregroundStyle(s.syncTone.name == "Good" ? Theme.textPrimary : toneColor(s.syncTone)) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.syncHeadline).font(.jb(16, .semibold))
                    if let detail = s.syncDetail { Text(detail).font(.jb(14)).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            if let error = model.signInError { Text(error).font(.jb(13)).foregroundStyle(toneColor(SerializdTone.problem)).padding(.horizontal, 18).padding(.bottom, 8) }
            if s.needsReconnect {
                Button { model.signInError = nil; model.showSignIn = true } label: {
                    HStack { if model.connecting { ProgressView().controlSize(.small) }; Text("Sign in again") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 46)).disabled(model.connecting).padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                Button { model.syncNow() } label: {
                    HStack(spacing: 8) {
                        if s.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text(s.busy ? "Syncing…" : "Sync now")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 46)).disabled(s.busy).padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder private func trackingRows(_ s: LetterboxdScreenState, enabled: Bool) -> some View {
        SwitchRow(symbol: "play.circle", title: "Log watched films", detail: "Automatically log films you finish watching.", isOn: s.logFilms, enabled: enabled) { model.setLogFilms($0) }
        RowDivider()
        SwitchRow(symbol: "star", title: "Sync ratings", detail: "Send your BannerTV ratings to Letterboxd.", isOn: s.syncRatings, enabled: enabled) { model.setSyncRatings($0) }
        RowDivider()
        SwitchRow(symbol: "bookmark", title: "Sync watchlist", detail: "Add films from your Letterboxd watchlist to My List.", isOn: s.syncWatchlist, enabled: enabled && !model.watchlistBusy) { model.setSyncWatchlist($0) }
    }

    private func dataCard(_ s: LetterboxdScreenState) -> some View {
        IntegrationSection(title: "Your data") {
            NavRow(symbol: "film", title: "Watch history", detail: s.watchHistoryLine) { showJournal = true }
            RowDivider()
            NavRow(symbol: "bookmark", title: "Watchlist", detail: s.watchlistLine) { showWatchlist = true }
            RowDivider()
            NavRow(symbol: "square.and.arrow.down", title: (model.importing || s.busy) ? "Importing…" : "Import from Letterboxd",
                   detail: (s.busy ? s.syncHeadline : nil) ?? model.importNote, chevron: false, enabled: !(model.importing || s.busy), busy: model.importing || s.busy) { askImport = true }
        }
    }
}

// MARK: - Advanced page

struct LetterboxdAdvancedPage: View {
    @EnvironmentObject private var account: AccountModel
    @StateObject private var model = LetterboxdModel()
    @State private var showJournal = false
    @State private var showActivity = false
    @State private var confirmDisconnect = false
    @State private var askImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Letterboxd").font(.jb(34, .bold))
                if let s = model.state {
                    trackingPreferences(s)
                    transfer(s)
                    connection(s)
                } else { ProgressView() }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 96).padding(.bottom, 60)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: account.activeProfile?.name) { _, _ in model.start() }
        .sheet(isPresented: $showJournal) { WatchJournalSheet(model: model) }
        .sheet(isPresented: $showActivity) { LetterboxdActivitySheet(model: model) }
        .confirmationDialog("Import your Letterboxd films", isPresented: $askImport, titleVisibility: .visible) {
            Button("Import and mark as watched") { model.importHistory(markWatched: true) }
            Button("Import to Watch Journal only") { model.importHistory(markWatched: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your diary and every film you have marked watched on Letterboxd go into the Watch Journal. Do you also want those films marked as watched in BannerTV? It is saved to your BannerTV account but not sent to Trakt or Simkl. A big library takes about ten minutes; progress is saved, so running it again continues where it stopped.")
        }
        .confirmationDialog("Disconnect Letterboxd?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect, keep Watch Journal", role: .destructive) { model.disconnect(deleteLocalHistory: false) }
            Button("Disconnect and delete journal", role: .destructive) { model.disconnect(deleteLocalHistory: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BannerTV stops sending to \(model.state?.username ?? "Letterboxd") and deletes the sign-in from this Mac. Anything already on Letterboxd stays there. Waiting items are dropped. Other profiles are not affected.")
        }
    }

    private func trackingPreferences(_ s: LetterboxdScreenState) -> some View {
        let tracking = s.connected && s.settings.autoLogMovies
        let footer: String? = !s.connected ? "Connect your Letterboxd account to change these."
            : (!s.settings.autoLogMovies ? "Rewatch and watched-threshold choices apply when Log watched films is on. They are kept as you set them." : nil)
        return IntegrationSection(title: "Tracking preferences", footer: footer) {
            SwitchRow(symbol: "repeat", title: "Track rewatches automatically", detail: "Mark a film you watched before as a rewatch.", isOn: s.settings.logRewatches, enabled: tracking) { model.setLogRewatches($0) }
            RowDivider()
            SwitchRow(symbol: "heart", title: "Sync favorites as likes", detail: "Also like films on Letterboxd when you log them from My List.", isOn: s.settings.syncFavorites, enabled: s.connected) { model.setSyncFavorites($0) }
            RowDivider()
            HStack(alignment: .top, spacing: 14) {
                IconSlot(symbol: "chart.bar")
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mark as watched after").font(.jb(16, .semibold))
                        Text("Count a film as watched when this much has been played.").font(.jb(13)).foregroundStyle(Theme.textSecondary)
                    }
                    Picker("Mark as watched after", selection: Binding(
                        get: { Int((s.settings.completionThreshold * 100).rounded()) },
                        set: { model.setCompletionPercent($0) }
                    )) {
                        Text("90%").tag(90); Text("95%").tag(95); Text("98%").tag(98)
                    }
                    .pickerStyle(.segmented).labelsHidden().disabled(!tracking)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14).opacity(tracking ? 1 : 0.5)
        }
    }

    private func transfer(_ s: LetterboxdScreenState) -> some View {
        IntegrationSection(title: "Import & data transfer") {
            NavRow(symbol: "square.and.arrow.down", title: (model.importing || s.busy) ? "Importing…" : "Import Letterboxd history",
                   detail: (s.busy ? s.syncHeadline : nil) ?? model.importNote ?? "Bring your diary and the films you've watched on Letterboxd into BannerTV.", enabled: s.connected && !(model.importing || s.busy), busy: model.importing || s.busy) { askImport = true }
            if model.importedCount > 0 {
                RowDivider()
                NavRow(symbol: "checkmark.circle", title: model.markingWatched ? "Marking…" : "Mark imported films as watched",
                       detail: "Marks the \(LetterboxdScreenText.shared.films(count: Int32(model.importedCount))) imported from Letterboxd as watched in BannerTV. Films already marked are skipped.",
                       enabled: s.connected && !model.markingWatched, busy: model.markingWatched) { model.markImportedWatched() }
            }
            RowDivider()
            NavRow(symbol: "books.vertical", title: "View Watch Journal", detail: "The films you finished here, and how each stands on Letterboxd.", enabled: s.connected) { showJournal = true }
        }
    }

    private func connection(_ s: LetterboxdScreenState) -> some View {
        IntegrationSection(title: "Connection & diagnostics", footer: s.connected ? nil : "Connect your Letterboxd account on the previous page.") {
            NavRow(symbol: "link", title: model.verifying ? "Verifying…" : "Verify connection", detail: model.verifyNote ?? "Check your Letterboxd account and sign-in.", enabled: s.connected && !model.verifying, busy: model.verifying) { model.verify() }
            RowDivider()
            NavRow(symbol: "waveform.path.ecg", title: "Sync activity", detail: "View recent syncs and any skipped items.", enabled: s.connected) { showActivity = true }
            RowDivider()
            NavRow(symbol: "arrow.clockwise", title: "Retry failed items",
                   detail: s.failedCount > 0 ? "\(s.failedCount) \(s.failedCount == 1 ? "item" : "items") didn't sync. Try sending them again." : "Nothing needs a retry.",
                   enabled: s.connected && s.failedCount > 0) { model.retryFailed() }
            RowDivider()
            NavRow(symbol: "rectangle.portrait.and.arrow.right", title: "Disconnect Letterboxd", tint: toneColor(SerializdTone.problem), enabled: s.connected) { confirmDisconnect = true }
        }
    }
}

// MARK: - Sheets

private struct WatchJournalSheet: View {
    @ObservedObject var model: LetterboxdModel

    var body: some View {
        SheetFrame(title: "Watch Journal", subtitle: model.state?.watchHistoryLine) {
            if model.journal.isEmpty {
                Text("Nothing here yet. Films you finish playing, and films you import, will appear here.").font(.jb(14)).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.journal, id: \.id) { film in
                            HStack(spacing: 12) {
                                AsyncImage(url: film.poster.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                                    .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(film.title).font(.jb(15, .semibold)).lineLimit(2)
                                    Text(film.detail).font(.jb(13)).foregroundStyle(Theme.textSecondary)
                                    Text(film.status).font(.jb(13)).foregroundStyle(toneColor(name: film.tone))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
        .onAppear { model.watchJournal() }
        .onDisappear { model.stopWatchingJournal() }
    }
}

private struct LetterboxdWatchlistSheet: View {
    @ObservedObject var model: LetterboxdModel
    @State private var refreshing = false
    @State private var failed = false
    @State private var list: MacLetterboxdWatchlist?

    var body: some View {
        SheetFrame(title: "Letterboxd watchlist", subtitle: list.map { "\(LetterboxdScreenText.shared.films(count: Int32($0.films.count))) · read \(formatted($0.readAtMs))" } ?? "Not read yet") {
            HStack {
                Text("Read only: editing the watchlist is not supported from BannerTV.").font(.jb(12)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button(refreshing ? "Refreshing…" : "Refresh") {
                    refreshing = true; failed = false
                    MacLetterboxd.shared.refreshWatchlist { ok in refreshing = false; failed = !ok.boolValue; list = model.watchlist() }
                }.buttonStyle(PillButtonStyle(kind: .secondary, height: 34)).disabled(refreshing)
            }
            if failed { Text("The watchlist could not be read completely, so the last full copy was kept.").font(.jb(13)).foregroundStyle(toneColor(SerializdTone.warning)) }
            if let list, !list.films.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list.films, id: \.tmdbId) { film in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(film.title).font(.jb(15, .semibold)).lineLimit(2)
                                if let year = film.year { Text(year).font(.jb(13)).foregroundStyle(Theme.textMuted) }
                            }
                            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            } else {
                Text(list == nil ? "Press Refresh to read your watchlist." : "Your watchlist is empty.").font(.jb(14)).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            }
        }
        .onAppear { list = model.watchlist() }
    }
}

private struct LetterboxdActivitySheet: View {
    @ObservedObject var model: LetterboxdModel

    var body: some View {
        SheetFrame(title: "Sync activity", subtitle: "Review text and sign-in details are never shown here.") {
            HStack { Spacer(); if (model.state?.failedCount ?? 0) > 0 { Button("Retry all") { model.retryFailed() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 34)) } }
            if model.activity.isEmpty {
                Text("No activity yet.").font(.jb(14)).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.activity, id: \.id) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.jb(15, .semibold)).lineLimit(1)
                                Text("\(e.kind) · \(e.status) · \(formatted(e.atMs))").font(.jb(13)).foregroundStyle(Theme.textSecondary)
                                if let note = e.note { Text(note).font(.jb(12)).foregroundStyle(e.issue ? toneColor(SerializdTone.warning) : Theme.textMuted) }
                            }
                            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
        .onAppear { model.watchActivity() }
        .onDisappear { model.stopWatchingActivity() }
    }
}
