import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore

    private func recentlyAdded(_ k: Kind) -> [Item] {
        Array(store.visibleItems(k).sorted { $0.added > $1.added }.prefix(30))
    }

    var body: some View {
        let cont = store.continueWatching
        let favChannels = store.favourites(.live)
        let favVod = store.data.favourites.filter { $0.kind == .movie || $0.kind == .series }
        let recentCh = store.data.recentChannels
        let newMovies = recentlyAdded(.movie)
        let newSeries = recentlyAdded(.series)
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
                                       subtitle: (p.item.episodeLabel.map { $0 + "  ·  " } ?? "") + Fmt.clock(p.duration - p.position) + " left",
                                       progress: p.fraction,
                                       action: { resume(p) },
                                       extraMenu: { AnyView(Button("Remove from Continue Watching") { store.removeFromContinue(p) }) })
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

                if !store.top10Films.isEmpty {
                    Shelf(title: "Top 10 Films in the UK This Week", subtitle: "from Netflix") {
                        ForEach(Array(store.top10Films.enumerated()), id: \.element.id) { i, it in
                            RankedCard(rank: i + 1, item: it) { store.open(it) }
                        }
                    }
                }

                if !store.top10Series.isEmpty {
                    Shelf(title: "Top 10 Series in the UK This Week", subtitle: "from Netflix") {
                        ForEach(Array(store.top10Series.enumerated()), id: \.element.id) { i, it in
                            RankedCard(rank: i + 1, item: it) { store.open(it) }
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
