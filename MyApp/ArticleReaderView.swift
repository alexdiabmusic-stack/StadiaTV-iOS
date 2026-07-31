import SwiftUI

// MARK: - Native ESPN article reader

struct ArticleReaderView: View {
    let article: ESPNArticle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var bodyParagraphs: [String] = []
    @State private var isLoading = false
    @State private var fullyLoaded = false
    @State private var isPremium = false

    private let service = ESPNService()

    private var isPremiumArticle: Bool {
        guard let url = article.url?.absoluteString else { return false }
        return url.contains("/insider/") || article.isPremium
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        heroSection
                        contentSection
                            .padding(.horizontal, 20)
                            .padding(.bottom, 40)
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.textSecondary)
                            .font(.title3)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = article.url {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .tint(Theme.accent)
        .task { await loadBody() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Theme.surfaceElevated
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()

                // Gradient scrim for the metadata overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            } else {
                Theme.surfaceElevated
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
            }

            // League + date badges over the image
            HStack(spacing: 6) {
                Text(article.league.shortName.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())

                if let badgeText = article.badgeText {
                    Text(badgeText)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeText == "BREAKING" ? Theme.live : Theme.surfaceElevated.opacity(0.8), in: Capsule())
                }

                Spacer()

                if let published = article.published {
                    Text(relativeDate(published))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(12)
        }
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Headline
            Text(article.headline)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            // Byline
            if let byline = article.byline, !byline.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(byline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Divider().overlay(Theme.hairline)

            // Body
            bodySection

            // Footer link — always shown for premium; subtle link when we have full content
            if let url = article.url {
                footerLink(url: url, prominent: isPremium || bodyParagraphs.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if isLoading {
            loadingPlaceholder
        } else if isPremium {
            premiumLock
        } else if !bodyParagraphs.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(bodyParagraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(.body)
                        .foregroundStyle(index == 0 ? Theme.textPrimary : Theme.textPrimary.opacity(0.9))
                        .fontWeight(index == 0 ? .medium : .regular)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            if !article.description.isEmpty {
                Text(article.description)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No article text available.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var premiumLock: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("ESPN+ Exclusive")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("This article is only available to ESPN Insider subscribers.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.surfaceElevated)
                    .frame(maxWidth: i == 4 ? .infinity * 0.6 : .infinity)
                    .frame(height: 14)
                    .redacted(reason: .placeholder)
                    .shimmering()
            }
        }
        .padding(.vertical, 8)
    }

    private func footerLink(url: URL, prominent: Bool) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: prominent ? "newspaper" : "arrow.up.right.square")
                    .font(.footnote)
                Text(prominent ? "Read full story at ESPN.com" : "Open at ESPN.com")
                    .font(.footnote.weight(.semibold))
                if prominent {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                }
            }
            .foregroundStyle(prominent ? Theme.accent : Theme.textSecondary)
            .padding(.vertical, prominent ? 12 : 8)
            .padding(.horizontal, prominent ? 16 : 0)
            .frame(maxWidth: prominent ? .infinity : nil, alignment: .leading)
            .overlay(
                Group {
                    if prominent {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.4))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .padding(.top, prominent ? 8 : 4)
    }

    // MARK: - Data loading

    private func loadBody() async {
        guard !fullyLoaded else { return }

        // Premium articles are paywalled — don't waste a network request
        if isPremiumArticle {
            isPremium = true
            fullyLoaded = true
            return
        }

        guard let articleURL = article.url else { return }
        isLoading = true
        let fetched = (try? await service.articleBodyFromURL(articleURL)) ?? []
        isLoading = false
        bodyParagraphs = fetched
        fullyLoaded = true
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let diff = max(0, Int(Date().timeIntervalSince(date)))
        if diff < 60 { return "Just now" }
        let minutes = diff / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "Yesterday" }
        return "\(days)d ago"
    }
}

// MARK: - Shimmer modifier for loading placeholders

private extension View {
    func shimmering() -> some View {
        self.overlay(ShimmerView())
            .mask(self)
    }
}

private struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.25), location: 0.5),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: .init(x: phase, y: 0.5),
                endPoint: .init(x: phase + 1, y: 0.5)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}

// MARK: - Article badge helper (reused from DiscoverView)

private extension ESPNArticle {
    var badgeText: String? {
        let text = "\(type ?? "") \(headline) \(categories.joined(separator: " "))".lowercased()
        if text.contains("breaking") || text.contains("injury") || text.contains("trade") { return "BREAKING" }
        if text.contains("analysis") { return "ANALYSIS" }
        if text.contains("rumor") || text.contains("rumour") { return "RUMOUR" }
        return nil
    }
}
