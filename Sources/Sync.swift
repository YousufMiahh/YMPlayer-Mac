import Foundation
import AppKit

/// Cross-device sync for the Mac: favourites, resume points, Continue Watching, watched, queue,
/// hidden and renamed categories and picture shape, shared with your other YM Player devices that
/// use the same login. Format and encryption: SyncCore. Server: Supabase (two functions only).
@MainActor
final class SyncService: ObservableObject {
    static let url = "https://lqvwqqfdolxkthdqsnct.supabase.co"
    /// The public ("publishable") key: it can only call the two sync functions.
    static let key = "sb_publishable_PiM4D3uKIbWhVDd4AzL5Vw_QX8f9J8u"
    /// The maps the Mac keeps (no per-title audio sync here); others pass through untouched.
    static let maps = SyncCore.maps.filter { $0 != "adelay" }

    typealias J = SyncCore.J

    weak var store: AppStore?
    @Published private(set) var syncing = false
    @Published private(set) var stamp = 0 // bumps when the status changes (Settings redraws)

    private var running = false, again = false
    private var pending: Task<Void, Never>?
    private var applying = false
    private var timer: Timer?
    private var settingsPrint = ""

    var configured: Bool { !SyncService.url.isEmpty && !SyncService.key.isEmpty }
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "cloudSync") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "cloudSync")
            stamp += 1
            if newValue { soon(0.3) }
        }
    }

    func start(_ s: AppStore) {
        store = s
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumed() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.now() }
        }
        // another device's changes show within half a minute while YM Player is in front
        settingsPrint = SyncService.settingsFingerprint()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let f = SyncService.settingsFingerprint()
                if f != self.settingsPrint { self.settingsPrint = f; self.soon(4) } // subtitle style, languages, Home rows
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in if NSApp.isActive { self?.now() } }
        }
        soon(1.5)
    }

    /// The account's data changed on this Mac.
    func changed(from old: UserData, to new: UserData) {
        if applying { return }
        var o = old
        o.progress = new.progress
        let removed = old.progress.keys.contains { new.progress[$0] == nil } // taken off Continue Watching
        if o == new && !removed { later() } else { soon(4) } // only resume points (while playing): at most every 20 s
    }

    func soon(_ seconds: Double) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.pending = nil
            self?.now()
        }
    }

    func later() { if pending == nil { soon(20) } }

    /// The app came to the front: get what other devices changed straight away.
    func resumed() { soon(0.3) }

    // MARK: status

    private func k(_ name: String) -> String { "sync.\(name).\(store?.currentId?.uuidString ?? "-")" }
    var lastOk: Date? { UserDefaults.standard.object(forKey: k("ok")) as? Date }
    private var lastFail: Date? { UserDefaults.standard.object(forKey: k("fail")) as? Date }

    /// "Synced 2 min ago", or why it isn't.
    var label: String {
        _ = stamp
        if !configured { return "Not set up in this version" }
        if !enabled { return "Off" }
        if syncing { return "Syncing…" }
        if let f = lastFail, f > (lastOk ?? .distantPast) { return "Couldn't reach the sync server" }
        guard let ok = lastOk else { return "Not synced yet" }
        let min = Int(Date().timeIntervalSince(ok) / 60)
        if min < 1 { return "Synced just now" }
        if min < 60 { return "Synced \(min) min ago" }
        return "Synced \(min / 60) h ago"
    }

    // MARK: running

    func now() {
        pending?.cancel()
        pending = nil
        if running { again = true; return }
        guard configured, enabled, let s = store, let acc = s.current, let accId = s.currentId else { return }
        running = true
        syncing = true
        Task {
            let ok = await once(s, acc, accId)
            UserDefaults.standard.set(Date(), forKey: ok ? k("ok") : k("fail"))
            running = false
            syncing = false
            stamp += 1
            if again { again = false; now() }
        }
    }

    private var shadowURL: (UUID) -> URL = { Storage.support.appendingPathComponent("sync-\($0.uuidString).json") }

    private func keys(_ acc: Account, _ id: UUID) async -> (String, Data) {
        let fp = SyncCore.sha256Hex(acc.server + "\n" + acc.user + "\n" + acc.pass)
        if let saved = UserDefaults.standard.string(forKey: "sync.keys.\(id.uuidString)") {
            let p = saved.split(separator: ",").map(String.init)
            if p.count == 3, p[0] == fp { return (p[1], SyncCore.unhex(p[2])) }
        }
        let server = acc.server, user = acc.user, pass = acc.pass
        let k = await Task.detached { SyncCore.deriveKeys(server: server, user: user, pass: pass) }.value
        UserDefaults.standard.set("\(fp),\(k.id),\(SyncCore.hex(k.key))", forKey: "sync.keys.\(id.uuidString)")
        return (k.id, k.key)
    }

    private func once(_ s: AppStore, _ acc: Account, _ accId: UUID) async -> Bool {
        do {
            let (id, key) = await keys(acc, accId)
            for _ in 0..<3 {
                guard s.currentId == accId else { return true }
                let shadow = (try? Data(contentsOf: shadowURL(accId))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? J }
                let prev = readLocal(s.data)
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let local = SyncCore.stamp(prev, shadow: shadow, now: nowMs, maps: SyncService.maps)
                let rows = try await rpc("ym_sync_get", ["p_id": id]) as? [J] ?? []
                let row = rows.first
                var remote: J? = nil
                if let blob = row?["data"] as? String, let plain = try? SyncCore.decrypt(key: key, blob: blob) {
                    remote = try? JSONSerialization.jsonObject(with: plain) as? J
                }
                let m = SyncCore.merge(local, remote ?? SyncCore.emptyDoc(), now: nowMs)
                if remote == nil || m.dirty {
                    let json = try JSONSerialization.data(withJSONObject: m.doc)
                    let body: J = ["p_id": id, "p_data": try SyncCore.encrypt(key: key, json: json),
                                   "p_version": SyncCore.num(row?["version"])]
                    let v = try await rpc("ym_sync_put", body)
                    if v == nil || v is NSNull { continue } // another device saved first: merge with theirs
                }
                guard s.currentId == accId else { return true }
                writeLocal(s, SyncCore.toState(m.doc), prev)
                if let d = try? JSONSerialization.data(withJSONObject: m.doc) { try? d.write(to: shadowURL(accId), options: .atomic) }
                return true
            }
        } catch {
            print("sync failed: \(error)")
        }
        return false
    }

    private func rpc(_ fn: String, _ body: J) async throws -> Any? {
        var r = URLRequest(url: URL(string: SyncService.url + "/rest/v1/rpc/" + fn)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue(SyncService.key, forHTTPHeaderField: "apikey")
        if SyncService.key.hasPrefix("eyJ") { r.setValue("Bearer " + SyncService.key, forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    // MARK: the Mac's data <-> the shared format

    static func wire(_ it: Item) -> J {
        var o: J = ["type": it.kind.rawValue, "id": it.streamId, "name": it.name]
        o["icon"] = it.icon
        o["ext"] = it.ext
        o["num"] = it.num
        o["plot"] = it.plot
        o["cat"] = it.categoryId
        if it.added > 0 { o["added"] = it.added }
        o["pid"] = it.seriesId
        o["pname"] = it.seriesName
        o["picon"] = it.cover
        o["dur"] = it.duration
        o["season"] = it.season
        o["ep"] = it.episode
        o["tmdb"] = it.tmdb
        return o
    }

    static func item(_ v: Any?) -> Item? {
        guard let o = v as? J, let kind = Kind(rawValue: o["type"] as? String ?? ""), let sid = (o["id"] as? String) ?? (o["id"] as? NSNumber)?.stringValue else { return nil }
        func s(_ k: String) -> String? { let x = o[k] as? String; return x?.isEmpty == true ? nil : x }
        var it = Item(kind: kind, streamId: sid, name: o["name"] as? String ?? "")
        it.icon = s("icon")
        it.ext = s("ext")
        it.num = s("num")
        it.plot = s("plot")
        it.categoryId = s("cat")
        it.added = SyncCore.num(o["added"])
        it.seriesId = s("pid")
        it.seriesName = s("pname")
        it.cover = s("picon")
        it.duration = s("dur")
        if let se = o["season"] as? NSNumber, se.intValue >= 0 { it.season = se.intValue }
        if let ep = o["ep"] as? NSNumber { it.episode = ep.intValue }
        it.tmdb = s("tmdb")
        return it
    }

    // MARK: settings shared too (subtitle style and languages, Home rows)

    /// Shared name → this Mac's UserDefaults key.
    static var settingKeys: [String: String] {
        var m = ["sub_size": "subSize", "sub_color": "subColour", "sub_bg": "subBackground", "sub_bg_opacity": "subOpacity",
                 "sub_lang": "subLang", "audio_lang": "audioLang"]
        for r in HomeRows.all { m["home_" + r.key] = "home." + r.key }
        return m
    }

    /// Only ones set on this Mac (a default here mustn't replace a choice made on another device).
    static func readSettings() -> J {
        var out = J()
        let d = UserDefaults.standard
        for (name, key) in settingKeys {
            guard let v = d.object(forKey: key) else { continue }
            if name == "sub_bg" || name.hasPrefix("home_") { out[name] = ["v": (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)] as J }
            else if name == "sub_lang" || name == "audio_lang" { out[name] = ["v": v as? String ?? ""] as J }
            else { out[name] = ["v": (v as? NSNumber)?.intValue ?? 0] as J }
        }
        return out
    }

    /// A snapshot to notice changes made in Settings (UserDefaults has no per-key notice).
    static func settingsFingerprint() -> String {
        let d = UserDefaults.standard
        return settingKeys.values.sorted().map { "\($0)=\(String(describing: d.object(forKey: $0)))" }.joined(separator: ";")
    }

    private func writeSettings(_ next: J, _ prev: J) {
        let d = UserDefaults.standard
        var homeChanged = false
        for (name, key) in SyncService.settingKeys {
            guard let e = next[name] as? J, let v = e["v"], !(v is NSNull) else { continue }
            if let p = prev[name] as? J, SyncCore.canon(p["v"]) == SyncCore.canon(v) { continue }
            if name == "sub_bg" || name.hasPrefix("home_") { d.set((v as? NSNumber)?.boolValue ?? false, forKey: key); homeChanged = homeChanged || name.hasPrefix("home_") }
            else if name == "sub_lang" || name == "audio_lang" { d.set(v as? String ?? "", forKey: key) }
            else { d.set((v as? NSNumber)?.intValue ?? 0, forKey: key) }
        }
        if homeChanged { d.set(d.integer(forKey: "homeRowsVersion") + 1, forKey: "homeRowsVersion") }
        settingsPrint = SyncService.settingsFingerprint()
    }

    /// Mac picture keys: episodes share "series:<id>"; the shared format says "series_<id>".
    private static func picOut(_ k: String) -> String { k.hasPrefix("series:") ? "series_" + k.dropFirst(7) : k }
    private static func picIn(_ k: String) -> String { k.hasPrefix("series_") ? "series:" + k.dropFirst(7) : k }

    func readLocal(_ d: UserData) -> J {
        var st = J()
        var pos = J(), up = J(), fav = J(), queue = J(), hist = J(), names = J(), pic = J()
        for (k, p) in d.progress {
            let at = p.position.isFinite ? p.position : 0, len = p.duration.isFinite ? max(0, p.duration) : 0
            if at > 0 {
                pos[k] = ["p": Int64(at * 1000), "d": Int64(len * 1000), "i": SyncService.wire(p.item)] as J
            } else {
                up[k] = ["i": SyncService.wire(p.item)] as J
            }
        }
        func set(_ s: Set<String>) -> J { var o = J(); for k in s { o[k] = J() }; return o }
        for (i, it) in d.favourites.enumerated() { fav[it.id] = ["o": i, "i": SyncService.wire(it)] as J }
        for (i, it) in d.queue.enumerated() { queue[it.id] = ["o": i, "i": SyncService.wire(it)] as J }
        for (i, it) in d.recentChannels.enumerated() { hist[it.id] = ["o": i, "i": SyncService.wire(it)] as J }
        for (i, it) in d.recentVOD.enumerated() { hist[it.id] = ["o": i, "i": SyncService.wire(it)] as J }
        for (k, n) in d.catNames { names[k] = ["n": n] as J }
        for (k, m) in d.picture where m > 0 { pic[SyncService.picOut(k)] = ["m": m] as J }
        st["pos"] = pos; st["up"] = up; st["fav"] = fav; st["queue"] = queue; st["hist"] = hist
        st["watched"] = set(d.watched); st["favcat"] = set(d.favCategories); st["hidecat"] = set(d.hiddenCategories)
        st["showcat"] = set(d.alwaysShown); st["hidetag"] = set(d.hiddenTags); st["recblock"] = set(d.recBlocked)
        st["catname"] = names; st["pic"] = pic
        st["settings"] = SyncService.readSettings()
        return st
    }

    private func sorted(_ m: J) -> [(String, J)] {
        m.compactMap { k, v in (v as? J).map { (k, $0) } }.sorted { SyncCore.num($0.1["o"]) < SyncCore.num($1.1["o"]) }
    }

    /// Applies what differs between next and prev (what readLocal gave) in one change.
    private func writeLocal(_ s: AppStore, _ next: J, _ prev: J) {
        let diff = (SyncService.maps + ["hist"]).filter { !SyncCore.sameMap($0, next[$0] as? J, prev[$0] as? J) }
        if diff.isEmpty { return }
        var d = s.data
        func keys(_ m: String) -> Set<String> { Set((next[m] as? J ?? [:]).keys) }
        let histItems = Dictionary((next["hist"] as? J ?? [:]).compactMap { k, v in SyncService.item((v as? J)?["i"]).map { (k, $0) } }, uniquingKeysWith: { a, _ in a })
        if diff.contains("pos") || diff.contains("up") {
            let pos = next["pos"] as? J ?? [:], up = next["up"] as? J ?? [:]
            var progress: [String: WatchProgress] = [:]
            for (k, v) in pos {
                guard let e = v as? J else { continue }
                let it = SyncService.item(e["i"]) ?? d.progress[k]?.item ?? histItems[k]
                guard let item = it else { continue }
                let p = Double(SyncCore.num(e["p"])) / 1000, dur = Double(SyncCore.num(e["d"])) / 1000
                if let old = d.progress[k], abs(old.position - p) < 1, abs(old.duration - dur) < 1 { progress[k] = old; continue }
                progress[k] = WatchProgress(item: item, position: p, duration: dur, updated: Date())
            }
            for (k, v) in up where progress[k] == nil {
                let it = SyncService.item((v as? J)?["i"]) ?? d.progress[k]?.item ?? histItems[k]
                guard let item = it else { continue }
                progress[k] = d.progress[k].flatMap { $0.position == 0 ? $0 : nil } ?? WatchProgress(item: item, position: 0, duration: 0, updated: Date())
            }
            d.progress = progress
        }
        if diff.contains("watched") { d.watched = keys("watched") }
        if diff.contains("favcat") { d.favCategories = keys("favcat") }
        if diff.contains("hidecat") { d.hiddenCategories = keys("hidecat") }
        if diff.contains("showcat") { d.alwaysShown = keys("showcat") }
        if diff.contains("hidetag") { d.hiddenTags = keys("hidetag") }
        if diff.contains("recblock") { d.recBlocked = keys("recblock") }
        if diff.contains("fav") { d.favourites = sorted(next["fav"] as? J ?? [:]).compactMap { SyncService.item($0.1["i"]) } }
        if diff.contains("queue") { d.queue = sorted(next["queue"] as? J ?? [:]).compactMap { SyncService.item($0.1["i"]) } }
        if diff.contains("catname") {
            var n: [String: String] = [:]
            for (k, v) in next["catname"] as? J ?? [:] { if let s = (v as? J)?["n"] as? String, !s.isEmpty { n[k] = s } }
            d.catNames = n
        }
        if diff.contains("pic") {
            var p: [String: Int] = [:]
            for (k, v) in next["pic"] as? J ?? [:] { let m = Int(SyncCore.num((v as? J)?["m"])); if m > 0 { p[SyncService.picIn(k)] = m } }
            d.picture = p
        }
        if diff.contains("settings") { writeSettings(next["settings"] as? J ?? [:], prev["settings"] as? J ?? [:]) }
        if diff.contains("hist") {
            let h = sorted(next["hist"] as? J ?? [:])
            d.recentChannels = h.filter { $0.0.hasPrefix("live:") }.compactMap { SyncService.item($0.1["i"]) }
            d.recentVOD = h.filter { !$0.0.hasPrefix("live:") }.compactMap { SyncService.item($0.1["i"]) }
        }
        applying = true
        s.data = d
        applying = false
        if diff.contains(where: { ["hidecat", "showcat", "hidetag", "catname"].contains($0) }) { s.filtersChanged() }
    }
}
