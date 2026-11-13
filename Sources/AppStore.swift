import SwiftUI
import Combine

enum Page: String, Hashable, CaseIterable, Identifiable {
    case home, live, movies, series, search, downloads, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .live: return "tv"
        case .movies: return "film"
        case .series: return "play.rectangle.on.rectangle"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

/// Special entries at the top of each category list.
enum Special {
    static let favourites = "__fav"
    static let recent = "__recent"
    static let all = "__all"
}

struct TagCount: Hashable {
    let tag: String
    let count: Int
}

@MainActor
final class AppStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var currentId: UUID?
    @Published var page: Page = .home
    @Published var categories: [Kind: [Category]] = [:]
    @Published var items: [Kind: [Item]] = [:]
    @Published var loading: Set<Kind> = []
    @Published var loadError: [Kind: String] = [:]
    @Published var data = UserData() { didSet { scheduleSave() } }
    @Published var filterVersion = 0
    @Published var top10Films: [Item] = []
    @Published var top10Series: [Item] = []
    @Published var detail: Item?
    @Published var session: PlaySession?
    @Published var mini = false
    @Published var accountInfo: String?
    @Published var toast: String?
    @Published var recRows: [RecRow] = []
    @Published var segments: Segments?

    let player = PlayerModel()
    let preview = PlayerModel()
    let guide = EpgStore()
    let downloads = Downloader()

