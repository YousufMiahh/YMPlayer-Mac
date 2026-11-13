import SwiftUI

/// Settings → Home Screen: which rows show (the same rows you can switch off on the TV and phone).
enum HomeRows {
    struct Row: Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    static let all: [Row] = [
        Row(key: "continue", name: "Continue Watching"), Row(key: "queue", name: "Your Queue"),
        Row(key: "fav_live", name: "Favourite Channels"), Row(key: "recent", name: "Recently Watched Channels"),
        Row(key: "top_movies", name: "Top 10 Films in the UK"), Row(key: "top_series", name: "Top 10 Series in the UK"),
        Row(key: "recommended", name: "Because You Watched…"), Row(key: "favourites", name: "My Favourites"),
        Row(key: "new_movies", name: "Recently Added Movies"), Row(key: "new_series", name: "Recently Added Series"),
    ]
    static func shows(_ key: String) -> Bool { UserDefaults.standard.object(forKey: "home." + key) as? Bool ?? true }
}

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("homeRowsVersion") private var rowsVersion = 0 // bumped by Settings so Home redraws

    private func recentlyAdded(_ k: Kind) -> [Item] {
        Array(store.visibleItems(k).sorted { $0.added > $1.added }.prefix(30))
    }

    var body: some View {
        let _ = rowsVersion
        let cont = HomeRows.shows("continue") ? store.continueWatching : []
        let favChannels = HomeRows.shows("fav_live") ? store.favourites(.live) : []
        let favVod = HomeRows.shows("favourites") ? store.data.favourites.filter { $0.kind == .movie || $0.kind == .series } : []
        let recentCh = HomeRows.shows("recent") ? store.data.recentChannels : []
        let newMovies = HomeRows.shows("new_movies") ? recentlyAdded(.movie) : []
        let newSeries = HomeRows.shows("new_series") ? recentlyAdded(.series) : []
        let queue = HomeRows.shows("queue") ? store.data.queue : []
        let topFilms = HomeRows.shows("top_movies") ? store.top10Films : []
        let topSeries = HomeRows.shows("top_series") ? store.top10Series : []
        let recs = HomeRows.shows("recommended") ? store.recRows : []
        let nothingYet = store.items[.movie] == nil && store.items[.series] == nil && store.items[.live] == nil

        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if nothingYet {
                    if let e = store.loadError[.live] ?? store.loadError[.movie] {
                        EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load your library", message: e)
                            .frame(height: 300)
                    } else {
                        LoadingView(text: "Loading your channels, movies and series…").frame(height: 300)
                    }
                }

                if !cont.isEmpty {
                    Shelf(title: "Continue Watching") {
                        ForEach(cont, id: \.item.id) { p in
                            PosterCard(item: p.item, width: 150,
                                       title: p.item.kind == .episode ? (p.item.seriesName ?? p.item.name) : p.item.name,
                                       subtitle: (p.item.episodeLabel.map { $0 + "  ·  " } ?? "") + (p.position > 0 ? Fmt.clock(p.duration - p.position) + " left" : "Next episode"),
                                       progress: p.fraction,
                                       action: { resume(p) },
                                       extraMenu: { AnyView(Button("Remove from Continue Watching") { store.removeFromContinue(p) }) })
                        }
                    }
                }

                if !queue.isEmpty {
                    Shelf(title: "Your Queue", subtitle: "plays next, in order") {
                        ForEach(queue) { it in
                            PosterCard(item: it, width: 150,
                                       title: it.displayTitle,
                                       subtitle: it.episodeLabel.map { $0 + "  ·  " + it.name } ?? it.rating,
                                       progress: store.data.progress[it.id]?.fraction,
                                       action: { store.play(it) },
                                       extraMenu: { AnyView(Group {
                                           Button("Move to Front") { store.moveInQueue(it, to: 0) }
                                           Button("Move to End") { store.moveInQueue(it, to: Int.max) }
                                       }) })
                        }
                    }
                }

                if !favChannels.isEmpty {
                    Shelf(title: "Favourite Channels") {
                        ForEach(favChannels) { ch in ChannelCard(item: ch) { store.play(ch, list: favChannels) } }
                    }
                }

                if !recentCh.isEmpty {
                    Shelf(title: "Recently Watched Channels") {
                        ForEach(recentCh) { ch in ChannelCard(item: ch) { store.play(ch, list: recentCh) } }
                    }
                }

                if !topFilms.isEmpty {
                    Shelf(title: "Top 10 Films in the UK This Week", subtitle: "from Netflix") {
                        ForEach(Array(topFilms.enumerated()), id: \.element.id) { i, it in
                            RankedCard(rank: i + 1, item: it) { store.open(it) }
                        }
                    }
                }

                if !topSeries.isEmpty {
                    Shelf(title: "Top 10 Series in the UK This Week", subtitle: "from Netflix") {
                        ForEach(Array(topSeries.enumerated()), id: \.element.id) { i, it in
                            RankedCard(rank: i + 1, item: it) { store.open(it) }
                        }
                    }
                }

                ForEach(recs) { row in
                    Shelf(title: row.title) {
                        ForEach(row.items) { it in
                            PosterCard(item: it, width: 150, subtitle: it.kind == .series ? (it.genre ?? "Series") : it.rating) { store.open(it) }
                        }
                    }
                }

                if !favVod.isEmpty {
                    Shelf(title: "My Favourites") {
                        ForEach(favVod) { it in PosterCard(item: it, width: 150, subtitle: it.kind == .series ? "Series" : it.rating) { store.open(it) } }
                    }
                }

                if !newMovies.isEmpty {
                    Shelf(title: "Recently Added Movies") {
                        ForEach(newMovies) { it in PosterCard(item: it, width: 150, subtitle: it.rating) { store.open(it) } }
                    }
                }

                if !newSeries.isEmpty {
                    Shelf(title: "Recently Added Series") {
                        ForEach(newSeries) { it in PosterCard(item: it, width: 150, subtitle: it.genre) { store.open(it) } }
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Home")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("YM Player").font(.system(size: 26, weight: .bold))
                if let a = store.current {
                    Text(a.label + (store.accountInfo.map { "  ·  " + $0 } ?? ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func resume(_ p: WatchProgress) {
        if p.item.kind == .episode {
            // Open the series so the rest of the episodes are there for "next episode"
            if let sid = p.item.seriesId, let s = store.items[.series]?.first(where: { $0.streamId == sid }) {
                Task {
                    if let info = try? await store.api?.seriesInfo(s) {
                        store.play(p.item, list: info.allEpisodes)
                    } else {
                        store.play(p.item)
                    }
                }
                return
            }
            store.play(p.item)
        } else {
            store.play(p.item)
        }
    }
}
