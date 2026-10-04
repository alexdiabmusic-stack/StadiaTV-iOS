import SwiftUI

/// Shared shell for the redesigned Game Detail screen: hero, watch card and tabs
/// stay pinned above the content (not inside a scroll view), so they're always
/// visible without the nested-scroll-view problems a "sticky tab bar inside one
/// big ScrollView" would create for tabs (Play-by-Play, Shot Chart) that already
/// manage their own internal scrolling/live-edge behavior. Each call site still
/// owns its own data/polling — this only standardizes layout and chrome.
struct GameDetailScaffold<Tab: Identifiable & RawRepresentable & Hashable, Hero: View, Watch: View, TabContent: View>: View where Tab.RawValue == String {
    let tabs: [Tab]
    @Binding var selection: Tab
    var cacheBanner: String? = nil
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let watch: () -> Watch
    @ViewBuilder let tabContent: (Tab) -> TabContent

    var body: some View {
        VStack(spacing: 0) {
            hero()
            watch()
            GameTabBar(tabs: tabs, selection: $selection)
            if let cacheBanner {
                Text(cacheBanner)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Theme.Spacing.xxs)
            }
            tabContent(selection)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
    }
}

/// Standard overview scroll container: capped content width, consistent vertical
/// rhythm between sections, and bottom padding clear of the mini-player inset.
struct GameOverviewScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                content
            }
            .padding(.vertical, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}
