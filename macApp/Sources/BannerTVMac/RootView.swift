import SwiftUI

/// The window: the current page full-bleed, with the floating navigation pill on top (as on the phone), the profile
/// button at the right, and a round back button on pushed pages.
struct RootView: View {
    @Binding var selection: AppSection
    let launchURL: URL?
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var account: AccountModel
    @EnvironmentObject private var home: HomeModel

    var body: some View {
        ZStack {
            if account.stage == .ready {
                shell
                    .sheet(item: $router.sourceTarget) { SourcesView(target: $0) }
                    .onChange(of: account.addons) { _, addons in home.reloadIfNeeded(addons: addons) }
                    .onChange(of: account.activeProfile?.index) { _, _ in home.reset(); home.reloadIfNeeded(addons: account.addons) }
                    .onAppear { home.reloadIfNeeded(addons: account.addons) }
                if let request = router.playback {
                    PlayerScreen(request: request).id(request.id).transition(.opacity)
                }
            } else {
                GateView()
            }
        }
        .background(Theme.background)
        .tint(Theme.accentEnd)
    }

    private var shell: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $router.path) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .navigationDestination(for: Route.self) { route in
                        Group {
                            switch route {
                            case .title(let ref): DetailsView(ref: ref)
                            case .collection(let c): CollectionPage(collection: c)
                            case .explore: ExploreView()
                            case .game(let id): SportsGameView(id: id)
                            case .league(let id): SportsLeagueView(id: id)
                            case .serializd: SerializdPage()
                            case .serializdAdvanced: SerializdAdvancedPage()
                            case .letterboxd: LetterboxdPage()
                            case .letterboxdAdvanced: LetterboxdAdvancedPage()
                            }
                        }
                        .background(Theme.background)
                        .toolbar(.hidden, for: .windowToolbar)
                    }
                    .toolbar(.hidden, for: .windowToolbar)
            }
            if router.path.isEmpty { TopBar(selection: $selection) } else { BackBar() }
        }
        .onChange(of: selection) { _, _ in router.path.removeAll() }
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .home: HomeView()
        case .explore: ExploreView()
        case .playbackTest: PlayerTestView(initialURL: launchURL)
        case .settings: SettingsView()
        case .library: LibraryView()
        case .search: SearchView()
        case .liveTV: LiveTvView()
        case .guide: LiveTvView(startOnGuide: true)
        case .sports: SportsView()
        }
    }
}

/// The floating, frosted navigation pill and the profile button.
private struct TopBar: View {
    @Binding var selection: AppSection
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                ForEach(AppSection.main) { section in
                    NavItem(section: section, selected: selection.tab == section) { selection = section }
                }
            }
            .padding(5)
            .glassCapsule()
            HStack {
                Spacer()
                ProfileMenu(selection: $selection)
            }
            .padding(.trailing, Theme.gutter)
        }
        .padding(.top, 18)
    }
}

private struct NavItem: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: section.symbol).font(.system(size: 18, weight: .semibold))
                Text(section.title).font(.jb(11, .semibold))
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(hovering ? 0.9 : 0.62))
            .frame(width: 78, height: 50)
            .background(selected ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(selected ? 0.18 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The active profile's picture; opens Settings, profile switching and sign-out.
private struct ProfileMenu: View {
    @Binding var selection: AppSection
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        Menu {
            if let profile = account.activeProfile { Text(profile.name) }
            Button("Settings") { selection = .settings }
            if account.profiles.count > 1 { Button("Switch Profile") { account.switchProfile() } }
        } label: {
            ZStack {
                Circle().fill(Color(hex: account.activeProfile?.colorHex ?? "#3185F5"))
                if let url = account.activeProfile?.avatar {
                    AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } }
                } else {
                    Text(String((account.activeProfile?.name ?? "B").prefix(1)).uppercased()).font(.jb(16, .bold))
                }
            }
            .frame(width: 44, height: 44).clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 2))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The round back button on pushed pages (clear of the window's traffic lights).
private struct BackBar: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack {
            Button { if !router.path.isEmpty { router.path.removeLast() } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(GlassCircleButtonStyle(size: 46))
                .keyboardShortcut("[", modifiers: .command)
            Spacer()
        }
        .padding(.leading, 92).padding(.top, 18)
    }
}
