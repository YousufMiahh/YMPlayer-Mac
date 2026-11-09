import Foundation

struct Top10Data: Codable {
    var week = ""
    var films: [String] = []
    var tv: [String] = []
    var checked = Date.distantPast
    var etag: String?
    var lastModified: String?
}

/// Netflix's official weekly UK Top 10 (films and TV), matched against your provider's library.
/// Netflix publishes it on Tuesdays; it's only downloaded again once a new week is due.
enum Top10 {
    static let url = URL(string: "https://www.netflix.com/tudum/top10/data/all-weeks-countries.tsv")!
    static var file: URL { Storage.support.appendingPathComponent("top10.json") }

    static func load() -> Top10Data? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Top10Data.self, from: d)
    }

    static func save(_ t: Top10Data) {
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: file, options: .atomic) }
    }

    static func due(_ d: Top10Data?) -> Bool {
        guard let d = d else { return true }
        let now = Date()
        if now.timeIntervalSince(d.checked) < 3600 { return false }
        if d.week.isEmpty { return true }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let w = f.date(from: d.week) else { return true }
        return now >= w.addingTimeInterval(9 * 86400) // Sunday the week ends + 9 days = the Tuesday after next
    }

    static func refresh() async -> Top10Data? {
        let old = load()
        if !due(old) { return old }
        do {
            var r = URLRequest(url: url, timeoutInterval: 120)
            r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                       forHTTPHeaderField: "User-Agent")
            if let e = old?.etag { r.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let l = old?.lastModified { r.setValue(l, forHTTPHeaderField: "If-Modified-Since") }
            let (d, resp) = try await URLSession.shared.data(for: r)
            let h = resp as? HTTPURLResponse
            if h?.statusCode == 304, var o = old {
                o.checked = Date()
                save(o)
                return o
            }
            if (h?.statusCode ?? 0) >= 400 { throw URLError(.badServerResponse) }
            var t = await Task.detached(priority: .utility) { Top10.parse(d) }.value
            if t.week.isEmpty, var o = old {
                o.checked = Date()
                save(o)
                return o
            }
            t.etag = h?.value(forHTTPHeaderField: "ETag")
            t.lastModified = h?.value(forHTTPHeaderField: "Last-Modified")
            t.checked = Date()
            save(t)
            return t
        } catch {
            if var o = old {
                o.checked = Date().addingTimeInterval(-3600 + 600) // try again in ~10 minutes
                save(o)
                return o
            }
            return nil
        }
    }

    static func parse(_ d: Data) -> Top10Data {
        guard let s = String(data: d, encoding: .utf8) else { return Top10Data() }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first else { return Top10Data() }
        let h = header.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let iWeek = h.firstIndex(of: "week"), let iCat = h.firstIndex(of: "category"),
              let iRank = h.firstIndex(of: "weekly_rank"), let iTitle = h.firstIndex(of: "show_title") else { return Top10Data() }
        let iIso = h.firstIndex(of: "country_iso2"), iCountry = h.firstIndex(of: "country_name")
        if iIso == nil && iCountry == nil { return Top10Data() }
        var best = ""
        var films: [Int: String] = [:], tv: [Int: String] = [:]
        for line in lines.dropFirst() {
            if iIso != nil {
                if !line.contains("\tGB\t") && !line.hasPrefix("GB\t") { continue }
            } else if !line.contains("United Kingdom") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard f.count > max(iWeek, iCat, iRank, iTitle) else { continue }
            if let i = iIso, i < f.count {
                if f[i].uppercased() != "GB" { continue }
            } else if let i = iCountry, i < f.count, f[i] != "United Kingdom" { continue }
            let week = f[iWeek]
            if week < best { continue }
            if week > best {
                best = week
                films = [:]
                tv = [:]
            }
            guard let rank = Int(f[iRank]) else { continue }
            if f[iCat].lowercased().hasPrefix("film") { films[rank] = f[iTitle] } else { tv[rank] = f[iTitle] }
        }
        var t = Top10Data()
        t.week = best
        t.films = films.keys.sorted().compactMap { films[$0] }
        t.tv = tv.keys.sorted().compactMap { tv[$0] }
        return t
    }

    static func key(_ name: String) -> String {
        var n = name
        n = n.replacingOccurrences(of: "^\\s*(?:[A-Za-z0-9]{2,4})\\s*[|:\\-]\\s+", with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "[:\\-]\\s*(?:season|series|limited series)\\b.*$", with: "", options: [.regularExpression, .caseInsensitive])
        return Fold.squash(n)
    }

    /// Finds each title in the library (ignoring "EN - ", "(2022)" and so on), keeping Netflix's order.
    static func match(_ titles: [String], _ library: [Item]) -> [Item] {
        var wanted: [String: Int] = [:]
        for (i, t) in titles.enumerated() {
            let k = key(t)
            if !k.isEmpty && wanted[k] == nil { wanted[k] = i }
        }
        if wanted.isEmpty { return [] }
        let keys = Array(wanted.keys)
        var found = [Item?](repeating: nil, count: titles.count)
        for it in library {
            let c = Fold.squash(it.name)
            if !keys.contains(where: { c.contains($0) }) { continue }
            guard let i = wanted[key(it.name)] else { continue }
            if let f = found[i], f.added >= it.added { continue }
            found[i] = it
        }
        return found.compactMap { $0 }
    }
}
