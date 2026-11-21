import SwiftUI

struct DetailSheet: View {
    let item: Item

    var body: some View {
        if item.kind == .series { SeriesDetail(item: item) } else { MovieDetail(item: item) }
    }
}

private struct Backdrop: View {
    @EnvironmentObject var store: AppStore
    let url: URL?
    let blurred: Bool
    /// Whose muted preview may play behind the page (Netflix-style), if any.
    var previewOwner: String? = nil

    var body: some View {
        ZStack {
            Theme.bg
            RemoteImage(url: url, maxPixel: 1400)
                .blur(radius: blurred ? 40 : 0)
                .opacity(blurred ? 0.6 : 0.85)
            if let o = previewOwner, store.pagePreviewOwner == o {
                PagePreviewLayer(preview: store.preview)
            }
        }
        .overlay(LinearGradient(colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.85), Theme.bg.opacity(0.97)],
                                startPoint: .top, endPoint: .bottom))
        .clipped()
    }
}

/// Audio & Subtitles before you start: the languages the player picks when it can.
struct AudioSubtitlesMenu: View {
    @AppStorage("subLang") private var subLang = ""
    @AppStorage("audioLang") private var audioLang = ""

    var body: some View {
        Menu {
            Picker("Subtitles", selection: $subLang) {
                Text("Off").tag("off")
                Text("English").tag("en")
                Text("As the stream sets them").tag("")
            }
            .pickerStyle(.inline)
            Picker("Audio", selection: $audioLang) {
                Text("English").tag("en")
                Text("Original (as the stream sets it)").tag("")
            }
            .pickerStyle(.inline)
        } label: {
            Label("Audio & Subtitles", systemImage: "captions.bubble")
        }
        .fixedSize()
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
    @State private var trailer: String?

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
            Backdrop(url: Item.url(info?.backdrop ?? item.icon), blurred: info?.backdrop == nil, previewOwner: item.id)
            HStack(alignment: .top, spacing: 30) {
                PosterCard(item: item, width: 230, showTitle: false) {}
                VStack(alignment: .leading, spacing: 14) {
                    TitleLogo(kind: .movie, name: item.name, tmdb: item.tmdb ?? info?.tmdb, height: 110, font: .system(size: 30, weight: .bold))
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
                        HStack(spacing: 10) {
                            ProgressLine(value: p.fraction).frame(maxWidth: 220)
                            Text(Fmt.clock(max(0, p.duration - p.position)) + " left").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    // Netflix: Resume / Play From Beginning, or Play / Audio & Subtitles
                    HStack(spacing: 10) {
                        if progress != nil {
                            Button { go(nil) } label: {
                                Label("Resume", systemImage: "play.fill").padding(.horizontal, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { go(0) } label: { Label("Play From Beginning", systemImage: "arrow.counterclockwise") }
                        } else {
                            Button { go(0) } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 14) }
                                .buttonStyle(.borderedProminent)
                            AudioSubtitlesMenu()
                        }
                        Button { store.toggleFavourite(item) } label: {
                            Label(store.isFavourite(item) ? "Favourite" : "Add to Favourites", systemImage: store.isFavourite(item) ? "heart.fill" : "heart")
                        }
                        if let id = TrailerSheet.youtubeId(info?.trailer) {
                            Button { trailer = id } label: { Label("Trailer", systemImage: "film") }
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
        .task {
            info = try? await store.api?.vodInfo(item)
            // Part way through: it plays (muted) behind the page after a moment, from where you were
            if let p = store.data.progress[item.id], p.position > 30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { store.startPagePreview(item, at: p.position, owner: item.id) }
            }
        }
        .onDisappear { store.stopPagePreview(owner: item.id) }
        .sheet(item: Binding(get: { trailer.map { TrailerID(id: $0) } }, set: { trailer = $0?.id })) { t in
            TrailerSheet(videoId: t.id, title: item.name)
        }
    }

    private func go(_ from: Double?) {
        store.stopPagePreview(owner: item.id)
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
    @State private var trailer: String?

    @State private var scrollTarget: String?
    /// How far the episode list is scrolled: the header shrinks into a bar with the small logo.
    @State private var scrolled: CGFloat = 0
    private var collapse: CGFloat { min(1, max(0, scrolled / 150)) }

    private var lastWatched: WatchProgress? {
        store.data.progress.values.filter { $0.item.seriesId == item.streamId }.max { $0.updated < $1.updated }
    }

    /// What Resume / Play starts (Netflix): the episode you were on (the next once it's finished), or the first.
    private var target: (ep: Item, resume: Bool)? {
        guard let info = info else { return nil }
        let all = info.allEpisodes
        guard let first = all.first(where: { ($0.season ?? 1) > 0 }) ?? all.first else { return nil }
        if let lw = lastWatched, let i = all.firstIndex(where: { $0.id == lw.item.id }) {
            var t = all[i]
            if store.isWatched(t), i + 1 < all.count { t = all[i + 1] }
            return (t, true)
        }
        return (first, false)
    }

    /// "S1: Ep. 3" to resume, "S1: E1" to start.
    private func heroName(_ ep: Item, resume: Bool) -> String {
        guard let s = ep.season, let e = ep.episode else { return ep.episodeLabel ?? "" }
        return resume ? "S\(s): Ep. \(e)" : "S\(s): E\(e)"
    }

    /// Episodes & More: that episode's season, scrolled to it.
    private func showEpisodes(_ ep: Item) {
        if let s = ep.season, info?.seasons[s] != nil { season = s }
        scrollTarget = nil
        DispatchQueue.main.async { scrollTarget = ep.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Backdrop(url: Item.url(info?.backdrop ?? info?.cover ?? item.icon), blurred: info?.backdrop == nil, previewOwner: item.id)
                HStack(alignment: .top, spacing: 26) {
                    PosterCard(item: item, width: 150, showTitle: false) {}
                    VStack(alignment: .leading, spacing: 10) {
                        TitleLogo(kind: .tv, name: info?.name ?? item.name, tmdb: info?.tmdb ?? item.tmdb, height: 92)
                        let meta = [info?.releaseDate.map { String($0.prefix(4)) }, info?.rating ?? item.rating, info?.genre ?? item.genre,
                                    info.map { "\($0.seasons.count) season" + ($0.seasons.count == 1 ? "" : "s") }].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: "   ·   ")).foregroundStyle(.secondary) }
                        if let p = info?.plot ?? item.plot {
                            Text(p).font(.system(size: 13)).lineLimit(4).lineSpacing(2)
                        }
                        if let t = target, t.resume, let p = store.data.progress[t.ep.id], p.position > 0, p.duration > 0 {
                            HStack(spacing: 10) {
                                ProgressLine(value: p.fraction).frame(maxWidth: 200)
                                Text(Fmt.clock(max(0, p.duration - p.position)) + " left").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        // Netflix: Resume S1: Ep. 3 / Play From Beginning / Episodes & More, or
                        // Play S1: E1 / Episodes & More / Audio & Subtitles for one you haven't started
                        HStack(spacing: 10) {
                            if let t = target {
                                Button { play(t.ep) } label: {
                                    Label((t.resume ? "Resume " : "Play ") + heroName(t.ep, resume: t.resume), systemImage: "play.fill").padding(.horizontal, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                if t.resume {
                                    Button { play(t.ep, from: 0) } label: { Label("Play From Beginning", systemImage: "arrow.counterclockwise") }
                                }
                                Button { showEpisodes(t.ep) } label: { Label("Episodes & More", systemImage: "list.bullet") }
                                if !t.resume { AudioSubtitlesMenu() }
                            }
                            Button { store.toggleFavourite(item) } label: {
                                Label(store.isFavourite(item) ? "Favourite" : "Add to Favourites", systemImage: store.isFavourite(item) ? "heart.fill" : "heart")
                            }
                            if let id = TrailerSheet.youtubeId(info?.trailer) {
                                Button { trailer = id } label: { Label("Trailer", systemImage: "film") }
                            }
                        }
                        .controlSize(.large)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(30)
                .opacity(1 - min(1, collapse * 1.6))
                .allowsHitTesting(collapse < 0.5)
                if collapse > 0 { // the bar it shrinks into: the small logo, centred
                    TitleLogo(kind: .tv, name: info?.name ?? item.name, tmdb: info?.tmdb ?? item.tmdb, height: 40, maxWidth: 260,
                              font: .system(size: 18, weight: .bold), alignment: .center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 70)
                        .opacity(collapse)
                        .scaleEffect(0.85 + 0.15 * collapse)
                }
                CloseButton()
            }
            .frame(height: 300 - 220 * collapse)
            .clipped()

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
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            GeometryReader { g in
                                Color.clear.preference(key: EpisodeScrollKey.self, value: -g.frame(in: .named("episodes")).minY)
                            }
                            .frame(height: 0)
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
                    .coordinateSpace(name: "episodes")
                    .onPreferenceChange(EpisodeScrollKey.self) { scrolled = $0 }
                    .onAppear { if let id = scrollTarget { proxy.scrollTo(id, anchor: .top) } }
                    .onChange(of: scrollTarget) { id in
                        if let id = id { withAnimation(Theme.ease) { proxy.scrollTo(id, anchor: .top) } }
                    }
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
        .sheet(item: Binding(get: { trailer.map { TrailerID(id: $0) } }, set: { trailer = $0?.id })) { t in
            TrailerSheet(videoId: t.id, title: item.name)
        }
        .task {
            do {
                let i = try await store.api?.seriesInfo(item)
                info = i
                let keys = i?.seasons.keys.sorted() ?? []
                if let lw = lastWatched?.item.season, keys.contains(lw) { season = lw } else { season = keys.first(where: { $0 > 0 }) ?? keys.first ?? 0 }
            } catch {
                failed = true
                return
            }
            // Part way through: it plays (muted) behind the page after a moment, from where you were
            if let t = target, t.resume, let p = store.data.progress[t.ep.id], p.position > 30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { store.startPagePreview(t.ep, at: p.position, owner: item.id) }
            }
        }
        .onDisappear { store.stopPagePreview(owner: item.id) }
    }

    private func seasonLabel(_ s: Int, _ eps: [Item]) -> String {
        let name = s == 0 ? "Specials" : "Season \(s)"
        let w = store.watchedCount(eps)
        if w == 0 || eps.isEmpty { return name }
        return w == eps.count ? name + "  ✓" : name + "  \(w)/\(eps.count)"
    }

    private func play(_ ep: Item, from: Double? = nil) {
        let list = info?.allEpisodes ?? [ep]
        store.stopPagePreview(owner: item.id)
        dismiss()
        store.play(ep, list: list, from: from)
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

struct TrailerID: Identifiable { let id: String }


/// How far the episode list has scrolled (SeriesDetail's header follows it).
private struct EpisodeScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
