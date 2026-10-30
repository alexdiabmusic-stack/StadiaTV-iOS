import SwiftUI

/// Restores only lightweight content IDs, never provider credentials or metadata objects.
nonisolated enum EntertainmentNavigationState {
    static func encode(_ path: [String]) -> String {
        guard let data = try? JSONEncoder().encode(Array(path.prefix(32))) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ value: String) -> [String] {
        guard value.utf8.count < 32_768,
              let path = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { return [] }
        return Array(path.filter { !$0.isEmpty && $0.utf8.count <= 1024 }.prefix(32))
    }
}

struct CompleteLibraryRoot: View {
    let kind: EntertainmentKind
    @SceneStorage("banner.navigation.movies.v1") private var moviePath = "[]"
    @SceneStorage("banner.navigation.series.v1") private var seriesPath = "[]"
    @State private var path: [String] = []
    @State private var restored = false

    var body: some View {
        NavigationStack(path: $path) {
            EntertainmentLibraryView(fixedKind: kind)
                .modifier(CompleteToolbar())
        }
        .onAppear {
            guard !restored else { return }
            restored = true
            path = EntertainmentNavigationState.decode(kind == .movie ? moviePath : seriesPath)
        }
        .onChange(of: path) { _, value in
            if kind == .movie { moviePath = EntertainmentNavigationState.encode(value) }
            else { seriesPath = EntertainmentNavigationState.encode(value) }
        }
    }
}
