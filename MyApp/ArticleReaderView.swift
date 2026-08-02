import SwiftUI

// MARK: - Reader Setting Types

enum ReaderAppearance: String, CaseIterable {
    case automatic, light, dark, sepia
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        }
    }
}

enum ReaderTypeface: String, CaseIterable {
    case system, serif
    var label: String { rawValue.capitalized }
    var design: Font.Design { self == .serif ? .serif : .default }
}

enum ReaderSpacing: String, CaseIterable {
    case compact, comfortable, spacious
    var label: String { rawValue.capitalized }
    var lineSpacing: CGFloat {
        switch self { case .compact: return 2; case .comfortable: return 6; case .spacious: return 10 }
    }
    var paragraphSpacing: CGFloat {
        switch self { case .compact: return 10; case .comfortable: return 16; case .spacious: return 24 }
    }
}

// MARK: - ArticleReaderView

struct ArticleReaderView: View {
    let article: ESPNArticle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Content
    @State private var bodyParagraphs: [String] = []
    @State private var isLoading = false
    @State private var fullyLoaded = false
    @State private var isPremium = false

    // Reader settings (persisted across sessions)
    @AppStorage("reader.sizeStep") private var sizeStep: Int = 3
    @AppStorage("reader.appearance") private var appearance: ReaderAppearance = .automatic
    @AppStorage("reader.typeface") private var typeface: ReaderTypeface = .system
    @AppStorage("reader.spacing") private var spacing: ReaderSpacing = .comfortable

    // UI state
    @State private var showingReaderSettings = false
    @State private var scrollProgress: CGFloat = 0

    private let service = ESPNService()

    // MARK: Computed appearance

    private var readerBackground: Color {
        switch appearance {
        case .automatic: return Color(.systemBackground)
        case .light:     return Color(red: 0.98, green: 0.97, blue: 0.96)
        case .dark:      return Color(red: 0.09, green: 0.09, blue: 0.10)
        case .sepia:     return Color(red: 0.97, green: 0.93, blue: 0.84)
        }
    }
    private var readerText: Color {
        switch appearance {
        case .automatic: return Color(.label)
        case .light:     return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .dark:      return Color(red: 0.92, green: 0.92, blue: 0.94)
        case .sepia:     return Color(red: 0.26, green: 0.19, blue: 0.12)
        }
    }
    private var readerSecondary: Color {
        switch appearance {
        case .automatic: return Color(.secondaryLabel)
        case .light:     return Color(red: 0.45, green: 0.45, blue: 0.48)
        case .dark:      return Color(red: 0.60, green: 0.60, blue: 0.62)
        case .sepia:     return Color(red: 0.52, green: 0.40, blue: 0.28)
        }
    }
    private var preferredScheme: ColorScheme? {
        switch appearance {
        case .automatic:        return nil
        case .light, .sepia:    return .light
        case .dark:             return .dark
        }
    }

    // MARK: Computed typography

    private var fontSizeOffset: CGFloat { CGFloat((sizeStep - 3) * 2) }
    private var bodyFont: Font { .system(size: 17 + fontSizeOffset, design: typeface.design) }
    private var headlineFont: Font { .system(size: 22 + fontSizeOffset, weight: .bold, design: typeface.design) }

    private var isPremiumArticle: Bool {
        guard let url = article.url?.absoluteString else { return false }
        return url.contains("/insider/") || article.isPremium
    }

