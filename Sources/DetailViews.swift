import SwiftUI

struct DetailSheet: View {
    let item: Item

    var body: some View {
        if item.kind == .series { SeriesDetail(item: item) } else { MovieDetail(item: item) }
    }
}

private struct Backdrop: View {
    let url: URL?
    let blurred: Bool

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: url, maxPixel: 1400)
                .blur(radius: blurred ? 40 : 0)
                .opacity(blurred ? 0.6 : 0.85)
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85), .black.opacity(0.97)],
                                startPoint: .top, endPoint: .bottom))
        .clipped()
    }
}

private struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .padding(9)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(16)
    }
}

struct MovieDetail: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var info: VodInfo?

    private var meta: String {
        var parts: [String] = []
        if let d = info?.releaseDate { parts.append(String(d.prefix(4))) }
        if let d = info?.duration { parts.append(d) }
        if let r = info?.rating ?? item.rating { parts.append(r) }
        if let g = info?.genre { parts.append(g) }
        return parts.joined(separator: "   ·   ")
    }

    var body: some View {
        let progress = store.data.progress[item.id]
        ZStack(alignment: .topTrailing) {
            Backdrop(url: Item.url(info?.backdrop ?? item.icon), blurred: info?.backdrop == nil)
            HStack(alignment: .top, spacing: 30) {
                PosterCard(item: item, width: 230, showTitle: false) {}
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.name).font(.system(size: 30, weight: .bold)).lineLimit(3)
                    if !meta.isEmpty { Text(meta).foregroundStyle(.secondary) }
                    if let p = info?.plot ?? item.plot {
                        ScrollView {
                            Text(p).font(.system(size: 14)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 170)
                    } else if info == nil {
                        ProgressView().controlSize(.small)
                    }
                    if let c = info?.cast { Text("Cast: " + c).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    if let d = info?.director { Text("Director: " + d).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 6)
                    if let p = progress {
                        ProgressLine(value: p.fraction).frame(maxWidth: 320)
                    }
                    HStack(spacing: 10) {
                        if let p = progress {
                            Button { go(nil) } label: {
                                Label("Resume from \(Fmt.clock(p.position))", systemImage: "play.fill").padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { go(0) } label: { Label("Play from Start", systemImage: "arrow.counterclockwise") }
                        } else {
                            Button { go(0) } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 14) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button { store.toggleFavourite(item) } label: {
                            Label(store.isFavourite(item) ? "Favourite" : "Add to Favourites", systemImage: store.isFavourite(item) ? "heart.fill" : "heart")
                        }
                        if let t = info?.trailer, !t.isEmpty, let u = URL(string: "https://www.youtube.com/watch?v=\(t)") {
                            Button { NSWorkspace.shared.open(u) } label: { Label("Trailer", systemImage: "film") }
                        }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(36)
            CloseButton()
        }
        .frame(width: 940, height: 580)
        .task { info = try? await store.api?.vodInfo(item) }
    }

    private func go(_ from: Double?) {
        dismiss()
        store.play(item, from: from)
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var info: SeriesInfo?
    @State private var failed = false
    @State private var season = 0

    private var lastWatched: WatchProgress? {
        store.data.progress.values.filter { $0.item.seriesId == item.streamId }.max { $0.updated < $1.updated }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Backdrop(url: Item.url(info?.backdrop ?? info?.cover ?? item.icon), blurred: info?.backdrop == nil)
                HStack(alignment: .top, spacing: 26) {
                    PosterCard(item: item, width: 150, showTitle: false) {}
                    VStack(alignment: .leading, spacing: 10) {
                        Text(info?.name ?? item.name).font(.system(size: 28, weight: .bold)).lineLimit(2)
                        let meta = [info?.releaseDate.map { String($0.prefix(4)) }, info?.rating ?? item.rating, info?.genre ?? item.genre,
                                    info.map { "\($0.seasons.count) season" + ($0.seasons.count == 1 ? "" : "s") }].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: "   ·   ")).foregroundStyle(.secondary) }
                        if let p = info?.plot ?? item.plot {
                            Text(p).font(.system(size: 13)).lineLimit(4).lineSpacing(2)
                        }
                        HStack(spacing: 10) {
                            if let info = info, let first = info.allEpisodes.first {
                                if let lw = lastWatched {
                                    Button { play(lw.item) } label: {
                                        Label("Continue \(lw.item.episodeLabel ?? "")", systemImage: "play.fill").padding(.horizontal, 6)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Button { play(first) } label: {
                                        Label("Play \(first.episodeLabel ?? "")", systemImage: "play.fill").padding(.horizontal, 6)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            Button { store.toggleFavourite(item) } label: {
                                Label(store.isFavourite(item) ? "Favourite" : "Add to Favourites", systemImage: store.isFavourite(item) ? "heart.fill" : "heart")
                            }
                        }
                        .controlSize(.large)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(30)
                CloseButton()
            }
            .frame(height: 300)

            if let info = info {
                let seasons = info.seasons.keys.sorted()
                if seasons.isEmpty {
                    EmptyState(icon: "play.rectangle", title: "No episodes yet")
                } else {
                    HStack {
                        Picker("Season", selection: $season) {
                            ForEach(seasons, id: \.self) { s in Text(s == 0 ? "Specials" : "Season \(s)").tag(s) }
                        }
                        .frame(width: 200)
                        Spacer()
                        Text("\(info.seasons[season]?.count ?? 0) episodes").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(info.seasons[season] ?? []) { ep in
                                EpisodeRow(episode: ep, progress: store.data.progress[ep.id]) { play(ep) }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    }
                }
            } else if failed {
                EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load the episodes")
            } else {
                LoadingView(text: "Loading episodes…")
            }
        }
        .frame(width: 940, height: 680)
        .background(Color.black)
        .task {
            do {
                let i = try await store.api?.seriesInfo(item)
                info = i
                let keys = i?.seasons.keys.sorted() ?? []
                if let lw = lastWatched?.item.season, keys.contains(lw) { season = lw } else { season = keys.first(where: { $0 > 0 }) ?? keys.first ?? 0 }
            } catch {
                failed = true
            }
        }
    }

    private func play(_ ep: Item) {
        let list = info?.allEpisodes ?? [ep]
        dismiss()
        store.play(ep, list: list)
    }
}

struct EpisodeRow: View {
    let episode: Item
    let progress: WatchProgress?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Theme.card
                Image(systemName: "play.rectangle").font(.title2).foregroundStyle(.tertiary)
                RemoteImage(url: episode.iconURL, maxPixel: 400)
            }
            .frame(width: 176, height: 99)
            .overlay(alignment: .bottom) {
                if let p = progress { ProgressLine(value: p.fraction).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text((episode.episode.map { "\($0).  " } ?? "") + episode.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if let d = episode.duration { Text(d).font(.caption).foregroundStyle(.secondary) }
                if let p = episode.plot { Text(p).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(hover ? Theme.accent : Color.secondary)
                .padding(.top, 30)
        }
        .padding(10)
        .background(hover ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}