    private var saveTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var endRetries = 0
    private var toastTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var visibleCache: [Kind: (Int, [Item])] = [:]
    private var groupCache: [Kind: (Int, [String: [Item]])] = [:]
    private var indexCache: [Kind: (Int, [Indexed])] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "accounts"), let a = try? JSONDecoder().decode([Account].self, from: d) { accounts = a }
        if let s = UserDefaults.standard.string(forKey: "currentAccount") { currentId = UUID(uuidString: s) }
        if current == nil { currentId = accounts.first?.id }
        guide.apiProvider = { [weak self] in self?.api }
        downloads.apiProvider = { [weak self] in self?.api }
        downloads.setAccount(currentId)
        loadUserData()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveCurrentProgress() }
        }
        if current != nil { startup() }
        checkWhatsNew()
        // Here rather than on the player screen, so the next episode also follows in the mini player
        player.$ended.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            Task { @MainActor in self?.playbackEnded() }
        }.store(in: &bag)
    }

    // MARK: what's new

    /// The summary shown after an update (Resources/whats_new.txt, also the GitHub release notes).
    @Published var whatsNew: [String]?

    static var whatsNewLines: [String] {
        guard let u = Bundle.main.url(forResource: "whats_new", withExtension: "txt"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    /// Once per new set of notes, and not on a fresh install (nothing has changed for a new user).
    private func checkWhatsNew() {
        let lines = AppStore.whatsNewLines
        guard !lines.isEmpty else { return }
        let key = String(lines.joined(separator: "\n").utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }) // stable across launches
        let seen = UserDefaults.standard.string(forKey: "whatsNewSeen")
        if seen == key { return }
        UserDefaults.standard.set(key, forKey: "whatsNewSeen")
        if seen == nil && accounts.isEmpty { return }
        whatsNew = lines
    }

    func showWhatsNew() { whatsNew = AppStore.whatsNewLines }

    var current: Account? { accounts.first { $0.id == currentId } }
    var api: XtreamAPI? { current.map { XtreamAPI($0) } }
    var liveFormat: String { UserDefaults.standard.string(forKey: "liveFormat") ?? "ts" }
    var previewMode: Int { (UserDefaults.standard.object(forKey: "previewMode") as? Int) ?? 2 }

    // MARK: accounts

    private func saveAccounts() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: "accounts") }
        UserDefaults.standard.set(currentId?.uuidString, forKey: "currentAccount")
    }

    func addAccount(_ a: Account) {
        accounts.append(a)
        switchTo(a.id)
    }

    func switchTo(_ id: UUID) {
        closePlayer()
        preview.stop()
        currentId = id
        saveAccounts()
        categories = [:]
        items = [:]
        loadError = [:]
        top10Films = []
        top10Series = []
        accountInfo = nil
        guide.reset()
        recRows = []
        downloads.setAccount(id)
        loadUserData()
        filtersChanged()
        page = .home
        startup()
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: userDataURL(id))
        downloads.forget(id)
        if currentId == id {
            if let first = accounts.first { switchTo(first.id) } else {
                closePlayer()
                downloads.setAccount(nil)
                currentId = nil
                categories = [:]
                items = [:]
                data = UserData()
                saveAccounts()
            }
        } else {
            saveAccounts()
        }
    }

    func startup() {
        Task { await ensureLoaded(.live) }
        Task {
            async let a: Void = ensureLoaded(.movie)
            async let b: Void = ensureLoaded(.series)
            _ = await (a, b)
            await loadTop10()
            downloads.pump()
            await loadRecs()
        }
        Task { await refreshAccountInfo() }
    }

    func refreshAccountInfo() async {
        guard let api = api else { return }
        let id = currentId
        if let r = try? await api.login(), id == currentId { accountInfo = XtreamAPI.describe(r) }
    }

    func refreshAll() {
        Task {
            for k in [Kind.live, .movie, .series] { await ensureLoaded(k, force: true) }
            await loadTop10()
        }
        guide.reset()
        show("Refreshing channels, movies and series…")
    }

    // MARK: library

    private func cacheKey(_ k: Kind, _ what: String) -> String { "\(currentId?.uuidString ?? "none")-\(k.rawValue)-\(what).json" }

    func ensureLoaded(_ k: Kind, force: Bool = false) async {
        guard let api = api else { return }
        if loading.contains(k) { return }
        if !force && items[k] != nil { return }
        let account = currentId
        let catKey = cacheKey(k, "categories"), strKey = cacheKey(k, "streams")

        // Saved copy first, so the app is usable straight away; refreshed when it's a few hours old
        if !force, let c = Storage.readCache(catKey), let s = Storage.readCache(strKey) {
            let parsed = await Task.detached(priority: .userInitiated) {
                (XtreamAPI.parseCategories(c.0), XtreamAPI.parseStreams(s.0, k))
            }.value
            guard account == currentId else { return }
            if !parsed.1.isEmpty {
                categories[k] = parsed.0
                items[k] = parsed.1
                filtersChanged()
                if Date().timeIntervalSince(s.1) < 6 * 3600 { return }
            }
        }

        loading.insert(k)
        loadError[k] = nil
        defer { loading.remove(k) }
        do {
            async let cd = api.categoriesData(k)
            async let sd = api.streamsData(k)
            let (c, s) = try await (cd, sd)
            let parsed = await Task.detached(priority: .userInitiated) {
                (XtreamAPI.parseCategories(c), XtreamAPI.parseStreams(s, k))
            }.value
            guard account == currentId else { return }
            categories[k] = parsed.0
            items[k] = parsed.1
            filtersChanged()
            Storage.writeCache(catKey, c)
            Storage.writeCache(strKey, s)
        } catch {
            if items[k] == nil { loadError[k] = error.localizedDescription }
        }
    }

    /// Waits for a load that's already running.
    func waitLoaded(_ k: Kind) async {
        while loading.contains(k) { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    func loadTop10() async {
        guard let t = await Top10.refresh() else { return }
        let movies = visibleItems(.movie), series = visibleItems(.series)
        let result = await Task.detached(priority: .utility) {
            (Top10.match(t.films, movies), Top10.match(t.tv, series))
        }.value
        top10Films = Array(result.0.prefix(10))
        top10Series = Array(result.1.prefix(10))
    }

    // MARK: filtering

    func filtersChanged() {
        filterVersion += 1
        visibleCache = [:]
        groupCache = [:]
        indexCache = [:]
    }

    private func hiddenIds(_ k: Kind, own: Bool) -> Set<String> {
        Set((categories[k] ?? []).filter { Filters.isHidden($0, k, data, own: own) }.map { $0.id })
    }

    func visibleCategories(_ k: Kind) -> [Category] {
        (categories[k] ?? []).filter { !Filters.isHidden($0, k, data) }.map { c in
            if let n = data.catNames[Filters.key(k, c)] { return Category(id: c.id, name: n) }
            return c
        }
    }

    /// Your own name for a category (empty = back to the provider's).
    func renameCategory(_ k: Kind, _ c: Category, to name: String) {
        let key = Filters.key(k, c)
        let n = name.trimmingCharacters(in: .whitespaces)
        let original = categories[k]?.first(where: { $0.id == c.id })?.name
        if n.isEmpty || n == original { data.catNames[key] = nil } else { data.catNames[key] = n }
    }

    func originalName(_ k: Kind, _ c: Category) -> String { categories[k]?.first(where: { $0.id == c.id })?.name ?? c.name }

    /// Everything not in a hidden category.
    func visibleItems(_ k: Kind) -> [Item] {
        if let c = visibleCache[k], c.0 == filterVersion { return c.1 }
        let hidden = hiddenIds(k, own: true)
        let all = items[k] ?? []
        let out = hidden.isEmpty ? all : all.filter { !hidden.contains($0.categoryId ?? "") }
        visibleCache[k] = (filterVersion, out)
        return out
    }

    private func groups(_ k: Kind) -> [String: [Item]] {
        if let g = groupCache[k], g.0 == filterVersion { return g.1 }
        let g = Dictionary(grouping: items[k] ?? [], by: { $0.categoryId ?? "" })
        groupCache[k] = (filterVersion, g)
        return g
    }

    func itemsFor(_ k: Kind, _ selection: String?) -> [Item] {
        let sel = selection ?? Special.all
        if sel == Special.favourites { return favourites(k) }
        if sel == Special.recent { return data.recentChannels }
        if sel == Special.all { return visibleItems(k) }
        return groups(k)[sel] ?? []
    }

    func categoryName(_ k: Kind, _ selection: String?) -> String {
        let sel = selection ?? Special.all
        if sel == Special.favourites { return "Favourites" }
        if sel == Special.recent { return "Recently Watched" }
        if sel == Special.all { return "All " + k.title }
        return visibleCategories(k).first(where: { $0.id == sel })?.name ?? categories[k]?.first(where: { $0.id == sel })?.name ?? k.title
    }

    /// For search: categories you hid yourself still turn up, hidden countries / languages don't.
    func searchIndex(_ k: Kind) async -> [Indexed] {
        if let c = indexCache[k], c.0 == filterVersion { return c.1 }
        let v = filterVersion
        let hidden = hiddenIds(k, own: false)
        let all = items[k] ?? []
        let built = await Task.detached(priority: .userInitiated) {
            all.filter { !hidden.contains($0.categoryId ?? "") }.map { Indexed($0) }
        }.value
        if v == filterVersion { indexCache[k] = (v, built) }
        return built
    }

    func detectedTags() -> [TagCount] {
        var counts: [String: Int] = [:]
        for k in [Kind.live, .movie, .series] {
            for c in categories[k] ?? [] { if let t = Filters.tag(c.name) { counts[t, default: 0] += 1 } }
        }
        for t in data.hiddenTags where counts[t] == nil { counts[t] = 0 }
        return counts.map { TagCount(tag: $0.key, count: $0.value) }
            .sorted { a, b in a.count != b.count ? a.count > b.count : Filters.tagName(a.tag) < Filters.tagName(b.tag) }
    }

    func setTag(_ t: String, hidden: Bool) {
        if hidden { data.hiddenTags.insert(t) } else { data.hiddenTags.remove(t) }
        filtersChanged()
    }

    func setTags(_ tags: [String], hidden: Bool) {
        for t in tags { if hidden { data.hiddenTags.insert(t) } else { data.hiddenTags.remove(t) } }
        filtersChanged()
    }

    /// All hidden categories, both yours and those hidden by a country / language filter.
    func hiddenCategoryList() -> [(Kind, Category)] {
        var out: [(Kind, Category)] = []
        for k in [Kind.live, .movie, .series] {
            for c in categories[k] ?? [] where Filters.isHidden(c, k, data) { out.append((k, c)) }
        }
        return out
    }

    func isHidden(_ k: Kind, _ c: Category) -> Bool { Filters.isHidden(c, k, data) }

    func setHidden(_ k: Kind, _ c: Category, _ hidden: Bool) {
        let key = Filters.key(k, c)
        if hidden {
            if Filters.hiddenByTag(c, data) { data.alwaysShown.remove(key) } else { data.hiddenCategories.insert(key) }
            data.favCategories.remove(key)
        } else {
            data.hiddenCategories.remove(key)
            if Filters.isHidden(c, k, data) { data.alwaysShown.insert(key) }
        }
        filtersChanged()
    }

    func hideCategory(_ k: Kind, _ c: Category) {
        setHidden(k, categories[k]?.first(where: { $0.id == c.id }) ?? c, true) // the provider's name, not your rename
        show("Hidden: \(c.name)  —  bring it back in Settings → Hidden Categories")
    }

    // MARK: favourites, history

    func isFavourite(_ it: Item) -> Bool { data.favourites.contains { $0.id == it.id } }

    func toggleFavourite(_ it: Item) {
        if let i = data.favourites.firstIndex(where: { $0.id == it.id }) {
            data.favourites.remove(at: i)
            show("Removed from Favourites")
        } else {
            data.favourites.insert(it, at: 0)
            show("Added to Favourites")
        }
    }

    func favourites(_ k: Kind) -> [Item] { data.favourites.filter { $0.kind == k } }

    func isFavCategory(_ k: Kind, _ c: Category) -> Bool { data.favCategories.contains(Filters.key(k, c)) }

    func toggleFavCategory(_ k: Kind, _ c: Category) {
        let key = Filters.key(k, c)
        if data.favCategories.contains(key) { data.favCategories.remove(key) } else { data.favCategories.insert(key) }
    }

    func addRecent(_ it: Item) {
        data.recentChannels.removeAll { $0.id == it.id }
        data.recentChannels.insert(it, at: 0)
        if data.recentChannels.count > 30 { data.recentChannels.removeLast(data.recentChannels.count - 30) }
    }

    /// Unfinished movies and episodes, newest first, one entry per series.
    var continueWatching: [WatchProgress] {
        var seen = Set<String>()
        var out: [WatchProgress] = []
        for p in data.progress.values.sorted(by: { $0.updated > $1.updated }) {
            let key = p.item.kind == .episode ? "s:" + (p.item.seriesId ?? p.item.id) : p.item.id
            if seen.insert(key).inserted { out.append(p) }
        }
        return out
    }

    func removeFromContinue(_ p: WatchProgress) {
        if p.item.kind == .episode, let s = p.item.seriesId {
            data.progress = data.progress.filter { $0.value.item.seriesId != s }
        } else {
            data.progress[p.item.id] = nil
        }
    }

    // MARK: already watched

    func isWatched(_ it: Item) -> Bool { data.watched.contains(it.id) }

    /// Watched: off Continue Watching and out of the Queue.
    func setWatched(_ it: Item, _ w: Bool) {
        if w {
            data.watched.insert(it.id)
            data.progress[it.id] = nil
            data.queue.removeAll { $0.id == it.id }
        } else {
            data.watched.remove(it.id)
        }
    }

    func setWatched(_ list: [Item], _ w: Bool) {
        for it in list {
            if w { data.watched.insert(it.id); data.progress[it.id] = nil } else { data.watched.remove(it.id) }
        }
        if w {
            let ids = Set(list.map(\.id))
            data.queue.removeAll { ids.contains($0.id) }
        }
    }

    func watchedCount(_ list: [Item]) -> Int { list.filter { data.watched.contains($0.id) }.count }

    // MARK: queue

    func inQueue(_ it: Item) -> Bool { data.queue.contains { $0.id == it.id } }

    func toggleQueue(_ it: Item) {
        if inQueue(it) {
            data.queue.removeAll { $0.id == it.id }
            show("Removed from your Queue")
        } else {
            data.queue.append(it)
            show("Added to your Queue")
        }
    }

    /// Done with this one: watched, and the next episode goes into Continue Watching, ready at the start.
    private func finished(_ s: PlaySession) {
        setWatched(s.item, true)
        guard s.item.kind == .episode, let sid = s.item.seriesId,
              let i = s.list.firstIndex(where: { $0.id == s.item.id }), i + 1 < s.list.count else { return }
        let nx = s.list[i + 1]
        guard nx.kind == .episode, nx.seriesId == sid, !data.watched.contains(nx.id), data.progress[nx.id] == nil else { return }
        data.progress[nx.id] = WatchProgress(item: nx, position: 0, duration: 0, updated: Date())
    }

    func moveInQueue(_ it: Item, to index: Int) {
        guard let i = data.queue.firstIndex(where: { $0.id == it.id }) else { return }
        let x = data.queue.remove(at: i)
        data.queue.insert(x, at: min(max(0, index), data.queue.count))
    }

    /// What plays after the current film / episode: the next episode, or else the next in your Queue.
    var upNext: Item? {
        guard let s = session, s.item.kind != .live else { return nil }
        if s.item.kind == .episode, let i = s.list.firstIndex(where: { $0.id == s.item.id }), i + 1 < s.list.count { return s.list[i + 1] }
        return data.queue.first { $0.id != s.item.id }
    }

    func playNext() {
        guard let s = session, let nx = upNext else { return }
        // Watched only if you got near the end (play() saves where you were otherwise)
        if player.duration > 60, player.time / player.duration >= 0.9 || player.duration - player.time < 60 { finished(s) }
        if s.item.kind == .episode, s.list.contains(where: { $0.id == nx.id }) {
            play(nx, list: s.list, from: 0)
        } else {
            play(nx)
        }
    }

    func saveCurrentProgress() {
        guard let s = session, s.item.kind != .live, player.url != nil, player.duration > 60 else { return }
        let pos = player.time, dur = player.duration
        if pos / dur >= 0.9 || dur - pos < 60 {
            if !data.watched.contains(s.item.id) || data.progress[s.item.id] != nil { finished(s) }
        } else if pos > 20 {
            data.progress[s.item.id] = WatchProgress(item: s.item, position: pos, duration: dur, updated: Date())
        }
    }

    // MARK: playback

    func open(_ it: Item, list: [Item] = []) {
        switch it.kind {
        case .live, .episode: play(it, list: list)
        case .movie, .series: detail = it
        }
    }

    func play(_ it: Item, list: [Item] = [], from start: Double? = nil) {
        guard let api = api, let streamURL = api.playURL(it, liveFormat: liveFormat) else { return }
        let url = it.kind == .live ? streamURL : (downloads.localURL(for: it) ?? streamURL) // downloaded: play from the Mac
        saveCurrentProgress()
        preview.stop()
        var at = start ?? 0
        if start == nil, it.kind != .live, let p = data.progress[it.id], p.position > 30, p.fraction < 0.95 { at = p.position }
        if session?.item.id != it.id { endRetries = 0 }
        session = PlaySession(item: it, list: list.isEmpty ? [it] : list)
        if it.kind == .live { addRecent(it) } else {
            data.recentVOD.removeAll { $0.id == it.id }
            data.recentVOD.insert(it, at: 0)
            if data.recentVOD.count > 40 { data.recentVOD.removeLast(data.recentVOD.count - 40) }
        }
        player.play(url: url, start: at, live: it.kind == .live)
        loadSegments(it)
    }

    /// Episodes: where the intro and credits are (TheIntroDB), for Skip Intro and the Next Episode card.
    func loadSegments(_ it: Item) {
        segments = nil
        guard it.kind == .episode, let season = it.season, let ep = it.episode, let series = it.seriesName else { return }
        let id = it.id
        Task {
            guard let tmdb = await Tmdb.findId(.tv, name: series, known: it.tmdb),
                  let s = await Segments.fetch(tmdb: tmdb, season: season, episode: ep) else { return }
            if session?.item.id == id { segments = s }
        }
    }

    /// "Because you watched …" rows: TMDB recommendations for what you've watched lately that your provider has.
    func loadRecs() async {
        var sources: [Item] = []
        var seen = Set<String>()
        for h in data.recentVOD {
            if sources.count >= 3 { break }
            let src: Item
            if h.kind == .episode, let sid = h.seriesId {
                var s = Item(kind: .series, streamId: sid, name: h.seriesName ?? h.name)
                s.tmdb = h.tmdb
                src = s
            } else { src = h }
            if seen.insert(src.id).inserted { sources.append(src) }
        }
        guard !sources.isEmpty else { recRows = []; return }
        let account = currentId
        let movies = visibleItems(.movie), series = visibleItems(.series)
        var rows: [RecRow] = []
        var shown = Set<String>()
        for src in sources {
            let tv = src.kind == .series
            guard let id = await Tmdb.findId(tv ? .tv : .movie, name: src.name, known: src.tmdb) else { continue }
            let titles = await Tmdb.recommendations(tv ? .tv : .movie, id: id)
            let lib = tv ? series : movies
            let found = await Task.detached(priority: .utility) { Top10.match(titles, lib) }.value
            var keep: [Item] = []
            for it in found where it.id != src.id && !data.watched.contains(it.id) && shown.insert(it.id).inserted {
                keep.append(it)
                if keep.count >= 20 { break }
            }
            let name = Tmdb.clean(src.name).name
            if keep.count >= 3 { rows.append(RecRow(title: "Because you watched " + (name.isEmpty ? src.name : name), items: keep)) }
        }
        guard account == currentId else { return } // switched account meanwhile
        recRows = rows
    }

    func startPreview(_ ch: Item) {
        guard session == nil, previewMode > 0, let url = api?.playURL(ch, liveFormat: liveFormat) else { return }
        preview.muted = previewMode == 1
        preview.play(url: url, live: true)
    }

    func closePlayer() {
        saveCurrentProgress()
        player.stop()
        session = nil
        if mini {
            mini = false
            MiniWindow.shared.close()
        }
    }

    /// Next / previous channel (or episode) in the list it was opened from.
    func step(_ d: Int) {
        guard let s = session, let i = s.list.firstIndex(where: { $0.id == s.item.id }) else { return }
        let n = s.list.count
        guard n > 1 else { return }
        let j = s.item.kind == .live ? ((i + d) % n + n) % n : i + d
        guard j >= 0 && j < n else { return }
        let next = s.list[j]
        play(next, list: s.list, from: s.item.kind == .live ? nil : 0)
        show(next.kind == .live ? (next.num.map { "\($0)  " } ?? "") + next.name : (next.episodeLabel ?? "") + "  " + next.name)
    }

    var hasNextEpisode: Bool {
        guard let s = session, s.item.kind == .episode, let i = s.list.firstIndex(where: { $0.id == s.item.id }) else { return false }
        return i + 1 < s.list.count
    }

    func playbackEnded() {
        guard let s = session else { return }
        // Stopped well before the end: the connection dropped, it didn't finish. Pick up where it stopped.
        let t = player.time, d = player.duration
        if s.item.kind != .live, d > 60, t > 0, t < d * 0.9, d - t > 60 {
            if endRetries < 3 {
                endRetries += 1
                show("Reconnecting…")
                play(s.item, list: s.list, from: t)
            } else {
                saveCurrentProgress()
                show("The stream stopped — your place is saved")
                closePlayer()
            }
            return
        }
        finished(s)
        if upNext != nil { playNext() } else { closePlayer() }
    }

    func enterMini() {
        guard session != nil, !mini else { return }
        mini = true
        if let w = MainWindow.window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        MiniWindow.shared.show(store: self)
    }

    func exitMini() {
        guard mini else { return }
        MiniWindow.shared.close()
        mini = false
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: messages

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: saving

    private func userDataURL(_ id: UUID) -> URL { Storage.support.appendingPathComponent("account-\(id.uuidString).json") }

    private func loadUserData() {
        guard let id = currentId, let d = try? Data(contentsOf: userDataURL(id)), let u = try? JSONDecoder().decode(UserData.self, from: d) else {
            data = UserData()
            return
        }
        data = u
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data, id = currentId
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            guard let id = id, let d = try? JSONEncoder().encode(snapshot) else { return }
            try? d.write(to: userDataURL(id), options: .atomic)
        }
    }
}

/// TV guide listings, fetched per channel as rows come into view and kept for 30 minutes.
@MainActor
final class EpgStore: ObservableObject {
    @Published private(set) var listings: [String: [Programme]] = [:]
    var apiProvider: () -> XtreamAPI? = { nil }
    private var fetched: [String: Date] = [:]
    private var inflight: Set<String> = []

    func get(_ id: String) -> [Programme]? { listings[id] }

    func now(_ id: String) -> Programme? { listings[id]?.first { $0.isNow } }

    func request(_ ch: Item) {
        let id = ch.streamId
        if inflight.contains(id) { return }
        if let t = fetched[id], Date().timeIntervalSince(t) < 1800 { return }
        guard let api = apiProvider() else { return }
        inflight.insert(id)
        Task {
            let l = await api.epg(id, limit: 24)
            inflight.remove(id)
            fetched[id] = Date()
            listings[id] = l
        }
    }

    func reset() {
        listings = [:]
        fetched = [:]
        inflight = []
    }
}
