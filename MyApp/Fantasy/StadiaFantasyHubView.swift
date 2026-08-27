import SwiftUI

struct StadiaFantasyHubView: View {
    @EnvironmentObject private var nativeStore: StadiaFantasyStore
    let importedContent: AnyView?
    let onCreateLeague: () -> Void
    let onJoinLeague: () -> Void
    let onConnectESPN: () -> Void
    let onConnectSleeper: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero
                actions
                myLeagues
                if let importedContent, nativeStore.leagues.isEmpty {
                    importedSection(importedContent)
                } else {
                    importSection
                }
                Spacer(minLength: 80)
            }
            .padding(20)
            .frame(maxWidth: Theme.isPad ? 820 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .task { await nativeStore.load() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fantasy", systemImage: "trophy.fill")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.accent)
            Text("Build your team. Compete with friends. Watch your players live in Stadia.")
                .font(.title2.weight(.black))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onCreateLeague) {
                Label("Create Fantasy Team", systemImage: "plus.circle.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            Button(action: onJoinLeague) {
                Label("Join a League", systemImage: "person.2.badge.plus")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
    }

    @ViewBuilder
    private var myLeagues: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MY LEAGUES")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            if nativeStore.isLoading && nativeStore.leagues.isEmpty {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(18)
            } else if nativeStore.leagues.isEmpty {
                StadiaFantasyInfoCard(systemImage: "person.3", title: "No Stadia leagues yet", subtitle: "Create a native Fantasy league or join one with an invite code.")
            } else {
                VStack(spacing: 0) {
                    ForEach(nativeStore.leagues, id: \.league.id) { bundle in
                        Button { nativeStore.selectLeague(id: bundle.league.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: bundle.league.phase == .lobby ? "clock.badge" : "trophy.fill")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bundle.league.name)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                    Text("\(bundle.league.sport.displayName) · \(bundle.league.source.displayName) · \(bundle.teams.count)/\(bundle.league.maxTeams) teams · \(bundle.league.phase.rawValue.capitalized)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if nativeStore.selectedLeagueID == bundle.league.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        if bundle.league.id != nativeStore.leagues.last?.league.id { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    private func importedSection(_ importedContent: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IMPORTED LEAGUE")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            importedContent
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IMPORT OR CONNECT")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) {
                Button(action: onConnectESPN) { StadiaFantasyDisclosureRow(title: "ESPN Fantasy", subtitle: "Import Football, Hockey, Basketball or Baseball") }
                    .buttonStyle(.plain)
                if AppConfiguration.isSleeperFantasyProviderEnabled {
                    Divider().overlay(Theme.hairline)
                    Button(action: onConnectSleeper) { StadiaFantasyDisclosureRow(title: "Sleeper", subtitle: "Import Football league") }
                        .buttonStyle(.plain)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

struct StadiaFantasyNativeDashboardView: View {
    @EnvironmentObject private var nativeStore: StadiaFantasyStore
    @State private var showingDraft = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                leagueSelector
                if let bundle = nativeStore.selectedBundle {
                    leagueSummary(bundle)
                    if bundle.league.phase == .lobby { lobby(bundle) }
                    livePlayers
                    todayPlayers
                    if bundle.league.effectiveMode == .simulatedLeague { matchupPlaceholder(bundle) }
                    roster(bundle)
                    if bundle.league.effectiveMode == .simulatedLeague { standings(bundle) }
                    activity(bundle)
                } else {
                    StadiaFantasyInfoCard(systemImage: "trophy", title: "No active league", subtitle: "Create or join a Stadia Fantasy league to get started.")
                }
                Spacer(minLength: 80)
            }
            .padding(20)
            .frame(maxWidth: Theme.isPad ? 820 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .task { await nativeStore.load() }
        .sheet(isPresented: $showingDraft) { StadiaFantasyDraftRoomView().environmentObject(nativeStore) }
    }

    @ViewBuilder
    private var leagueSelector: some View {
        if nativeStore.leagues.count > 1 {
            Menu {
                ForEach(nativeStore.leagues, id: \.league.id) { bundle in
                    Button(bundle.league.name) { nativeStore.selectLeague(id: bundle.league.id) }
                }
            } label: {
                StadiaFantasyDisclosureRow(title: nativeStore.selectedBundle?.league.name ?? "Select League", subtitle: nativeStore.selectedBundle.map { "Stadia Fantasy · \($0.league.sport.displayName)" } ?? "Stadia Fantasy")
            }
            .buttonStyle(.plain)
        }
    }

    private func leagueSummary(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bundle.league.name)
                        .font(.title3.weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(bundle.league.sport.displayName) · \(bundle.league.source.displayName) · \(bundle.league.scoringRules.type.displayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(bundle.league.phase.rawValue.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
            if let team = nativeStore.selectedTeam {
                Text(team.displayName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func lobby(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LEAGUE LOBBY")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Text("\(bundle.teams.count) / \(bundle.league.maxTeams) teams joined")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(bundle.league.inviteCode)
                    .font(.caption.weight(.black).monospaced())
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
            if let draftDate = bundle.league.draftSettings.scheduledAt {
                Label(draftDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button { showingDraft = true } label: {
                Label("Open Draft Room", systemImage: "rectangle.grid.2x2")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private var livePlayers: some View {
        let contexts = nativeStore.liveEventContexts
        if !contexts.isEmpty {
            fantasyEventSection(title: "MY PLAYERS LIVE", systemImage: "dot.radiowaves.left.and.right", contexts: contexts)
        }
    }

    @ViewBuilder
    private var todayPlayers: some View {
        let contexts = nativeStore.todayEventContexts.filter { !$0.isLive }
        if !contexts.isEmpty {
            fantasyEventSection(title: "TODAY", systemImage: "calendar", contexts: contexts)
        }
    }

    private func fantasyEventSection(title: String, systemImage: String, contexts: [FantasyEventContext]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.heavy))
                .foregroundStyle(title.contains("LIVE") ? Theme.live : Theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(contexts) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(context.event.shortName)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Spacer()
                            Text(eventStatusText(context.event))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(context.isLive ? Theme.live : Theme.textSecondary)
                        }
                        Text(context.playerGames.map { $0.fantasyPlayer.fullName }.prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text("\(context.playerGames.count) players")
                            if context.matchedChannel != nil { Text("Watch available") }
                        }
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(12)
                    if context.id != contexts.last?.id { Divider().overlay(Theme.hairline) }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func eventStatusText(_ match: Match) -> String {
        switch match.state {
        case .live: return "LIVE"
        case .final: return "FINAL"
        case .pre: return match.date.formatted(date: .omitted, time: .shortened)
        }
    }

    private func matchupPlaceholder(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        StadiaFantasyInfoCard(systemImage: "chart.xyaxis.line", title: "Matchups ready after draft", subtitle: "Native scoring uses Stadia sports stats through the FantasyScoringEngine. Projections are not fabricated.")
    }

    private func roster(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MY TEAM")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            let entries = nativeStore.selectedRoster?.entries ?? []
            if entries.isEmpty {
                StadiaFantasyInfoCard(systemImage: "person.crop.rectangle.stack", title: "Roster empty", subtitle: "Draft NHL players to build your team.")
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.primaryPosition ?? "--")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 42, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.playerName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text([entry.nhlTeamAbbreviation, entry.eligibleSlots.map(\.displayAbbreviation).joined(separator: "/")].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if let injury = entry.injuryStatus {
                                Text(injury.uppercased())
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(Theme.starting)
                            }
                            Menu {
                                ForEach(entry.eligibleSlots + [.bench], id: \.self) { slot in
                                    Button(slot.displayName) {
                                        Task { await nativeStore.moveLineup(playerEntryID: entry.id, to: slot) }
                                    }
                                }
                                Button("Drop Player", role: .destructive) {
                                    Task { await nativeStore.drop(playerEntryID: entry.id) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .accessibilityLabel("Manage \(entry.playerName)")
                        }
                        .padding(12)
                        if entry.id != entries.last?.id { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    private func standings(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STANDINGS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(bundle.standings.sorted { $0.rank < $1.rank }) { standing in
                    let team = bundle.teams.first { $0.id == standing.teamID }
                    HStack(spacing: 10) {
                        Text("\(standing.rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24)
                        Text(team?.displayName ?? "Team")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(standing.wins)-\(standing.losses)-\(standing.ties)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(12)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func activity(_ bundle: StadiaFantasyLeagueBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTIVITY")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            if bundle.transactions.isEmpty {
                StadiaFantasyInfoCard(systemImage: "list.bullet.rectangle", title: "No activity yet", subtitle: "Draft picks, adds, drops, waivers and trades will appear here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(bundle.transactions.prefix(8)) { transaction in
                        Text(transaction.description)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }
}

struct StadiaFantasyCreateLeagueFlow: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nativeStore: StadiaFantasyStore
    @State private var selectedSport: FantasySport = .nhl
    @State private var selectedMode: StadiaFantasyMode = .personalTeam
    @State private var leagueName = ""
    @State private var teamName = ""
    @State private var maxTeams = 10
    @State private var visibility: StadiaFantasyVisibility = .private
    @State private var scoringType: StadiaFantasyScoringType = .headToHeadPoints
    @State private var rosterConfiguration = StadiaFantasyRosterConfiguration.standard
    @State private var draftDate = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var pickTimer = 90
    @State private var waiverType: StadiaFantasyWaiverSettings.WaiverType = .rollingPriority
    @State private var playoffTeams = 4

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("STADIA FANTASY", systemImage: selectedSport.symbolName)
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(Theme.accent)
                            Text(selectedMode == .personalTeam ? "Create your fantasy team" : "Create a simulated league")
                                .font(.title2.weight(.black))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Choose a sport, draft real ESPN-backed players, then track points and games inside Stadia.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

                        setupCard(title: "Fantasy Type", systemImage: "switch.2") {
                            Picker("Mode", selection: $selectedMode) {
                                ForEach(StadiaFantasyMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text(selectedMode == .personalTeam ? "One local roster for live scoring, season totals and Watch links." : "Local CPU opponents, generated schedules, standings and draft order.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        setupCard(title: "Sport & Identity", systemImage: selectedSport.symbolName) {
                            Picker("Sport", selection: $selectedSport) {
                                ForEach(FantasySport.allCases) { sport in
                                    Label(sport.longDisplayName, systemImage: sport.symbolName).tag(sport)
                                }
                            }
                            .onChange(of: selectedSport) { _, newSport in rosterConfiguration = .standard(for: newSport) }
                            TextField(selectedMode == .personalTeam ? "Team name" : "League name", text: $leagueName)
                                .textFieldStyle(.roundedBorder)
                            TextField("Your team name", text: $teamName)
                                .textFieldStyle(.roundedBorder)
                            if selectedMode == .simulatedLeague {
                                Stepper("\(maxTeams) teams", value: $maxTeams, in: 4...20, step: 2)
                                Picker("Visibility", selection: $visibility) {
                                    ForEach(StadiaFantasyVisibility.allCases) { Text($0.displayName).tag($0) }
                                }
                            }
                        }

                        setupCard(title: "Scoring", systemImage: "chart.bar.fill") {
                            Picker("Scoring", selection: $scoringType) {
                                ForEach(StadiaFantasyScoringType.allCases) { Text($0.displayName).tag($0) }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                                ForEach(StadiaFantasyScoringRules.stadiaDefault(sport: selectedSport, type: scoringType).rules.prefix(12)) { rule in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.stat.abbreviation)
                                            .font(.caption2.weight(.heavy))
                                            .foregroundStyle(Theme.textSecondary)
                                        Text(rule.points.formatted(.number.precision(.fractionLength(1))))
                                            .font(.headline.weight(.bold).monospacedDigit())
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }

                        setupCard(title: "Roster", systemImage: "person.3.fill") {
                            ForEach(FantasySportConfiguration.configuration(for: selectedSport).eligiblePositions) { slot in
                                Stepper("\(slot.displayAbbreviation)  \(rosterConfiguration.slotCounts[slot] ?? 0)", value: Binding(
                                    get: { rosterConfiguration.slotCounts[slot] ?? 0 },
                                    set: { rosterConfiguration.slotCounts[slot] = $0 }
                                ), in: 0...10)
                            }
                        }

                        setupCard(title: "Draft", systemImage: "rectangle.grid.2x2") {
                            DatePicker("Draft time", selection: $draftDate)
                            Stepper("\(pickTimer) second pick timer", value: $pickTimer, in: 30...300, step: 15)
                        }

                        if selectedMode == .simulatedLeague {
                            setupCard(title: "League Rules", systemImage: "slider.horizontal.3") {
                                Picker("Waivers", selection: $waiverType) {
                                    ForEach(StadiaFantasyWaiverSettings.WaiverType.allCases) { Text($0.rawValue.capitalized).tag($0) }
                                }
                                Stepper("\(playoffTeams) playoff teams", value: $playoffTeams, in: 2...12, step: 2)
                            }
                        }

                        Button {
                            Task {
                                await nativeStore.createLeague(createRequest)
                                if nativeStore.lastError == nil { dismiss() }
                            }
                        } label: {
                            Label(selectedMode == .personalTeam ? "Create Fantasy Team" : "Create League", systemImage: "checkmark.circle.fill")
                                .font(.headline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(leagueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let error = nativeStore.lastError {
                            StadiaFantasyInfoCard(systemImage: "exclamationmark.triangle", title: "Could not create Fantasy", subtitle: error)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Create Fantasy")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func setupCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var createRequest: StadiaFantasyCreateLeagueRequest {
        StadiaFantasyCreateLeagueRequest(
            sport: selectedSport,
            mode: selectedMode,
            leagueName: leagueName.trimmingCharacters(in: .whitespacesAndNewlines),
            teamName: teamName.trimmingCharacters(in: .whitespacesAndNewlines),
            maxTeams: selectedMode == .personalTeam ? 1 : maxTeams,
            visibility: visibility,
            scoringType: scoringType,
            rosterConfiguration: rosterConfiguration,
            scoringRules: .stadiaDefault(sport: selectedSport, type: scoringType),
            draftSettings: StadiaFantasyDraftSettings(type: .snake, scheduledAt: draftDate, pickTimerSeconds: pickTimer, draftOrderTeamIDs: []),
            waiverSettings: StadiaFantasyWaiverSettings(type: waiverType, waiverPeriodHours: 24, usesFAAB: waiverType == .faab, faabBudget: waiverType == .faab ? 100 : nil),
            tradeSettings: StadiaFantasyTradeSettings(deadline: nil, reviewType: .commissioner),
            playoffSettings: StadiaFantasyPlayoffSettings(regularSeasonPeriods: 20, playoffTeams: playoffTeams, playoffRounds: max(1, Int(log2(Double(playoffTeams)))), championshipPeriod: nil)
        )
    }
}

struct StadiaFantasyJoinLeagueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nativeStore: StadiaFantasyStore
    @State private var inviteCode = ""
    @State private var teamName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite") {
                    TextField("Invite code", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                    TextField("Your team name", text: $teamName)
                }
                Section {
                    Button {
                        Task {
                            await nativeStore.joinLeague(StadiaFantasyJoinLeagueRequest(inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines), teamName: teamName.trimmingCharacters(in: .whitespacesAndNewlines)))
                            if nativeStore.lastError == nil { dismiss() }
                        }
                    } label: {
                        Label("Join League", systemImage: "person.2.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = nativeStore.lastError {
                    Section { Text(error).foregroundStyle(Theme.starting) }
                }
            }
            .navigationTitle("Join League")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct StadiaFantasyDraftRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nativeStore: StadiaFantasyStore
    @State private var query = ""
    @State private var positionFilter: String = "All"
    @State private var teamFilter: String = "All"
    @State private var minimumPoints = 0.0
    @State private var selectedPlayer: StadiaFantasyAvailablePlayer?

    private var positions: [String] {
        ["All"] + Array(Set(nativeStore.availablePlayers.compactMap(\.position))).sorted()
    }

    private var teams: [String] {
        ["All"] + Array(Set(nativeStore.availablePlayers.compactMap(\.teamAbbreviation))).sorted()
    }

    private var filteredPlayers: [StadiaFantasyAvailablePlayer] {
        let rostered = Set(nativeStore.selectedBundle?.rosters.flatMap(\.entries).map(\.canonicalPlayerID) ?? [])
        let available = nativeStore.availablePlayers.filter { !rostered.contains($0.id) }
        let searched = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? available : available.filter { $0.fullName.localizedCaseInsensitiveContains(query) || ($0.teamAbbreviation?.localizedCaseInsensitiveContains(query) == true) || ($0.position?.localizedCaseInsensitiveContains(query) == true) }
        return searched.filter { player in
            let matchesPosition = positionFilter == "All" || player.position == positionFilter
            let matchesTeam = teamFilter == "All" || player.teamAbbreviation == teamFilter
            let matchesPoints = minimumPoints == 0 || (player.lastSeasonFantasyPoints ?? -1) >= minimumPoints
            return matchesPosition && matchesTeam && matchesPoints
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    TextField("Search players", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Picker("Position", selection: $positionFilter) {
                                ForEach(positions, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("Team", selection: $teamFilter) {
                                ForEach(teams, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        .pickerStyle(.menu)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Last season points")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(minimumPoints == 0 ? "Any" : minimumPoints.formatted(.number.precision(.fractionLength(0))))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $minimumPoints, in: 0...500, step: 10)
                                .tint(Theme.accent)
                        }
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(.horizontal, 16)
                    List(filteredPlayers) { player in
                        StadiaFantasyDraftPlayerRow(
                            player: player,
                            onOpen: { selectedPlayer = player },
                            onDraft: { Task { await nativeStore.draft(player: player) } }
                        )
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Draft Room")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await nativeStore.loadAvailablePlayers() }
            .sheet(item: $selectedPlayer) { player in
                StadiaFantasyPlayerStatsSheet(player: player)
            }
        }
    }
}

private struct StadiaFantasyDraftPlayerRow: View {
    let player: StadiaFantasyAvailablePlayer
    let onOpen: () -> Void
    let onDraft: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    StadiaFantasyPlayerHeadshot(url: player.headshotURL, name: player.fullName, size: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(player.fullName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text([player.teamAbbreviation, player.position, player.eligibleSlots.map(\.displayAbbreviation).joined(separator: "/")].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if !player.keyInfo.isEmpty {
                            Text(player.keyInfo.prefix(4).joined(separator: " · "))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(player.lastSeasonFantasyPoints.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(player.lastSeasonFantasyPoints == nil ? Theme.textTertiary : Theme.accent)
                Button("Draft", action: onDraft)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(player.fullName), \(player.teamAbbreviation ?? "team unavailable"), \(player.position ?? "position unavailable"), last season fantasy points \(player.lastSeasonFantasyPoints.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "unavailable")")
    }
}

private struct StadiaFantasyPlayerStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let player: StadiaFantasyAvailablePlayer

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            StadiaFantasyPlayerHeadshot(url: player.headshotURL, name: player.fullName, size: 72)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(player.fullName)
                                    .font(.title2.weight(.black))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                Text([player.teamAbbreviation, player.position].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("LAST SEASON")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(Theme.textSecondary)
                            HStack {
                                Text("Fantasy points")
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(player.lastSeasonFantasyPoints.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Unavailable")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            if let statLine = player.lastSeasonStatLine {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 10)], spacing: 10) {
                                    ForEach(statLine.values.sorted { $0.key.abbreviation < $1.key.abbreviation }, id: \.key) { stat, value in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(stat.abbreviation)
                                                .font(.caption2.weight(.heavy))
                                                .foregroundStyle(Theme.textSecondary)
                                            Text(value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 2))))
                                                .font(.headline.weight(.bold).monospacedDigit())
                                                .foregroundStyle(Theme.textPrimary)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                }
                            } else {
                                StadiaFantasyInfoCard(systemImage: "chart.bar.doc.horizontal", title: "Stats unavailable", subtitle: "ESPN did not return season statistics for this player in the roster feed.")
                            }
                        }
                        .padding(16)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Player Card")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct StadiaFantasyPlayerHeadshot: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.surfaceElevated)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                Text(initials)
                    .font(.caption.weight(.black))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline))
        .accessibilityHidden(true)
    }

    private var initials: String {
        String(name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
    }
}

private struct StadiaFantasyInfoCard: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct StadiaFantasyDisclosureRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
    }
}
