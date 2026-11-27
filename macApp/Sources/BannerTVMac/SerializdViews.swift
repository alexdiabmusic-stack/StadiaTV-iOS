import BannerCore
import SwiftUI

// The Serializd settings on the Mac: the same two pages as the phone apps (a short main page and an Advanced page), drawn from the
// shared core's state. Wording and status decisions are the core's; these views only lay them out.


private struct SerializdMark: View {
    var size: CGFloat = 56
    var body: some View {
        IntegrationIcon(name: "serializd_icon", size: size).accessibilityLabel("Serializd")
    }
}

// MARK: - Connect

private struct ConnectCard: View {
    @ObservedObject var model: SerializdModel
    var reconnect: Bool
    var accountName: String?
    var onDone: () -> Void = {}
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !reconnect {
                HStack(spacing: 14) {
                    SerializdMark(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Serializd").font(.jb(20, .semibold))
                        Text("Track series, keep your diary, rate and review.").foregroundStyle(Theme.textSecondary).font(.jb(14))
                    }
                }
            } else {
                Text("Sign in as \(accountName ?? "your Serializd account") to keep syncing.").font(.jb(14)).foregroundStyle(Theme.textSecondary)
            }
            TextField("Serializd email", text: $email).textFieldStyle(.plain).fieldStyle().textContentType(.username).disabled(model.connecting)
            SecureField("Serializd password", text: $password).textFieldStyle(.plain).fieldStyle().textContentType(.password).disabled(model.connecting).onSubmit(submit)
            Text("Your email and password are checked with Serializd, then kept in this Mac's Keychain for this profile only. They are never sent anywhere else or written to logs, and Disconnect deletes them.")
                .font(.jb(12)).foregroundStyle(Theme.textMuted)
            if let error = model.connectError { Text(error).font(.jb(13)).foregroundStyle(toneColor(SerializdTone.problem)) }
            Button(action: submit) {
                HStack { if model.connecting { ProgressView().controlSize(.small) }; Text(model.connecting ? "Checking with Serializd…" : (reconnect ? "Sign in" : "Connect Serializd")) }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 46)).disabled(email.isEmpty || password.isEmpty || model.connecting)
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        model.connect(email: email, password: password, reconnect: reconnect) { email = ""; password = ""; onDone() }
    }
}

// MARK: - Main page

