import SwiftUI

struct SearchToolbarModifier: ViewModifier {
    @State private var showingSearch = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
    }
}

extension View {
    func searchToolbar() -> some View {
        modifier(SearchToolbarModifier())
    }
}
