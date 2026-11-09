import Foundation

enum APIError: LocalizedError {
    case badServer, http(Int), auth, notXtream

    var errorDescription: String? {
        switch self {
        case .badServer: return "Check the server address."
        case .http(let c): return "The server replied with error \(c)."
        case .auth: return "Wrong username or password, or the account has expired."
        case .notXtream: return "This doesn't look like an Xtream server. Check the address."
        }
    }
}

/// Xtream Codes "player_api.php" client.
final class XtreamAPI {
    static let userAgent = "XtreamPlayer/1.0 (Macintosh; Mac OS X)"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 40
        c.timeoutIntervalForResource = 600
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    let base: String
    let user: String
    let pass: String

    init(_ a: Account) {
        base = XtreamAPI.normalize(a.server)
        user = a.user.trimmingCharacters(in: .whitespaces)
        pass = a.pass
    }

    /// Turns whatever was typed into "http(s)://host:port".
    static func normalize(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        let low = s.lowercased()
        if !low.hasPrefix("http://") && !low.hasPrefix("https://") { s = "http://" + s }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        for t in ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"] where s.hasSuffix(t) { s = String(s.dropLast(t.count)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: XtreamAPI.unreserved) ?? s }

    func apiURL(_ action: String?, _ extra: String = "") -> URL? {
        var s = base + "/player_api.php?username=" + enc(user) + "&password=" + enc(pass)
        if let a = action { s += "&action=" + a }
        return URL(string: s + extra)
    }

    func get(_ url: URL?) async throws -> Data {
        guard let url = url else { throw APIError.badServer }
        var r = URLRequest(url: url)
        r.setValue(XtreamAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await XtreamAPI.session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw APIError.http(h.statusCode) }
        return d
    }

    // MARK: account

    func login() async throws -> [String: Any] {
        let d = try await get(apiURL(nil))
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw APIError.notXtream }
        guard let u = o["user_info"] as? [String: Any], str(u["auth"]) != "0" else { throw APIError.auth }
        return o
    }

    static func describe(_ r: [String: Any]) -> String {
        guard let u = r["user_info"] as? [String: Any] else { return "" }
        var parts = ["Status: " + (str(u["status"]) ?? "?")]
        if let e = str(u["exp_date"]), let t = Double(e) {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy"
            parts.append("Expires: " + f.string(from: Date(timeIntervalSince1970: t)))
        } else {
            parts.append("Expires: never")
        }
        if let m = str(u["max_connections"]) { parts.append("Connections: \(str(u["active_cons"]) ?? "0")/\(m)") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: lists

    func categoriesData(_ k: Kind) async throws -> Data {
        try await get(apiURL(k == .live ? "get_live_categories" : k == .movie ? "get_vod_categories" : "get_series_categories"))
    }

    func streamsData(_ k: Kind) async throws -> Data {
        try await get(apiURL(k == .live ? "get_live_streams" : k == .movie ? "get_vod_streams" : "get_series"))
    }

    static func parseCategories(_ d: Data) -> [Category] {
        guard let a = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return [] }
        var out: [Category] = []
        for case let o as [String: Any] in a {
            guard let id = str(o["category_id"]) else { continue }
            out.append(Category(id: id, name: clean(o["category_name"])))
        }
        return out
    }

    static func parseStreams(_ d: Data, _ k: Kind) -> [Item] {
        guard let a = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return [] }
        var out: [Item] = []
        out.reserveCapacity(a.count)
        for case let o as [String: Any] in a {
            if k == .series {
                guard let id = str(o["series_id"]) else { continue }
                var it = Item(kind: .series, streamId: id, name: clean(o["name"]))
                it.icon = str(o["cover"])
                it.plot = str(o["plot"])
                it.genre = str(o["genre"])
                it.rating = ratingText(o["rating"])
                it.added = Int64(str(o["last_modified"]) ?? "") ?? 0
                it.categoryId = str(o["category_id"])
                out.append(it)
            } else {
                guard let id = str(o["stream_id"]) else { continue }
                var it = Item(kind: k, streamId: id, name: clean(o["name"]))
                it.icon = str(o["stream_icon"])
                it.num = str(o["num"])
                it.ext = str(o["container_extension"])
                if k == .movie { it.rating = ratingText(o["rating"]) }
                it.added = Int64(str(o["added"]) ?? "") ?? 0
                it.categoryId = str(o["category_id"])
                out.append(it)
            }
        }
        return out
    }

    // MARK: details

