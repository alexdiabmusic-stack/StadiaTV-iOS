import SwiftUI

struct ArticleReaderView: View {
    let article: ESPNArticle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var paragraphs: [String] {
        article.description
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heroImage
                        header
                        bodyText
                        sourceAction
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(article.league.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private var heroImage: some View {
        if let imageURL = article.imageURL {
            AsyncImage(url: imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Theme.surfaceElevated.overlay {
                        Image(systemName: "newspaper.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.textSecondary.opacity(0.55))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(article.league.shortName.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                if let published = article.published {
                    Text(relativeDate(published))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(article.headline)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if let byline = article.byline, !byline.isEmpty {
                Text(byline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var bodyText: some View {
        if paragraphs.isEmpty {
            Text("This source did not include article text in the feed.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(5)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var sourceAction: some View {
        if let url = article.url {
            Button {
                openURL(url)
            } label: {
                Label("Open Original", systemImage: "arrow.up.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .foregroundStyle(.white)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 4)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
