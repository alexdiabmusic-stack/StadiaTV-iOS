import Foundation
import Combine

struct SavedArticle: Codable, Hashable, Identifiable {
    let id: String
    let headline: String
    let description: String
    let published: Date?
    let urlString: String?
    let imageURLString: String?
    let leagueID: String
    let byline: String?
    let type: String?
    let isPremium: Bool
    let categories: [String]
    let savedAt: Date

    init(article: ESPNArticle, savedAt: Date = Date()) {
        self.id = article.id
        self.headline = article.headline
        self.description = article.description
        self.published = article.published
        self.urlString = article.url?.absoluteString
        self.imageURLString = article.imageURL?.absoluteString
        self.leagueID = article.league.id
        self.byline = article.byline
        self.type = article.type
        self.isPremium = article.isPremium
        self.categories = article.categories
        self.savedAt = savedAt
    }

    var article: ESPNArticle {
        ESPNArticle(
            id: id,
            headline: headline,
            description: description,
            published: published,
            url: urlString.flatMap(URL.init(string:)),
            imageURL: imageURLString.flatMap(URL.init(string:)),
            league: League.all.first(where: { $0.id == leagueID }) ?? League.all[0],
            byline: byline,
            type: type,
            isPremium: isPremium,
            categories: categories
        )
    }
}

@MainActor
final class ArticleLibraryStore: ObservableObject {
    @Published private(set) var savedArticles: [SavedArticle] = []
    @Published private(set) var hiddenArticleIDs: Set<String> = []
    @Published private(set) var mutedSources: Set<String> = []

    private let savedArticlesKey = "stadiatv.savedArticles.v1"
    private let hiddenArticlesKey = "stadiatv.hiddenArticles.v1"
    private let mutedSourcesKey = "stadiatv.mutedArticleSources.v1"

    init() {
        load()
    }

    func isSaved(_ article: ESPNArticle) -> Bool {
        savedArticles.contains { $0.id == article.id }
    }

    func save(_ article: ESPNArticle) {
        guard !isSaved(article) else { return }
        savedArticles.insert(SavedArticle(article: article), at: 0)
        persistSavedArticles()
    }

    func unsave(_ article: ESPNArticle) {
        savedArticles.removeAll { $0.id == article.id }
        persistSavedArticles()
    }

    func toggleSaved(_ article: ESPNArticle) {
        isSaved(article) ? unsave(article) : save(article)
    }

    func hide(_ article: ESPNArticle) {
        hiddenArticleIDs.insert(article.id)
        persistHiddenArticles()
    }

    func unhide(_ article: ESPNArticle) {
        hiddenArticleIDs.remove(article.id)
        persistHiddenArticles()
    }

    func isHidden(_ article: ESPNArticle) -> Bool {
        hiddenArticleIDs.contains(article.id)
    }

    func muteSource(for article: ESPNArticle) {
        mutedSources.insert(sourceName(for: article))
        persistMutedSources()
    }

    func unmuteSource(_ source: String) {
        mutedSources.remove(source)
        persistMutedSources()
    }

    func isMuted(_ article: ESPNArticle) -> Bool {
        mutedSources.contains(sourceName(for: article))
    }

    func sourceName(for article: ESPNArticle) -> String {
        guard let byline = article.byline?.trimmingCharacters(in: .whitespacesAndNewlines), !byline.isEmpty else {
            return "ESPN"
        }
        return byline
    }

    /// Clears hidden articles and muted sources (resets content recommendations).
    func clearRecommendations() {
        hiddenArticleIDs.removeAll()
        mutedSources.removeAll()
        UserDefaults.standard.removeObject(forKey: hiddenArticlesKey)
        UserDefaults.standard.removeObject(forKey: mutedSourcesKey)
    }

    /// Clears all local article data (saved, hidden, muted).
    func clearAll() {
        savedArticles.removeAll()
        hiddenArticleIDs.removeAll()
        mutedSources.removeAll()
        UserDefaults.standard.removeObject(forKey: savedArticlesKey)
        UserDefaults.standard.removeObject(forKey: hiddenArticlesKey)
        UserDefaults.standard.removeObject(forKey: mutedSourcesKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: savedArticlesKey),
           let decoded = try? JSONDecoder().decode([SavedArticle].self, from: data) {
            savedArticles = decoded
        }
        if let data = UserDefaults.standard.data(forKey: hiddenArticlesKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            hiddenArticleIDs = decoded
        }
        if let data = UserDefaults.standard.data(forKey: mutedSourcesKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            mutedSources = decoded
        }
    }

    private func persistSavedArticles() {
        if let data = try? JSONEncoder().encode(savedArticles) {
            UserDefaults.standard.set(data, forKey: savedArticlesKey)
        }
    }

    private func persistHiddenArticles() {
        if let data = try? JSONEncoder().encode(hiddenArticleIDs) {
            UserDefaults.standard.set(data, forKey: hiddenArticlesKey)
        }
    }

    private func persistMutedSources() {
        if let data = try? JSONEncoder().encode(mutedSources) {
            UserDefaults.standard.set(data, forKey: mutedSourcesKey)
        }
    }
}
