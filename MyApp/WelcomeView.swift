import SwiftUI

/// Cinematic full-screen welcome screen.
/// The production artwork (BannerWelcomePhone / BannerWelcomePad) fills the
/// entire canvas. Native SwiftUI controls are layered on top.
struct WelcomeView: View {
    let onGetStarted: () -> Void
    let onRestore: () -> Void

    @State private var contentOpacity: Double = 0
    @State private var contentOffset: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let isWide = size.width > size.height
            // Picked from the window's shape, not the idiom: an unfolded iPhone Duo is a wide window.
            let artworkName = isWide ? "BannerWelcomePad" : "BannerWelcomePhone"
            // Where the artwork's own "BANNER TV" wordmark ends, as a fraction of its height, and
            // its pixel aspect ratio (both measured from the bundled images).
            let wordmarkBottom: CGFloat = isWide ? 0.80 : 0.755
            let aspect: CGFloat = isWide ? 1448.0 / 1086.0 : 941.0 / 1672.0
            let controlsHeight: CGFloat = isWide ? 150 : 195
            // Scale to cover the whole window, then slide the artwork up just enough that its
            // wordmark ends above the controls. The bottom edge fades into the background.
            let artHeight = max(size.height, size.width / aspect)
            let artWidth = artHeight * aspect
            let wantedOffset = size.height - controlsHeight - 12 - wordmarkBottom * artHeight
            let offset = min(0, wantedOffset)

            ZStack(alignment: .bottom) {
                Theme.Palette.nearBlack
                Image(artworkName)
                    .resizable()
                    .frame(width: artWidth, height: artHeight)
                    .mask(edgeFade)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .offset(y: offset)
                    .clipped()
                nativeContent(width: size.width, isWide: isWide)
                    .frame(height: controlsHeight)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(false)
        #endif
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Native content

    private func nativeContent(width: CGFloat, isWide: Bool) -> some View {
        VStack(spacing: 0) {
            textBlock(isWide: isWide)
                .padding(.bottom, isWide ? 12 : 20)
            ctaBlock
        }
        .frame(maxWidth: min(width - 48, 560))
        .frame(maxWidth: .infinity)
        .opacity(contentOpacity)
        .offset(y: contentOffset)
    }

    private func textBlock(isWide: Bool) -> some View {
        Text(isWide ? "Live sports, scores, schedules, and your channels." : "Live sports, scores, schedules,\nand your channels.")
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
                    .background(Theme.actionFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
