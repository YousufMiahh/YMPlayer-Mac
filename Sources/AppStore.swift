import SwiftUI

enum Page: String, Hashable, CaseIterable, Identifiable {
    case home, live, movies, series, search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .search: return "Search"
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

    let player = PlayerModel()
    let preview = PlayerModel()
    let guide = EpgStore()

    private var saveTask: Task<Void, Never>?
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
        loadUserData()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveCurrentProgress() }
        }
        if current != nil { startup() }
    }

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
        loadUserData()
        filtersChanged()
        page = .home
        startup()
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: userDataURL(id))
        if currentId == id {
            if let first = accounts.first { switchTo(first.id) } else {
                closePlayer()
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
        (categories[k] ?? []).filter { !Filters.isHidden($0, k, data) }
    }

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
        return categories[k]?.first(where: { $0.id == sel })?.name ?? k.title
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
        setHidden(k, c, true)
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

    func saveCurrentProgress() {
        guard let s = session, s.item.kind != .live, player.url != nil, player.duration > 60 else { return }
        let pos = player.time, dur = player.duration
        if pos / dur > 0.95 {
            data.progress[s.item.id] = nil
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
        guard let api = api, let url = api.playURL(it, liveFormat: liveFormat) else { return }
        saveCurrentProgress()
        preview.stop()
        var at = start ?? 0
        if start == nil, it.kind != .live, let p = data.progress[it.id], p.position > 30, p.fraction < 0.95 { at = p.position }
        session = PlaySession(item: it, list: list.isEmpty ? [it] : list)
        if it.kind == .live { addRecent(it) }
        player.play(url: url, start: at, live: it.kind == .live)
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
        data.progress[s.item.id] = nil
        if s.item.kind == .episode && hasNextEpisode { step(1) } else { closePlayer() }
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
