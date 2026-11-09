import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var filter: Kind? = nil
    @State private var results: [Kind: [Item]] = [:]
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private let kinds: [Kind] = [.live, .movie, .series]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                TextField("Search channels, movies and series", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Picker("Show", selection: $filter) {
                Text("All").tag(Kind?.none)
                Text("Live TV").tag(Kind?.some(.live))
                Text("Movies").tag(Kind?.some(.movie))
                Text("Series").tag(Kind?.some(.series))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 400)

            resultsView
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .navigationTitle("Search")
        .onChange(of: query) { _ in run() }
        .onChange(of: filter) { _ in run() }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var resultsView: some View {
        let nonEmpty = kinds.filter { !(results[$0] ?? []).isEmpty }
        if !Match.Query(query).usable {
            EmptyState(icon: "magnifyingglass", title: "Search everything",
                       message: "Type at least two letters. Hidden countries and languages are left out; categories you hid yourself are still searched.")
        } else if nonEmpty.isEmpty {
            if searching { LoadingView(text: "Searching…") } else { EmptyState(icon: "questionmark.circle", title: "No results for “\(query)”") }
        } else if let k = filter ?? (nonEmpty.count == 1 ? nonEmpty[0] : nil) {
            // One type (chosen, or the only one with results): the full grid
            grid(k, results[k] ?? [])
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(nonEmpty, id: \.self) { k in
                        let hits = results[k] ?? []
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(k == .live ? "Channels" : k.title).font(.system(size: 20, weight: .bold))
                                Text("\(hits.count)").foregroundStyle(.secondary)
                                Spacer()
                                if hits.count > 12 { Button("Show All") { filter = k } }
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(hits.prefix(30)) { it in card(it, k, hits, width: k == .live ? 190 : 140) }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func grid(_ k: Kind, _ hits: [Item]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: k == .live ? 180 : 140, maximum: k == .live ? 240 : 190), spacing: 18)],
                      alignment: .leading, spacing: 22) {
                ForEach(hits) { it in card(it, k, hits, width: nil) }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func card(_ it: Item, _ k: Kind, _ list: [Item], width: CGFloat?) -> some View {
        if k == .live {
            ChannelCard(item: it, width: width) { store.play(it, list: list) }
        } else {
            PosterCard(item: it, width: width, subtitle: it.rating) { store.open(it) }
        }
    }

    private func run() {
        task?.cancel()
        let q = query
        guard Match.Query(q).usable else {
            results = [:]
            searching = false
            return
        }
        let wanted = filter.map { [$0] } ?? kinds
        let limit = filter == nil ? 200 : 400
        searching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            var out: [Kind: [Item]] = [:]
            for k in wanted {
                await store.ensureLoaded(k)
                await store.waitLoaded(k)
                let idx = await store.searchIndex(k)
                let hits = await Task.detached { Match.rank(idx, q, max: limit) }.value
                if Task.isCancelled { return }
                out[k] = hits
            }
            results = out // all at once, so "All" doesn't flick to a grid while the rest are still searching
            searching = false
        }
    }
}