struct SerializdPage: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var account: AccountModel
    @StateObject private var model = SerializdModel()
    @State private var showDetails = false
    @State private var showWatchlist = false
    @State private var showSignIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Serializd").font(.jb(34, .bold))
                if let s = model.state {
                    if !s.connected {
                        ConnectCard(model: model, reconnect: false, accountName: nil)
                        IntegrationSection(title: "Automatic tracking", footer: "Connect your Serializd account to use these.") { trackingRows(s, enabled: false) }
                    } else {
                        accountCard(s)
                        IntegrationSection(title: "Automatic tracking", footer: model.watchlistNote) { trackingRows(s, enabled: true) }
                        dataCard(s)
                        IntegrationSection(title: "") {
                            NavRow(symbol: "slider.horizontal.3", title: "Advanced settings", detail: "Tracking, imports, sync rules and more.") { router.path.append(.serializdAdvanced) }
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
        .sheet(isPresented: $showDetails) { WatchHistorySheet(model: model) }
        .sheet(isPresented: $showWatchlist) { WatchlistSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.state?.setupPending == true }, set: { _ in })) { SetupSheet(model: model) }
    }

    private func accountCard(_ s: SerializdScreenState) -> some View {
        IntegrationSection(title: "Serializd") {
            Button { router.path.append(.serializdAdvanced) } label: {
                HStack(spacing: 14) {
                    SerializdMark(size: 56)
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
            if s.needsReconnect {
                Button { showSignIn.toggle() } label: { Text(showSignIn ? "Cancel" : "Sign in again").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 46)).padding(.horizontal, 14).padding(.bottom, 14)
                if showSignIn { ConnectCard(model: model, reconnect: true, accountName: s.username) { showSignIn = false }.padding(.horizontal, 6).padding(.bottom, 6) }
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

    @ViewBuilder private func trackingRows(_ s: SerializdScreenState, enabled: Bool) -> some View {
        SwitchRow(symbol: "play.circle", title: "Track watched episodes", detail: "Automatically track episodes you finish watching.", isOn: s.trackEpisodes, enabled: enabled) { model.setTrackEpisodes($0) }
        RowDivider()
        SwitchRow(symbol: "star", title: "Sync ratings", detail: "Send your BannerTV ratings to Serializd.", isOn: s.syncRatings, enabled: enabled) { model.setSyncRatings($0) }
        RowDivider()
        SwitchRow(symbol: "bookmark", title: "Sync watchlist", detail: "Add shows from your Serializd watchlist to My List.", isOn: s.syncWatchlist, enabled: enabled && !model.watchlistBusy) { model.setSyncWatchlist($0) }
    }

    private func dataCard(_ s: SerializdScreenState) -> some View {
        IntegrationSection(title: "Your data") {
            NavRow(symbol: "tv", title: "Watch history", detail: s.watchHistoryLine) { showDetails = true }
            RowDivider()
            NavRow(symbol: "bookmark", title: "Watchlist", detail: s.watchlistLine) { showWatchlist = true }
            RowDivider()
            NavRow(symbol: "square.and.arrow.down", title: (model.importing || s.busy) ? "Importing…" : "Import from Serializd",
                   detail: (s.busy ? s.syncHeadline : nil) ?? model.importNote ?? s.importLine, chevron: false, enabled: !(model.importing || s.busy), busy: model.importing || s.busy) { model.importNow() }
        }
    }
}

// MARK: - Advanced page

struct SerializdAdvancedPage: View {
    @EnvironmentObject private var account: AccountModel
    @StateObject private var model = SerializdModel()
    @State private var showDetails = false
    @State private var showActivity = false
    @State private var showSend = false
    @State private var confirmDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Serializd").font(.jb(34, .bold))
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
        .sheet(isPresented: $showDetails) { WatchHistorySheet(model: model) }
        .sheet(isPresented: $showActivity) { ActivitySheet(model: model) }
        .sheet(isPresented: $showSend) { SendHistorySheet(model: model) }
        .confirmationDialog("Disconnect Serializd?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect, keep local history", role: .destructive) { model.disconnect(deleteLocalHistory: false) }
            Button("Disconnect and delete local history", role: .destructive) { model.disconnect(deleteLocalHistory: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BannerTV stops sending to \(model.state?.username ?? "Serializd") and deletes the saved email, password and token from this Mac. Anything already on Serializd stays there. Waiting items are dropped. Other profiles are not affected.")
        }
    }

    private func trackingPreferences(_ s: SerializdScreenState) -> some View {
        let tracking = s.connected && s.settings.autoTrackEpisodes
        let footer: String? = !s.connected ? "Connect your Serializd account to change these."
            : (!s.settings.autoTrackEpisodes ? "Diary, rewatch and watched-threshold choices apply when Track watched episodes is on. They are kept as you set them." : nil)
        return IntegrationSection(title: "Tracking preferences", footer: footer) {
            SwitchRow(symbol: "calendar", title: "Create dated diary entries", detail: "Add episodes to your Serializd diary with the date you finished them.", isOn: s.settings.createDiaryEntries, enabled: tracking) { model.setCreateDiaryEntries($0) }
            RowDivider()
            SwitchRow(symbol: "repeat", title: "Track rewatches automatically", detail: "Automatically log when you watch an episode again.", isOn: s.settings.logRewatches, enabled: tracking) { model.setLogRewatches($0) }
            RowDivider()
            SwitchRow(symbol: "heart", title: "Sync favorites as likes", detail: "Also like shows on Serializd when you add them to My List.", isOn: s.settings.syncFavorites, enabled: s.connected) { model.setSyncFavorites($0) }
            RowDivider()
            HStack(alignment: .top, spacing: 14) {
                IconSlot(symbol: "chart.bar")
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mark as watched after").font(.jb(16, .semibold))
                        Text("Count an episode as watched when this much has been played.").font(.jb(13)).foregroundStyle(Theme.textSecondary)
                    }
                    Picker("Mark as watched after", selection: Binding(
                        get: { Int((s.settings.completionThreshold * 100).rounded()) },
                        set: { model.setCompletionPercent($0) }
                    )) {
                        Text("80%").tag(80); Text("90%").tag(90); Text("95%").tag(95)
                    }
                    .pickerStyle(.segmented).labelsHidden().disabled(!tracking)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14).opacity(tracking ? 1 : 0.5)
        }
    }

    private func transfer(_ s: SerializdScreenState) -> some View {
        IntegrationSection(title: "Import & data transfer", footer: model.historyNote) {
            NavRow(symbol: "square.and.arrow.down", title: (model.importing || s.busy) ? "Importing…" : "Import Serializd history",
                   detail: (s.busy ? s.syncHeadline : nil) ?? model.importNote ?? "Bring what you've already watched on Serializd into BannerTV.", enabled: s.connected && !(model.importing || s.busy), busy: model.importing || s.busy) { model.importNow() }
            RowDivider()
            SwitchRow(symbol: "checklist", title: "Include watched seasons", detail: "Also import seasons you marked watched on Serializd. They have no date.", isOn: s.settings.importWatchedHistory, enabled: s.connected) { model.setImportWatchedHistory($0) }
            RowDivider()
            NavRow(symbol: "icloud.and.arrow.up", title: model.sendingHistory ? "Queuing…" : "Send existing BannerTV history",
                   detail: "Add episodes you've watched in BannerTV to Serializd. Only when you choose.", enabled: s.connected && !model.sendingHistory) { showSend = true }
            RowDivider()
            NavRow(symbol: "clock.arrow.circlepath", title: "View import details", detail: s.importLine ?? "See what was imported and when.", enabled: s.connected) { showDetails = true }
        }
    }

    private func connection(_ s: SerializdScreenState) -> some View {
        IntegrationSection(title: "Connection & diagnostics", footer: s.connected ? nil : "Connect your Serializd account on the previous page.") {
            NavRow(symbol: "link", title: model.verifying ? "Verifying…" : "Verify connection", detail: model.verifyNote ?? "Check your Serializd account and sign-in.", enabled: s.connected && !model.verifying, busy: model.verifying) { model.verify() }
            RowDivider()
            NavRow(symbol: "waveform.path.ecg", title: "Sync activity", detail: "View recent syncs and any skipped items.", enabled: s.connected) { showActivity = true }
            RowDivider()
            NavRow(symbol: "arrow.clockwise", title: "Retry failed items",
                   detail: s.failedCount > 0 ? "\(s.failedCount) \(s.failedCount == 1 ? "item" : "items") didn't sync. Try sending them again." : "Nothing needs a retry.",
                   enabled: s.connected && s.failedCount > 0) { model.retryFailed() }
            RowDivider()
            NavRow(symbol: "rectangle.portrait.and.arrow.right", title: "Disconnect Serializd", tint: toneColor(SerializdTone.problem), enabled: s.connected) { confirmDisconnect = true }
        }
    }
}

// MARK: - Sheets

private struct WatchHistorySheet: View {
    @ObservedObject var model: SerializdModel

    var body: some View {
        SheetFrame(title: "Watch history", subtitle: model.state?.watchHistoryLine) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let stats = model.state?.importStats {
                        Text("Last import \(formatted(stats.atMs))").font(.jb(13)).foregroundStyle(Theme.textMuted).padding(.bottom, 6)
                        DetailLine(label: "Added", value: SerializdScreenText.shared.grouped(n: stats.added))
                        DetailLine(label: "Already known", value: SerializdScreenText.shared.grouped(n: stats.alreadyKnown))
                        DetailLine(label: "Not matched", value: SerializdScreenText.shared.grouped(n: stats.unmatched))
                        if !stats.placedByCount.isEmpty { DetailLine(label: "Placed by season count", value: SerializdScreenText.shared.grouped(n: Int32(stats.placedByCount.count))) }
                        DetailLine(label: "Diary entries read", value: SerializdScreenText.shared.grouped(n: stats.diaryEntries))
                        DetailLine(label: "Watched shows read", value: SerializdScreenText.shared.grouped(n: stats.watchedShows))
                        if stats.partial { Text("This import stopped early. Run it again to continue.").font(.jb(13)).foregroundStyle(toneColor(SerializdTone.problem)).padding(.top, 8) }
                        if !stats.notMatched.isEmpty { names("Not matched", "Serializd no longer lists these seasons, so they could not be placed without guessing.", stats.notMatched) }
                        if !stats.placedByCount.isEmpty { names("Placed by season count", "Serializd re-created these seasons' ids. Every season was marked watched, so each was placed by counting.", stats.placedByCount) }
                    } else {
                        Text((model.state?.trackedEpisodes ?? 0) > 0
                             ? "Details of earlier imports were not kept. Run Import from Serializd once and the numbers will show here."
                             : "Nothing has been imported yet. Use Import from Serializd to bring in what you have already watched there.")
                            .font(.jb(14)).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Imported history is never sent back to Serializd.").font(.jb(12)).foregroundStyle(Theme.textMuted).padding(.top, 14)
                }
            }
        }
    }

    private func names(_ title: String, _ note: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.jb(13, .semibold)).foregroundStyle(Theme.textMuted).padding(.top, 14)
            Text(note).font(.jb(12)).foregroundStyle(Theme.textMuted)
            ForEach(items, id: \.self) { Text($0).font(.jb(14)) }
        }
    }
}

