import SwiftUI

/// A cancellable, restrained pulse that stops offscreen, in the background,
/// or as soon as Reduce Motion is enabled.
struct GentlePulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimmed = false

    private var isActive: Bool { !reduceMotion && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .opacity(isActive && dimmed ? 0.65 : 1)
            .task(id: isActive) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dimmed = false }
                guard isActive else { return }
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.2)) { dimmed.toggle() }
                    do { try await Task.sleep(for: .seconds(1.2)) }
                    catch { return }
                }
            }
    }
}

/// Placeholders mirror the content hierarchy, keeping the page recognizable
/// while data loads. Only the parent loading label is exposed to VoiceOver.
struct ContentSkeleton: View {
    enum Kind { case games, stories }
    var kind: Kind = .games

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if kind == .stories {
                    RoundedRectangle(cornerRadius: Theme.Radius.xl)
                        .fill(Theme.surface)
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
                ForEach(0..<3, id: \.self) { _ in
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            bar(width: 96)
                            HStack(spacing: 20) {
                                RoundedRectangle(cornerRadius: 12)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 10) {
                                    bar(width: nil)
                                    bar(width: 120)
                                }
                                if kind == .games {
                                    RoundedRectangle(cornerRadius: 12)
                                        .frame(width: 48, height: 48)
                                }
                            }
                            if kind == .games { bar(width: 100) }
                        }
                        .foregroundStyle(Theme.surfaceElevated)
                    }
                }
            }
            .padding(Theme.Spacing.screen)
            .modifier(GentlePulse())
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .games ? Text("Loading games") : Text("Loading stories"))
    }

    private func bar(width: CGFloat?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.surfaceElevated)
            .frame(width: width, height: 12)
    }
}
