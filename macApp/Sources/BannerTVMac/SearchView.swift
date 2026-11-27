import BannerCore
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var shelves: [HomeShelf] = []
    @Published private(set) var isSearching = false
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "mac_recent_searches") ?? []
    private var debounce: Task<Void, Never>?

    func queryChanged() {
        debounce?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { MacBridge.shared.search(query: "", onRows: { _ in }, onDone: {}); shelves = []; isSearching = false; return }
        debounce = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            run(text)
        }
    }

    func run(_ text: String) {
        isSearching = true
        MacBridge.shared.search(query: text, onRows: { [weak self] rows in
            let mapped = rows.map { HomeShelf(id: $0.key, rowId: $0.rowId, title: $0.title, source: $0.addonName, items: $0.items.map(TitleCard.init)) }
            Task { @MainActor in self?.shelves = mapped }
        }, onDone: { [weak self] in Task { @MainActor in self?.isSearching = false } })
        remember(text)
    }

    private func remember(_ text: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recents = Array(list.prefix(10))
        UserDefaults.standard.set(recents, forKey: "mac_recent_searches")
    }

    func clearRecents() { recents = []; UserDefaults.standard.removeObject(forKey: "mac_recent_searches") }
}

struct SearchView: View {
    @StateObject private var model = SearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    TextField("Search movies and series", text: $model.query)
                        .textFieldStyle(.plain).font(.jb(20)).focused($focused)
                        .onChange(of: model.query) { _, _ in model.queryChanged() }
                        .onSubmit { model.run(model.query) }
                    if model.isSearching { ProgressView().controlSize(.small) }
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 22).frame(height: 58)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(focused ? 0.35 : 0.10), lineWidth: 1))
                .frame(maxWidth: 760)
                .padding(.horizontal, Theme.gutter).padding(.top, 96)

                if model.query.isEmpty {
                    if !model.recents.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent").font(.jb(22, .semibold)); Spacer()
                                Button("Clear") { model.clearRecents() }.buttonStyle(.plain).font(.jb(14, .semibold)).foregroundStyle(Theme.textMuted)
                            }
                            FlowRow {
                                ForEach(model.recents, id: \.self) { text in
                                    Button { model.query = text; model.run(text) } label: {
                                        Label(text, systemImage: "clock.arrow.circlepath").font(.jb(14, .semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 8).background(Color.white.opacity(0.10), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: 760).padding(.horizontal, Theme.gutter)
                    }
                } else if model.shelves.isEmpty && !model.isSearching {
                    Text("No results for \u{201C}\(model.query)\u{201D}").font(.jb(16)).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.gutter)
                }
                ForEach(model.shelves) { shelf in TitleShelf(title: shelf.title, items: shelf.items) }
            }
            .padding(.bottom, 60)
        }
        .onAppear {
            focused = true
            if let q = DebugHarness.value(after: "--search") { model.query = q; model.run(q) }
        }
    }
}