    func seriesInfo(_ s: Item) async throws -> SeriesInfo {
        let d = try await get(apiURL("get_series_info", "&series_id=" + enc(s.streamId)))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let info = o["info"] as? [String: Any] ?? [:]
        var si = SeriesInfo()
        si.name = str(info["name"]) ?? s.name
        si.plot = str(info["plot"]) ?? s.plot
        si.genre = str(info["genre"]) ?? s.genre
        si.cast = str(info["cast"])
        si.releaseDate = str(info["releaseDate"]) ?? str(info["release_date"])
        si.rating = ratingText(info["rating"]) ?? s.rating
        si.cover = str(info["cover"]) ?? s.icon
        if let b = info["backdrop_path"] as? [Any] { si.backdrop = b.compactMap { str($0) }.first } else { si.backdrop = str(info["backdrop_path"]) }

        var eps: [[String: Any]] = []
        if let m = o["episodes"] as? [String: Any] {
            for (_, v) in m {
                if let arr = v as? [Any] { for case let e as [String: Any] in arr { eps.append(e) } }
            }
        } else if let arr = o["episodes"] as? [Any] {
            for v in arr {
                if let inner = v as? [Any] { for case let e as [String: Any] in inner { eps.append(e) } }
                else if let e = v as? [String: Any] { eps.append(e) }
            }
        }
        for e in eps {
            guard let id = str(e["id"]) else { continue }
            let ei = e["info"] as? [String: Any] ?? [:]
            var it = Item(kind: .episode, streamId: id, name: clean(e["title"]))
            it.ext = str(e["container_extension"])
            it.season = Int(str(e["season"]) ?? "")
            it.episode = Int(str(e["episode_num"]) ?? "")
            it.icon = str(ei["movie_image"])
            it.plot = str(ei["plot"])
            it.duration = str(ei["duration"])
            it.seriesId = s.streamId
            it.seriesName = si.name ?? s.name
            it.cover = si.cover ?? s.icon
            si.seasons[it.season ?? 0, default: []].append(it)
        }
        for k in Array(si.seasons.keys) { si.seasons[k]?.sort { ($0.episode ?? 0) < ($1.episode ?? 0) } }
        return si
    }

    func vodInfo(_ m: Item) async throws -> VodInfo {
        let d = try await get(apiURL("get_vod_info", "&vod_id=" + enc(m.streamId)))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let i = o["info"] as? [String: Any] ?? [:]
        var v = VodInfo()
        v.plot = str(i["plot"]) ?? str(i["description"])
        v.genre = str(i["genre"])
        v.cast = str(i["cast"]) ?? str(i["actors"])
        v.director = str(i["director"])
        v.releaseDate = str(i["releasedate"]) ?? str(i["release_date"])
        v.duration = str(i["duration"])
        v.rating = ratingText(i["rating"])
        v.trailer = str(i["youtube_trailer"])
        v.poster = str(i["movie_image"]) ?? str(i["cover_big"])
        if let b = i["backdrop_path"] as? [Any] { v.backdrop = b.compactMap { str($0) }.first } else { v.backdrop = str(i["backdrop_path"]) }
        return v
    }

    // MARK: guide

    func epg(_ streamId: String, limit: Int) async -> [Programme] {
        guard let d = try? await get(apiURL("get_short_epg", "&stream_id=" + enc(streamId) + "&limit=\(limit)")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let a = o["epg_listings"] as? [Any] else { return [] }
        let now = Date()
        var out: [Programme] = []
        for case let e as [String: Any] in a {
            guard let s = Double(str(e["start_timestamp"]) ?? ""), let t = Double(str(e["stop_timestamp"]) ?? "") else { continue }
            let stop = Date(timeIntervalSince1970: t)
            if stop < now { continue }
            out.append(Programme(title: b64(str(e["title"]) ?? ""), desc: b64(str(e["description"]) ?? ""),
                                 start: Date(timeIntervalSince1970: s), stop: stop))
        }
        return XtreamAPI.tidy(out)
    }

    /// Drops duplicates and overlaps some providers send.
    static func tidy(_ input: [Programme]) -> [Programme] {
        let l = input.filter { $0.stop > $0.start }.sorted { a, b in a.start != b.start ? a.start < b.start : a.stop > b.stop }
        var out: [Programme] = []
        var end = Date.distantPast
        for var p in l {
            if p.stop <= end { continue }
            if p.start < end { p.start = end }
            out.append(p)
            end = p.stop
        }
        return out
    }

    // MARK: playback

    func playURL(_ it: Item, liveFormat: String) -> URL? {
        let u = enc(user), p = enc(pass)
        switch it.kind {
        case .live: return URL(string: "\(base)/live/\(u)/\(p)/\(it.streamId).\(liveFormat)")
        case .movie: return URL(string: "\(base)/movie/\(u)/\(p)/\(it.streamId).\(it.ext ?? "mp4")")
        case .episode: return URL(string: "\(base)/series/\(u)/\(p)/\(it.streamId).\(it.ext ?? "mp4")")
        case .series: return nil
        }
    }
}

enum Storage {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YM Player", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var caches: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.ymplayer.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func readCache(_ key: String) -> (Data, Date)? {
        let u = caches.appendingPathComponent(key)
        guard let d = try? Data(contentsOf: u),
              let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let m = a[.modificationDate] as? Date else { return nil }
        return (d, m)
    }

    static func writeCache(_ key: String, _ d: Data) {
        try? d.write(to: caches.appendingPathComponent(key), options: .atomic)
    }
}