private struct WatchlistSheet: View {
    @ObservedObject var model: SerializdModel
    @State private var refreshing = false
    @State private var failed = false
    @State private var list: MacSerializdWatchlist?

    var body: some View {
        SheetFrame(title: "Serializd watchlist", subtitle: list.map { "\($0.shows.count) \($0.shows.count == 1 ? "show" : "shows") · read \(formatted($0.readAtMs))" } ?? "Not read yet") {
            HStack {
                Text("Read only: editing the watchlist is not supported from BannerTV yet.").font(.jb(12)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button(refreshing ? "Refreshing…" : "Refresh") {
                    refreshing = true; failed = false
                    MacSerializd.shared.refreshWatchlist { ok in refreshing = false; failed = !ok.boolValue; list = model.watchlist() }
                }.buttonStyle(PillButtonStyle(kind: .secondary, height: 34)).disabled(refreshing)
            }
            if failed { Text("The watchlist could not be read completely, so the last full copy was kept.").font(.jb(13)).foregroundStyle(toneColor(SerializdTone.warning)) }
            if let list, !list.shows.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list.shows, id: \.tmdbId) { show in
                            HStack(spacing: 12) {
                                AsyncImage(url: show.poster.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                                    .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(show.name).font(.jb(15, .semibold)).lineLimit(2)
                                    Text(show.watchedEpisodes > 0 ? "\(show.watchedEpisodes) \(show.watchedEpisodes == 1 ? "episode" : "episodes") watched" : "Not started")
                                        .font(.jb(13)).foregroundStyle(show.watchedEpisodes > 0 ? toneColor(SerializdTone.good) : Theme.textMuted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
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

private struct ActivitySheet: View {
    @ObservedObject var model: SerializdModel

    var body: some View {
        SheetFrame(title: "Sync activity", subtitle: "Review text, passwords and sign-in details are never shown here.") {
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

private struct SendHistorySheet: View {
    @ObservedObject var model: SerializdModel
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30
    @State private var withDiary = true

    var body: some View {
        SheetFrame(title: "Send your watched history?") {
            Text("Episodes you watched in BannerTV are marked watched on your Serializd account. Episodes that came from Serializd, or were already sent, are skipped. Pick how far back to go:")
                .font(.jb(14)).foregroundStyle(Theme.textSecondary)
            Picker("Range", selection: $days) { Text("Last 30 days").tag(30); Text("Last year").tag(365); Text("Everything").tag(0) }.pickerStyle(.segmented).labelsHidden()
            Toggle(isOn: $withDiary) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also add dated diary entries").font(.jb(15, .semibold))
                    Text("Only for episodes with a real watch date, up to 400 at a time. Episodes with no date get the watched mark only.").font(.jb(12)).foregroundStyle(Theme.textMuted)
                }
            }.toggleStyle(.switch)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                Button("Send") { model.sendHistory(days: days, withDiary: withDiary); dismiss() }.buttonStyle(PillButtonStyle(kind: .primary, height: 40))
            }
        }
    }
}

private struct SetupSheet: View {
    @ObservedObject var model: SerializdModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Serializd").font(.jb(24, .bold))
            Text("Connected as \(model.state?.username ?? ""). Choose how BannerTV should work with your account.").font(.jb(15))
            Text("Recommended: track episodes you finish, sync your ratings, and add your Serializd watchlist to My List. What you have already watched on Serializd is read in. Nothing from BannerTV is sent to Serializd that you did not just watch.")
                .font(.jb(13)).foregroundStyle(Theme.textSecondary)
            if model.setupWorking {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.state?.busy == true ? (model.state?.syncHeadline ?? "Setting up…") : "Setting up…").font(.jb(14)) }
            }
            HStack {
                Spacer()
                Button("Customize Settings") { model.completeSetup(recommended: false) }.buttonStyle(PillButtonStyle(kind: .secondary, height: 42)).disabled(model.setupWorking)
                Button("Use Recommended Settings") { model.completeSetup(recommended: true) }.buttonStyle(PillButtonStyle(kind: .primary, height: 42)).disabled(model.setupWorking)
            }
        }
        .padding(26).frame(width: 520).background(Theme.background).interactiveDismissDisabled()
    }
}
