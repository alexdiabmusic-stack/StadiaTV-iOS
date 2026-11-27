import SwiftUI

/// Account and add-ons. Sign-in and add-on handling are the shared core's; this is only the Mac presentation.
struct SettingsView: View {
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings").font(.jb(40, .bold))
                AccountCard()
                RowOrderCard()
                PlaybackCard()
                IntegrationsCard()
                AddonsCard()
                LiveTvSourcesCard()
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 96).padding(.bottom, 60)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.jb(14, .semibold)).foregroundStyle(Theme.textMuted).textCase(.uppercase).tracking(1.2)
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct AccountCard: View {
    @EnvironmentObject private var account: AccountModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Card(title: "Account") {
            switch account.phase {
            case "signedIn":
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.isAnonymous ? "Using BannerTV without an account" : (account.email ?? "Signed in")).font(.jb(20, .semibold))
                        Text(account.isAnonymous ? "Your list and progress stay on this Mac." : "Profiles, add-ons and watch history sync with your other devices.")
                            .foregroundStyle(Theme.textSecondary)
                        if let profile = account.activeProfile { Text("Profile: \(profile.name)").foregroundStyle(Theme.textSecondary) }
                    }
                    Spacer()
                    if account.profiles.count > 1 { Button("Switch Profile") { account.switchProfile() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40)) }
                    Button(account.isAnonymous ? "Sign In Instead" : "Sign Out") { account.signOut() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                }
            case "loading":
                ProgressView().controlSize(.small)
            default:
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Email", text: $email).textFieldStyle(.plain).fieldStyle().textContentType(.username)
                    SecureField("Password", text: $password).textFieldStyle(.plain).fieldStyle().textContentType(.password)
                        .onSubmit(submit)
                    HStack {
                        Button("Sign In", action: submit).buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                            .keyboardShortcut(.defaultAction)
                            .disabled(email.isEmpty || password.isEmpty || account.busy)
                        if account.busy { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let message = account.message {
                Text(message).foregroundStyle(.red).font(.jb(14))
            }
        }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        account.signIn(email: email, password: password)
    }
}

private struct AddonsCard: View {
    @EnvironmentObject private var account: AccountModel
    @State private var url = ""

    var body: some View {
        Card(title: "Add-ons") {
            HStack {
                TextField("Add-on manifest URL", text: $url).textFieldStyle(.plain).fieldStyle().onSubmit(add)
                Button("Install", action: add).buttonStyle(PillButtonStyle(kind: .secondary, height: 38)).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || account.busy)
                Button { account.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh all")
            }
            if account.addons.isEmpty {
                Text("No add-ons installed yet.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(account.addons) { row in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.jb(16, .semibold))
                        Text(row.error ?? row.detail)
                            .font(.jb(14))
                            .foregroundStyle(row.error == nil ? Theme.textSecondary : .red)
                            .lineLimit(2)
                    }
                    Spacer()
                    if row.isRefreshing { ProgressView().controlSize(.small) }
                    Toggle("", isOn: Binding(get: { row.enabled }, set: { account.setEnabled(row, $0) }))
                        .labelsHidden().toggleStyle(.switch)
                    Button(role: .destructive) { account.remove(row) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
                Divider().opacity(0.4)
            }
        }
    }

    private func add() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        account.addAddon(url: trimmed)
        url = ""
    }
}

private struct RowOrderCard: View {
    @EnvironmentObject private var home: HomeModel
    @State private var order: [String] = []

    var body: some View {
        Card(title: "Home Row Order") {
            if order.count < 2 {
                Text("Open Home once so its rows can be listed here.").foregroundStyle(Theme.textSecondary)
            } else {
                Text("Drag rows to arrange Home. The order follows your profile to your other devices.")
                    .font(.jb(14)).foregroundStyle(Theme.textSecondary)
                List {
                    ForEach(order, id: \.self) { id in
                        HStack { Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textSecondary); Text(home.titleForRow(id)) }
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        home.saveOrder(visible: order)
                    }
                }
                .scrollDisabled(true).frame(height: CGFloat(order.count) * 34 + 8)
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .onAppear { order = home.orderedRowIds }
        .onChange(of: home.shelves) { _, _ in order = home.orderedRowIds }
        .onChange(of: home.rowOrder) { _, _ in order = home.orderedRowIds }
    }
}

/// IPTV: M3U playlists, an Xtream login and extra guide (XMLTV) URLs. Kept on this Mac; the Xtream password is in the Keychain.
private struct LiveTvSourcesCard: View {
    @EnvironmentObject private var sources: LiveTvSources
    @State private var name = ""
    @State private var url = ""
    @State private var epg = ""