    private var readTimeMinutes: Int {
        let words = bodyParagraphs.joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        return max(1, Int((Double(words) / 238).rounded(.up)))
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                readerBackground.ignoresSafeArea()

                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            heroSection
                            contentSection
                                .padding(.horizontal, 20)
                                .padding(.bottom, 80)
                        }
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .background(
                            GeometryReader { inner in
                                Color.clear.preference(
                                    key: ScrollContentFrameKey.self,
                                    value: inner.frame(in: .named("readerScroll"))
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: "readerScroll")
                    .onPreferenceChange(ScrollContentFrameKey.self) { frame in
                        let scrollable = frame.height - viewport.size.height
                        guard scrollable > 0 else { scrollProgress = 0; return }
                        scrollProgress = min(1, max(0, -frame.minY / scrollable))
                    }
                }

                // Floating Aa button
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showingReaderSettings = true } label: {
                            Text("Aa")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(readerText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule()
                                        .fill(readerBackground)
                                        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                                        .overlay(Capsule().strokeBorder(readerText.opacity(0.12)))
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .overlay(alignment: .top) { progressBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(readerSecondary)
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
            .sheet(isPresented: $showingReaderSettings) {
                ReaderSettingsSheet(
                    sizeStep: $sizeStep,
                    appearance: $appearance,
                    typeface: $typeface,
                    spacing: $spacing,
                    onReset: {
                        sizeStep = 3
                        appearance = .automatic
                        typeface = .system
                        spacing = .comfortable
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .preferredColorScheme(preferredScheme)
        .tint(Theme.accent)
        .task { await loadBody() }
    }

    // MARK: Progress bar

    @ViewBuilder
    private var progressBar: some View {
        if scrollProgress > 0 && scrollProgress < 1 {
            GeometryReader { g in
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: g.size.width * scrollProgress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.linear(duration: 0.05), value: scrollProgress)
            }
            .frame(height: 2)
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var heroSection: some View {
        if let imageURL = article.imageURL {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

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
                            .background(
                                badgeText == "BREAKING" ? Theme.live : Color.black.opacity(0.4),
                                in: Capsule()
                            )
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
    }

    // MARK: Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(article.headline)
                .font(headlineFont)
                .foregroundStyle(readerText)
                .lineSpacing(spacing.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, article.imageURL != nil ? 20 : 28)

            metadataLine

            if let byline = article.byline, !byline.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.caption)
                    Text(byline)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(readerSecondary)
            }

            Divider()

            bodySection

            if let url = article.url {
                footerLink(url: url, prominent: isPremium || bodyParagraphs.isEmpty)
            }
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 4) {
            Text(article.league.shortName)
            if let published = article.published {
                Text("·")
                Text(published, format: .dateTime.month(.wide).day().year())
            }
            if fullyLoaded && !bodyParagraphs.isEmpty {
                Text("·")
                Text("\(readTimeMinutes) min read")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(readerSecondary)
    }

    // MARK: Body

    @ViewBuilder
    private var bodySection: some View {
        if isLoading {
            loadingPlaceholder
        } else if isPremium {
            premiumLock
        } else if !bodyParagraphs.isEmpty {
            VStack(alignment: .leading, spacing: spacing.paragraphSpacing) {
                ForEach(Array(bodyParagraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(bodyFont)
                        .foregroundStyle(readerText.opacity(index == 0 ? 1.0 : 0.92))
                        .fontWeight(index == 0 ? .medium : .regular)
                        .lineSpacing(spacing.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            if !article.description.isEmpty {
                Text(article.description)
                    .font(bodyFont)
                    .foregroundStyle(readerText.opacity(0.9))
                    .lineSpacing(spacing.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No article text available.")
                    .font(bodyFont)
                    .foregroundStyle(readerSecondary)
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
                .foregroundStyle(readerText)
            Text("This article is only available to ESPN Insider subscribers.")
                .font(.subheadline)
                .foregroundStyle(readerSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(readerSecondary.opacity(0.15))
                    .frame(maxWidth: i == 5 ? 180 : .infinity)
                    .frame(height: 14)
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
            .foregroundStyle(prominent ? Theme.accent : readerSecondary)
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

    // MARK: Loading

    private func loadBody() async {
        guard !fullyLoaded else { return }
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

// MARK: - Scroll Content Frame Key

private struct ScrollContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Reader Settings Sheet

struct ReaderSettingsSheet: View {
    @Binding var sizeStep: Int
    @Binding var appearance: ReaderAppearance
    @Binding var typeface: ReaderTypeface
    @Binding var spacing: ReaderSpacing
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reader Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Text size
                    section("Text Size") {
                        HStack(spacing: 12) {
                            Button { sizeStep = max(1, sizeStep - 1) } label: {
                                Text("A")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                            }
                            .buttonStyle(.plain)

                            Slider(
                                value: Binding(
                                    get: { Double(sizeStep) },
                                    set: { sizeStep = Int($0.rounded()) }
                                ),
                                in: 1...6, step: 1
                            )
                            .tint(Theme.accent)

                            Button { sizeStep = min(6, sizeStep + 1) } label: {
                                Text("A")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Appearance
                    section("Appearance") {
                        HStack(spacing: 8) {
                            ForEach(ReaderAppearance.allCases, id: \.self) { option in
                                chip(option.label, selected: appearance == option) {
                                    appearance = option
                                }
                            }
                        }
                    }

                    // Typeface
                    section("Typeface") {
                        HStack(spacing: 8) {
                            ForEach(ReaderTypeface.allCases, id: \.self) { option in
                                chip(
                                    option.label,
                                    font: option == .serif ? .system(size: 15, design: .serif) : nil,
                                    selected: typeface == option
                                ) {
                                    typeface = option
                                }
                            }
                        }
                    }

                    // Spacing
                    section("Spacing") {
                        HStack(spacing: 8) {
                            ForEach(ReaderSpacing.allCases, id: \.self) { option in
                                chip(option.label, selected: spacing == option) {
                                    spacing = option
                                }
                            }
                        }
                    }

                    Button("Reset to Default", action: onReset)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chip(
        _ label: String,
        font: Font? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(font ?? .subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? Theme.accent : Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shimmer

private extension View {
    func shimmering() -> some View {
        self.overlay(ShimmerView()).mask(self)
    }
}

private struct ShimmerView: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { _ in
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

// MARK: - Article badge helper

private extension ESPNArticle {
    var badgeText: String? {
        let text = "\(type ?? "") \(headline) \(categories.joined(separator: " "))".lowercased()
        if text.contains("breaking") || text.contains("injury") || text.contains("trade") { return "BREAKING" }
        if text.contains("analysis") { return "ANALYSIS" }
        if text.contains("rumor") || text.contains("rumour") { return "RUMOUR" }
        return nil
    }
}
