import SwiftUI

/// Movies or Series: categories on the left, a poster grid on the right.
struct VODView: View {
    @EnvironmentObject var store: AppStore
    let kind: Kind
    @State private var category: String? = Special.all
    @State private var query = ""
    @State private var results: [Item]?
    @State private var searchTask: Task<Void, Never>?

    private var shown: [Item] { results ?? store.itemsFor(kind, category) }
    private var title: String { results != nil ? "Results for “\(query)”" : store.categoryName(kind, category) }

    var body: some View {
        HStack(spacing: 0) {
            CategoryColumn(kind: kind, selection: $category)
                .frame(width: 250)
            Divider()
            content
        }
        .navigationTitle(kind.title)
        .searchable(text: $query, placement: .toolbar, prompt: "Search \(kind.plural)")
        .onChange(of: query) { _ in runSearch() }
        .onChange(of: category) { _ in if !query.isEmpty { query = "" } }
        .task { await store.ensureLoaded(kind) }
    }

    @ViewBuilder
    private var content: some View {
        if store.items[kind] == nil {
            if let e = store.loadError[kind] {
                EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load \(kind.plural)", message: e)
            } else {
                LoadingView(text: "Loading \(kind.plural)…")
            }
        } else {
            let list = shown
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    Text("\(list.count)").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 4)
                if list.isEmpty {
                    EmptyState(icon: category == Special.favourites ? "heart" : "film",
                               title: results != nil ? "Nothing found" : category == Special.favourites ? "No favourites yet" : "Nothing here",
                               message: category == Special.favourites ? "Right-click anything and choose Add to Favourites." : nil)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)], alignment: .leading, spacing: 22) {
                            ForEach(list) { it in
                                PosterCard(item: it, width: nil, subtitle: subtitle(it), progress: store.data.progress[it.id]?.fraction) {
                                    store.open(it)
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
    }

    private func subtitle(_ it: Item) -> String? {
        let parts = [it.rating, kind == .series ? it.genre : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard Match.Query(q).usable else {
            results = nil
            return
        }
        let k = kind
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let idx = await store.searchIndex(k)
            let hits = await Task.detached { Match.rank(idx, q, max: 300) }.value
            if !Task.isCancelled { results = hits }
        }
    }
}