    var body: some View {
        Card(title: "Live TV Sources") {
            Text("Add an M3U playlist or an Xtream login. They stay on this Mac.").font(.jb(14)).foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Playlists").font(.jb(15, .semibold))
                ForEach(sources.playlists) { playlist in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(playlist.name).font(.jb(16, .semibold))
                            Text(playlist.url).font(.jb(12)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { sources.playlists.removeAll { $0 == playlist } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name", text: $name).textFieldStyle(.plain).fieldStyle().frame(width: 140)
                    TextField("Playlist URL (.m3u)", text: $url).textFieldStyle(.plain).fieldStyle().onSubmit(addPlaylist)
                    Button("Add", action: addPlaylist).buttonStyle(PillButtonStyle(kind: .secondary, height: 38)).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Xtream").font(.jb(15, .semibold))
                TextField("Server (http://host:port)", text: $sources.xtreamServer).textFieldStyle(.plain).fieldStyle()
                HStack {
                    TextField("Username", text: $sources.xtreamUser).textFieldStyle(.plain).fieldStyle()
                    SecureField("Password", text: $sources.xtreamPassword).textFieldStyle(.plain).fieldStyle()
                }
            }

            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Extra guide (XMLTV) URLs").font(.jb(15, .semibold))
                ForEach(sources.epgUrls, id: \.self) { u in
                    HStack {
                        Text(u).font(.jb(12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { sources.epgUrls.removeAll { $0 == u } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Guide URL (.xml or .xml.gz)", text: $epg).textFieldStyle(.plain).fieldStyle().onSubmit(addEpg)
                    Button("Add", action: addEpg).buttonStyle(PillButtonStyle(kind: .secondary, height: 38)).disabled(epg.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addPlaylist() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !sources.playlists.contains(where: { $0.url == u }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        sources.playlists.append(PlaylistSource(name: n.isEmpty ? (URL(string: u)?.host ?? "Playlist") : n, url: u))
        name = ""; url = ""
    }

    private func addEpg() {
        let u = epg.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !sources.epgUrls.contains(u) else { return }
        sources.epgUrls.append(u); epg = ""
    }
}

private struct PlaybackCard: View {
    @AppStorage("mac_pref_audio") private var audio = ""
    @AppStorage("mac_pref_subtitle") private var subtitle = ""
    @AppStorage("mac_pref_sub_scale") private var scale = 1.0

    var body: some View {
        Card(title: "Playback") {
            Picker("Preferred audio", selection: $audio) {
                ForEach(PlaybackPreferences.languages, id: \.code) { Text($0.name).tag($0.code) }
            }
            Picker("Preferred subtitles", selection: $subtitle) {
                Text("Off unless chosen").tag("")
                ForEach(PlaybackPreferences.languages.dropFirst(), id: \.code) { Text($0.name).tag($0.code) }
            }
            HStack {
                Text("Subtitle size")
                Slider(value: $scale, in: 0.6...2.0)
                Text("\(Int(scale * 100))%").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Text("Applies to the next video you open.").font(.jb(14)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Connected services. Each opens its own page.
private struct IntegrationsCard: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        Card(title: "Integrations") {
            row(icon: "letterboxd_icon", title: "Letterboxd", detail: "Log films to your diary, rate and review", route: .letterboxd)
            Divider().overlay(Theme.hairline)
            row(icon: "serializd_icon", title: "Serializd", detail: "Track episodes, log your diary, rate and review series", route: .serializd)
        }
    }

    private func row(icon: String, title: String, detail: String, route: Route) -> some View {
        Button { router.path.append(route) } label: {
            HStack(spacing: 14) {
                IntegrationIcon(name: icon, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.jb(16, .semibold))
                    Text(detail).font(.jb(13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
