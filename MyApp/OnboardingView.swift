import SwiftUI

/// Root onboarding coordinator. Manages step routing, back navigation, and commit.
struct OnboardingView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore

    @State private var step: OnboardingStep = .welcome
    @State private var store = OnboardingStore()
    @State private var sportPendingDeselect: CatalogSport?
    @State private var showDeselectAlert = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if step != .welcome {
                    OnboardingProgressBar(step: step)
                }

                stepContent
                    .frame(maxWidth: step == .welcome ? .infinity : 600)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)

                if step != .welcome {
                    OnboardingBottomBar(
                        step: step,
                        canContinue: canContinue,
                        continueLabel: continueLabel,
                        onBack: goBack,
                        onContinue: goForward
                    )
                }
            }
        }
        .tint(Theme.accent)
        .alert("Remove \(sportPendingDeselect?.name ?? "")?",
               isPresented: $showDeselectAlert,
               presenting: sportPendingDeselect) { sport in
            Button("Remove", role: .destructive) {
                store.deselectSport(sport)
            }
            Button("Keep", role: .cancel) {}
        } message: { sport in
            Text("This will also remove your \(sport.name) league selections and any favorite teams.")
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeView(
                onGetStarted: { withAnimation(.easeInOut(duration: 0.3)) { step = .sports } },
                onRestore: { prefs.completeOnboarding() }
            )
        case .sports:
            SportsSelectionView(
                store: store,
                onSportDeselect: { sport in
                    sportPendingDeselect = sport
                    showDeselectAlert = true
                }
            )
        case .favorites:
            FavoriteEntitiesView(store: store)
        case .watch:
            WatchSetupView(onSkip: commit)
        }
    }

    // MARK: - Navigation

    private var canContinue: Bool {
        switch step {
        case .sports: return store.hasAtLeastOneSport
        default: return true
        }
    }

    private var continueLabel: String {
        switch step {
        case .watch: return "Start watching"
        default: return "Continue"
        }
    }

    private func goForward() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch step {
            case .welcome:
                step = .sports
            case .sports:
                step = store.hasFavoriteScreenContent ? .favorites : .watch
            case .favorites:
                step = .watch
            case .watch:
                commit()
            }
        }
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch step {
            case .sports:
                step = .welcome
            case .favorites:
                step = .sports
            case .watch:
                step = store.hasFavoriteScreenContent ? .favorites : .sports
            case .welcome:
                break
            }
        }
    }

    private func commit() {
        store.commit(to: prefs)
    }
}
