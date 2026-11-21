import Foundation

/// The Movie Database (themoviedb.org): finds a title's TMDB id from its name and fetches
/// recommendations. Used for Skip Intro (the intro database is keyed by TMDB id) and for
/// "Because you watched…" on Home.
enum Tmdb {
    static let key = "ec34788e4bc515bbf0c395f7f3441b78"
    static let base = "https://api.themoviedb.org/3"

    enum Kind: String { case movie, tv }

    private static func get(_ path: String) async throws -> [String: Any] {
        let sep = path.contains("?") ? "&" : "?"
        guard let url = URL(string: base + path + sep + "api_key=" + key + "&language=en-GB") else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("YMPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    private static var imdbCache: [String: String] = [:]

    /// A series' IMDb id ("tt0903747") from its TMDB id, for the skip-intro databases that use it.
    @MainActor static func imdbId(_ tvId: String) async -> String? {
        if let v = imdbCache[tvId] { return v.isEmpty ? nil : v }
        guard let o = try? await get("/tv/\(tvId)/external_ids") else { return nil }
        let v = (o["imdb_id"] as? String) ?? ""
        imdbCache[tvId] = v.hasPrefix("tt") ? v : ""
        return v.hasPrefix("tt") ? v : nil
    }

    /// "EN - Breaking Bad (2008) [4K]" → ("Breaking Bad", "2008"). Only a provider's tag comes off the
    /// front ("EN - ", "UK: ", "NF | "), never part of a title ("CSI: Miami", "24: Legacy"); a title
    /// that is a year ("1917") stays. `full` keeps an unbracketed trailing number ("Blade Runner 2049").
    static func clean(_ raw: String) -> (name: String, year: String?, full: String) {
        var n = raw.trimmingCharacters(in: .whitespaces)
        n = n.replacingOccurrences(of: "^[^|]{1,8}\\|\\s*", with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "^(?:[A-Z]{2}|(?i:ENG|AMZ|DSNP|ATVP|VOD|MULTI|4K|UHD|FHD|HD))\\s*[:\\-]\\s+", with: "", options: .regularExpression)
        var year: String?
        if let r = n.range(of: "[(\\[]((19|20)\\d{2})[)\\]]", options: .regularExpression) {
            year = String(n[r]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
        } else if let r = n.range(of: "\\S\\s+(19|20)\\d{2}\\s*$", options: .regularExpression) {
            year = String(String(n[r]).dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        n = n.replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\s+[-:]?\\s*S\\d{1,2}\\s*E\\d{1,3}\\b.*$", with: "", options: [.regularExpression, .caseInsensitive])
        n = n.replacingOccurrences(of: "\\s+(?:4K|UHD|FHD|HD|SD|MULTI|SUB|DUB|HEVC|H265)\\b.*$", with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let full = n
        if let y = year { n = n.replacingOccurrences(of: "\\s*\(y)\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        if n.isEmpty { n = full.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : full; year = nil }
        return (n, year, full)
    }

    /// Safe in a query value: "Fast & Furious" must not split the URL.
    static let queryAllowed: CharacterSet = { var c = CharacterSet.urlQueryAllowed; c.remove(charactersIn: "&+=?#"); return c }()

    private static var idCache: [String: String] = [:]

    /// The provider's TMDB id if it gave one, else looked up by name (remembered). Nil if not found.
    static func findId(_ kind: Kind, name: String, known: String?) async -> String? {
        if let k = known, Int(k) != nil, k != "0" { return k }
        let c = clean(name)
        guard !c.name.isEmpty else { return nil }
        let ck = "\(kind.rawValue):\(c.name.lowercased()):\(c.year ?? "")"
        if let hit = await MainActor.run(body: { idCache[ck] }) { return hit.isEmpty ? nil : hit }
        let q = c.name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? c.name
        var path = "/search/\(kind.rawValue)?query=\(q)"
        if let y = c.year { path += (kind == .tv ? "&first_air_date_year=" : "&year=") + y }
        guard var results = (try? await get(path))?["results"] as? [[String: Any]] else { return nil }
        if results.isEmpty, c.year != nil, c.full != c.name { // the number is part of the title ("Blade Runner 2049")
            let fq = c.full.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? c.full
            results = ((try? await get("/search/\(kind.rawValue)?query=\(fq)"))?["results"] as? [[String: Any]]) ?? []
        }
        if results.isEmpty, c.year != nil {
            results = ((try? await get("/search/\(kind.rawValue)?query=\(q)"))?["results"] as? [[String: Any]]) ?? []
        }
        let id = results.first.flatMap { str($0["id"]) }
        await MainActor.run { idCache[ck] = id ?? "" }
        return id
    }

    /// The title's logo (the artwork Netflix and Apple TV show instead of the name): English first,
    /// then one without words; remembered per title (in memory and between launches).
    static func logo(_ kind: Kind, id: String) async -> URL? { await art(kind, id: id).logo }

    /// The logo as above, and a wide picture without words (or an English one) for a card that
    /// widens on Home. One request, remembered between launches.
    static func art(_ kind: Kind, id: String) async -> (logo: URL?, backdrop: URL?) {
        let lk = "tmdbLogo.\(kind.rawValue).\(id)", bk = "tmdbBackdrop.\(kind.rawValue).\(id)"
        let d = UserDefaults.standard
        if let l = d.string(forKey: lk), let b = d.string(forKey: bk) {
            return (l.isEmpty ? nil : URL(string: l), b.isEmpty ? nil : URL(string: b))
        }
        guard let o = try? await get("/\(kind.rawValue)/\(id)/images?include_image_language=en,null") else { return (nil, nil) }
        let l = pickLogo(o["logos"] as? [[String: Any]] ?? [])
        let b = pickBackdrop(o["backdrops"] as? [[String: Any]] ?? [])
        d.set(l ?? "", forKey: lk)
        d.set(b ?? "", forKey: bk)
        return (l.flatMap { URL(string: $0) }, b.flatMap { URL(string: $0) })
    }

    /// A backdrop without words first (the logo goes on top), then an English one; most liked.
    static func pickBackdrop(_ list: [[String: Any]]) -> String? {
        func rank(_ b: [String: Any]) -> Int {
            let lang = b["iso_639_1"] as? String ?? ""
            return lang.isEmpty ? 0 : lang == "en" ? 1 : 9
        }
        var best: [String: Any]? = nil
        for b in list where (b["file_path"] as? String ?? "") != "" && rank(b) < 9 {
            guard let cur = best else { best = b; continue }
            let v = (b["vote_average"] as? NSNumber)?.doubleValue ?? 0, cv = (cur["vote_average"] as? NSNumber)?.doubleValue ?? 0
            if rank(b) < rank(cur) || (rank(b) == rank(cur) && v > cv) { best = b }
        }
        return (best?["file_path"] as? String).map { "https://image.tmdb.org/t/p/w780" + $0 }
    }

    static func pickLogo(_ logos: [[String: Any]]) -> String? {
        func rank(_ l: [String: Any]) -> Int {
            let lang = l["iso_639_1"] as? String ?? ""
            return lang == "en" ? 0 : lang.isEmpty ? 1 : 9
        }
        var best: [String: Any]? = nil
        for l in logos where (l["file_path"] as? String ?? "") != "" && rank(l) < 9 {
            guard let b = best else { best = l; continue }
            let v = (l["vote_average"] as? NSNumber)?.doubleValue ?? 0, bv = (b["vote_average"] as? NSNumber)?.doubleValue ?? 0
            if rank(l) < rank(b) || (rank(l) == rank(b) && v > bv) { best = l }
        }
        guard var path = best?["file_path"] as? String else { return nil }
        if path.lowercased().hasSuffix(".svg") { path = String(path.dropLast(4)) + ".png" }
        return "https://image.tmdb.org/t/p/w500" + path
    }

    /// Titles TMDB recommends to people who liked this (English and original titles).
    static func recommendations(_ kind: Kind, id: String) async -> [String] {
        var out: [String] = []
        for page in 1...2 {
            guard let r = (try? await get("/\(kind.rawValue)/\(id)/recommendations?page=\(page)"))?["results"] as? [[String: Any]] else { break }
            for o in r {
                let t = str(o[kind == .tv ? "name" : "title"]) ?? ""
                let ot = str(o[kind == .tv ? "original_name" : "original_title"]) ?? ""
                if !t.isEmpty { out.append(t) }
                if !ot.isEmpty && ot != t { out.append(ot) }
            }
        }
        return out
    }
}

/// Where an episode's recap, intro and end credits are, from TheIntroDB (theintrodb.org), a free
/// community database used by Jellyfin, Emby and Kodi, looked up by the series' TMDB id, season and
/// episode (and its length, so it picks the right cut). When a show isn't covered there's simply
/// no Skip button.
struct Segments {
    var introStart: Double = -1   // seconds
    var introEnd: Double = -1
    var recapStart: Double = -1
    var recapEnd: Double = -1
    var creditsStart: Double = -1
    /// What happened, shown in the player's menu so a missing button can be explained.
    var status = ""

    var hasIntro: Bool { introEnd > 0 && introEnd > introStart }
    var hasRecap: Bool { recapEnd > 0 && recapEnd > recapStart }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    /// TheIntroDB first (this cut, then the episode as a whole); with no intro or recap there,
    /// SkipDB (skipdb.tv) and then IntroDB (introdb.app), which go by the IMDb id.
    static func fetch(tmdb: String, season: Int, episode: Int, duration: Double = 0) async -> Segments {
        let what = "TMDB \(tmdb) S\(season)E\(episode)"
        let base = "https://api.theintrodb.org/v4/media?tmdb_id=\(tmdb)&season=\(season)&episode=\(episode)"
        var s = Segments()
        var source = "TheIntroDB"
        var inTidb = true
        let first = await json(base + (duration > 60 ? "&duration_ms=\(Int(duration * 1000))" : ""))
        if first.code == 404 {
            inTidb = false
        } else if let o = first.body {
            s = parse(o)
        } else {
            return Segments(status: first.code == 0 ? "Couldn't reach TheIntroDB" : "TheIntroDB answered \(first.code)")
        }
        // Nothing for the intro or recap in this cut (the episode's length picks one): the intro is
        // usually at the same place in every cut, so take it from the episode as a whole
        if inTidb && !s.hasIntro && !s.hasRecap && duration > 60, let o = await json(base).body {
            if take(&s, parse(o)) { source = "TheIntroDB, another cut" }
        }
        // Still nothing: the other free databases, which go by the IMDb id
        if !s.hasIntro && !s.hasRecap, let imdb = await Tmdb.imdbId(tmdb) {
            let q = "?imdb_id=\(imdb)&season=\(season)&episode=\(episode)"
            if let o = await json("https://api.skipdb.tv/api/segments" + q + (duration > 60 ? "&duration=\(Int(duration))" : "")).body,
               take(&s, parse((o["segments"] as? [String: Any]) ?? o)) {
                source = "SkipDB"
            }
            if !s.hasIntro && !s.hasRecap, let o = await json("https://api.introdb.app/segments" + q).body,
               take(&s, parse((o["segments"] as? [String: Any]) ?? o)) {
                source = "IntroDB"
            }
        }
        var parts: [String] = []
        if s.hasRecap { parts.append("recap \(clock(s.recapStart))–\(clock(s.recapEnd))") }
        if s.hasIntro { parts.append("intro \(clock(s.introStart))–\(clock(s.introEnd))") }
        if s.creditsStart > 0 { parts.append("credits \(clock(s.creditsStart))") }
        if s.hasIntro || s.hasRecap { parts.append("(\(source))") }
        else if !parts.isEmpty { parts.append("·  no intro or recap times in TheIntroDB, SkipDB or IntroDB yet") }
        else { parts.append(inTidb ? "no times yet" : "not in TheIntroDB, SkipDB or IntroDB") }
        s.status = what + ": " + parts.joined(separator: "  ")
        return s
    }

    /// GET a JSON object: (HTTP status, body). Status 0 when it couldn't be reached.
    private static func json(_ address: String) async -> (code: Int, body: [String: Any]?) {
        guard let url = URL(string: address) else { return (0, nil) }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Mozilla/5.0 (YMPlayer)", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r) else { return (0, nil) }
        let code = (res.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return (code, nil) }
        return (code, (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any])
    }

    private static func parse(_ body: [String: Any]) -> Segments {
        var o = body
        if o["intro"] == nil, let inner = o["data"] as? [String: Any] { o = inner }
        var s = Segments()
        if let i = longest(o["intro"]) { s.introStart = i.0; s.introEnd = i.1 }
        if let r = longest(o["recap"]) { s.recapStart = r.0; s.recapEnd = r.1 }
        if let c = longest(o["credits"]) ?? longest(o["outro"]), c.0 > 0 { s.creditsStart = c.0 } // SkipDB / IntroDB: outro
        return s
    }

    /// Copies the intro and recap from `from` (and the credits if there were none). True if it had any.
    private static func take(_ to: inout Segments, _ from: Segments) -> Bool {
        guard from.hasIntro || from.hasRecap else {
            if to.creditsStart <= 0 && from.creditsStart > 0 { to.creditsStart = from.creditsStart }
            return false
        }
        to.introStart = from.introStart; to.introEnd = from.introEnd
        to.recapStart = from.recapStart; to.recapEnd = from.recapEnd
        if to.creditsStart <= 0 { to.creditsStart = from.creditsStart }
        return true
    }

    /// The segment as (start, end) in seconds: a missing start is 0, a missing end -1. The longest of several.
    private static func longest(_ v: Any?) -> (Double, Double)? {
        let list: [[String: Any]] = (v as? [[String: Any]]) ?? ((v as? [String: Any]).map { [$0] } ?? [])
        var best: (Double, Double)?
        for seg in list {
            func n(_ a: String, _ b: String) -> Double {
                ((seg[a] as? NSNumber) ?? (seg[b] as? NSNumber)).map { $0.doubleValue / 1000 } ?? -1
            }
            var start = n("start_ms", "startMs")
            var end = n("end_ms", "endMs")
            if start < 0 && end < 0 { // IntroDB gives seconds
                start = ((seg["start_sec"] as? NSNumber) ?? (seg["start"] as? NSNumber))?.doubleValue ?? -1
                end = ((seg["end_sec"] as? NSNumber) ?? (seg["end"] as? NSNumber))?.doubleValue ?? -1
            }
            if start <= 0 && end <= 0 { continue } // {0,0}: confirmed there isn't one
            if start < 0 { start = 0 }
            if let b = best {
                if end > 0, b.1 > 0, end - start > b.1 - b.0 { best = (start, end) }
            } else {
                best = (start, end)
            }
        }
        return best
    }
}

struct RecRow: Identifiable {
    let title: String
    let items: [Item]
    /// What it's based on ("Because you watched X"), so it can be turned off; nil for others.
    var sourceId: String? = nil
    var sourceName: String? = nil
    var id: String { title }
}
