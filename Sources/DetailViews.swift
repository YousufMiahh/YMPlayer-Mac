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
            Theme.bg
            RemoteImage(url: url, maxPixel: 1400)
                .blur(radius: blurred ? 40 : 0)
                .opacity(blurred ? 0.6 : 0.85)
        }
        .overlay(LinearGradient(colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.85), Theme.bg.opacity(0.97)],
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
                    HStack(spacing: 10) {
                        Button { store.toggleQueue(item) } label: {
                            Label(store.inQueue(item) ? "In Queue" : "Add to Queue", systemImage: store.inQueue(item) ? "checkmark" : "plus")
                        }
                        Button { store.setWatched(item, !store.isWatched(item)) } label: {
                            Label(store.isWatched(item) ? "Watched" : "Mark as Watched", systemImage: store.isWatched(item) ? "checkmark.circle.fill" : "circle")
                        }
                        DownloadButton(dl: store.downloads, item: item)
                    }
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
        var it = item
        if it.tmdb == nil { it.tmdb = info?.tmdb }
        store.play(it, from: from)
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dl: Downloader
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
                    let eps = info.seasons[season] ?? []
                    HStack(spacing: 14) {
                        Picker("Season", selection: $season) {
                            ForEach(seasons, id: \.self) { s in Text(seasonLabel(s, info.seasons[s] ?? [])).tag(s) }
                        }
                        .frame(width: 230)
                        Menu {
                            Button(store.watchedCount(eps) == eps.count ? "Mark Season as Unwatched" : "Mark Season as Watched") {
                                store.setWatched(eps, store.watchedCount(eps) != eps.count)
                            }
                            Divider()
                            Button("Download " + (season == 0 ? "Specials" : "Season \(season)")) { store.downloads.add(eps) }
                            if seasons.count > 1 {
                                Button("Download All Seasons") { store.downloads.add(info.allEpisodes) }
                            }
                            if eps.contains(where: { e in let s = store.downloads.entry(e)?.state; return s == .waiting || s == .running }) {
                                Button("Cancel This Season's Downloads") { store.downloads.cancelAll(eps) }
                            }
                        } label: { Label("Season", systemImage: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                        DownloadLine(dl: store.downloads, season: season, episodes: eps)
                        Text("\(eps.count) episodes").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(eps) { ep in
                                EpisodeRow(episode: ep, progress: store.data.progress[ep.id], watched: store.isWatched(ep),
                                           downloaded: store.downloads.entry(ep)?.state == .done) { play(ep) }
                                    .contextMenu {
                                        Button("Play") { play(ep) }
                                        Button(store.isWatched(ep) ? "Mark as Unwatched" : "Mark as Watched") { store.setWatched(ep, !store.isWatched(ep)) }
                                        Button(store.watchedCount(eps) == eps.count ? "Mark Season as Unwatched" : "Mark Season as Watched") {
                                            store.setWatched(eps, store.watchedCount(eps) != eps.count)
                                        }
                                        Button(store.inQueue(ep) ? "Remove from Queue" : "Add to Queue") { store.toggleQueue(ep) }
                                        Divider()
                                        if let e = store.downloads.entry(ep) {
                                            if e.state == .done {
                                                Button("Show in Finder") { store.downloads.reveal(e) }
                                                Button("Delete Download") { store.downloads.delete(e) }
                                            } else {
                                                Button("Cancel Download") { store.downloads.cancel(e) }
                                            }
                                        } else {
                                            Button("Download Episode") { store.downloads.add([ep]) }
                                        }
                                        if store.data.progress[ep.id] != nil {
                                            Button("Remove from Continue Watching") { store.data.progress[ep.id] = nil }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    }
                    .id(season)
                    .transition(.opacity.combined(with: .offset(y: 16))) // as on the apps: a new season's episodes rise in
                    .animation(Theme.ease, value: season)
                }
            } else if failed {
                EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load the episodes")
            } else {
                LoadingView(text: "Loading episodes…")
            }
        }
        .frame(width: 940, height: 680)
        .background(Theme.bg)
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

    private func seasonLabel(_ s: Int, _ eps: [Item]) -> String {
        let name = s == 0 ? "Specials" : "Season \(s)"
        let w = store.watchedCount(eps)
        if w == 0 || eps.isEmpty { return name }
        return w == eps.count ? name + "  ✓" : name + "  \(w)/\(eps.count)"
    }

    private func play(_ ep: Item) {
        let list = info?.allEpisodes ?? [ep]
        dismiss()
        store.play(ep, list: list)
    }
}

/// "Season 2: 3 of 10 downloaded · about 40 min left"
struct DownloadLine: View {
    @ObservedObject var dl: Downloader
    let season: Int
    let episodes: [Item]

    var body: some View {
        let states = episodes.compactMap { dl.entry($0)?.state }
        let busy = states.contains(.waiting) || states.contains(.running)
        if busy {
            let done = states.filter { $0 == .done }.count
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(lineText(done))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension DownloadLine {
    fileprivate func lineText(_ done: Int) -> String {
        let name: String = season == 0 ? "Specials" : "Season \(season)"
        var s: String = name + ": \(done) of \(episodes.count) downloaded"
        if let t = dl.timeLeft(episodes) { s += "  ·  " + Downloader.timeText(t) }
        return s
    }
}

struct EpisodeRow: View {
    let episode: Item
    let progress: WatchProgress?
    var watched = false
    var downloaded = false
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
            .overlay(alignment: .topTrailing) {
                if watched { WatchedBadge().padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text((episode.episode.map { "\($0).  " } ?? "") + episode.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                let sub = [episode.duration, watched ? "✓ Watched" : nil, downloaded ? "Downloaded" : nil].compactMap { $0 }
                if !sub.isEmpty { Text(sub.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary) }
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
