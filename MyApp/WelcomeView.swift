import SwiftUI

/// Cinematic full-screen welcome screen.
/// The production artwork (BannerWelcomePhone / BannerWelcomePad) fills the
/// entire canvas. Native SwiftUI controls are layered on top.
struct WelcomeView: View {
    let onGetStarted: () -> Void
    let onRestore: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var contentOpacity: Double = 0
    @State private var contentOffset: CGFloat = 20

    private var isIPad: Bool { sizeClass == .regular }
    private var artworkName: String { isIPad ? "BannerWelcomePad" : "BannerWelcomePhone" }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // LAYER 1 — Full-screen artwork (already contains icon, wordmark, score cards)
                artworkLayer(geo: geo)

                // LAYER 2 — Subtle readability gradient over lower third only
                gradientLayer

                // LAYER 3 — Native headline, subtitle, and CTAs
                nativeContent
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    // MARK: - Artwork

    private func artworkLayer(geo: GeometryProxy) -> some View {
        Image(artworkName)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            .clipped()
            .ignoresSafeArea()
    }

    // MARK: - Gradient

    private var gradientLayer: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.55), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 420)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Native content

    @ViewBuilder
    private var nativeContent: some View {
        let maxWidth: CGFloat = isIPad ? 560 : .infinity

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            textBlock
                .frame(maxWidth: maxWidth)
                .padding(.bottom, 28)
            ctaBlock
                .frame(maxWidth: maxWidth)
        }
        .padding(.horizontal, isIPad ? 0 : 24)
        .padding(.bottom, 40)
        .safeAreaPadding(.bottom)
        .frame(maxWidth: .infinity)
        .opacity(contentOpacity)
        .offset(y: contentOffset)
    }

    private var textBlock: some View {
        Text("Live sports, scores, schedules,\nand your channels.")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
    }

    private var ctaBlock: some View {
        VStack(spacing: 14) {
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get Started")

            HStack(spacing: 4) {
                Text("Already set up?")
                    .foregroundStyle(.white.opacity(0.55))
                Button(action: onRestore) {
                    Text("Restore preferences")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 14))
        }
    }
}
