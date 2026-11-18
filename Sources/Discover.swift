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

    static func fetch(tmdb: String, season: Int, episode: Int, duration: Double = 0) async -> Segments {
        let what = "TMDB \(tmdb) S\(season)E\(episode)"
        var q = "https://api.theintrodb.org/v4/media?tmdb_id=\(tmdb)&season=\(season)&episode=\(episode)"
        if duration > 60 { q += "&duration_ms=\(Int(duration * 1000))" }
        guard let url = URL(string: q) else { return Segments(status: "Bad address") }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Mozilla/5.0 (YMPlayer)", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r) else { return Segments(status: "Couldn't reach TheIntroDB") }
        let code = (res.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return Segments(status: "Not in TheIntroDB (\(what))") }
        guard code == 200, var o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else {
            return Segments(status: "TheIntroDB answered \(code)")
        }
        if o["intro"] == nil, let inner = o["data"] as? [String: Any] { o = inner }
        var s = Segments()
        if let i = longest(o["intro"]) { s.introStart = i.0; s.introEnd = i.1 }
        if let r = longest(o["recap"]) { s.recapStart = r.0; s.recapEnd = r.1 }
        if let c = longest(o["credits"]), c.0 > 0 { s.creditsStart = c.0 }
        var parts: [String] = []
        if s.hasRecap { parts.append("recap \(clock(s.recapStart))–\(clock(s.recapEnd))") }
        if s.hasIntro { parts.append("intro \(clock(s.introStart))–\(clock(s.introEnd))") }
        if s.creditsStart > 0 { parts.append("credits \(clock(s.creditsStart))") }
        s.status = what + ": " + (parts.isEmpty ? "no times yet" : parts.joined(separator: "  "))
        return s
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
            let end = n("end_ms", "endMs")
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
