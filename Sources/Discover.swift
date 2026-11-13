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

    /// "EN - Breaking Bad (2008) [4K]" → ("Breaking Bad", "2008").
    static func clean(_ raw: String) -> (name: String, year: String?) {
        var n = raw
        var year: String?
        if let r = n.range(of: "[(\\[]((19|20)\\d{2})[)\\]]", options: .regularExpression) {
            year = String(n[r]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
        } else if let r = n.range(of: "\\b(19|20)\\d{2}\\s*$", options: .regularExpression) {
            year = String(n[r]).trimmingCharacters(in: .whitespaces)
        }
        n = n.replacingOccurrences(of: "^\\s*(?:[A-Za-z0-9]{2,4})\\s*[|:\\-]\\s+", with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\s+[-:]?\\s*S\\d{1,2}\\s*E\\d{1,3}.*$", with: "", options: [.regularExpression, .caseInsensitive])
        n = n.replacingOccurrences(of: "\\b(4k|uhd|fhd|hd|sd|multi|sub|dub)\\b.*$", with: "", options: [.regularExpression, .caseInsensitive])
        if let y = year { n = n.replacingOccurrences(of: "\\s*\(y)\\s*$", with: "", options: .regularExpression) }
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (n, year)
    }

    private static var idCache: [String: String] = [:]

    /// The provider's TMDB id if it gave one, else looked up by name (remembered). Nil if not found.
    static func findId(_ kind: Kind, name: String, known: String?) async -> String? {
        if let k = known, Int(k) != nil, k != "0" { return k }
        let c = clean(name)
        guard !c.name.isEmpty else { return nil }
        let ck = "\(kind.rawValue):\(c.name.lowercased()):\(c.year ?? "")"
        if let hit = await MainActor.run(body: { idCache[ck] }) { return hit.isEmpty ? nil : hit }
        let q = c.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c.name
        var path = "/search/\(kind.rawValue)?query=\(q)"
        if let y = c.year { path += (kind == .tv ? "&first_air_date_year=" : "&year=") + y }
        guard var results = (try? await get(path))?["results"] as? [[String: Any]] else { return nil }
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

/// Where an episode's intro and end credits are, from TheIntroDB (theintrodb.org) — a free
/// community database used by Jellyfin, Emby and Kodi — looked up by the series' TMDB id,
/// season and episode. When a show isn't covered there's simply no Skip Intro button.
struct Segments {
    var introStart: Double = -1   // seconds
    var introEnd: Double = -1
    var creditsStart: Double = -1

    var hasIntro: Bool { introEnd > 0 && introEnd > introStart }

    static func fetch(tmdb: String, season: Int, episode: Int) async -> Segments? {
        guard let url = URL(string: "https://api.theintrodb.org/v4/media?tmdb_id=\(tmdb)&season=\(season)&episode=\(episode)") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("YMPlayer/1.0", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              var o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else { return nil }
        if o["intro"] == nil, let inner = o["data"] as? [String: Any] { o = inner }
        var s = Segments()
        if let i = first(o["intro"]) {
            s.introStart = max(0, i.0)
            s.introEnd = i.1
        }
        if let c = first(o["credits"]), c.0 > 0 { s.creditsStart = c.0 }
        return s
    }

    /// First segment as (start, end) in seconds; a missing start means 0, a missing end means -1.
    private static func first(_ v: Any?) -> (Double, Double)? {
        var o: [String: Any]?
        if let a = v as? [Any] { o = a.first as? [String: Any] } else { o = v as? [String: Any] }
        guard let seg = o else { return nil }
        let start = (seg["start_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? -1
        let end = (seg["end_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? -1
        if start <= 0 && end <= 0 { return nil } // {0,0}: confirmed there isn't one
        return (start, end)
    }
}

struct RecRow: Identifiable {
    let title: String
    let items: [Item]
    var id: String { title }
}
