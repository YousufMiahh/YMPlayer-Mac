import Foundation

enum Kind: String, Codable, CaseIterable, Hashable {
    case live, movie, series, episode

    var title: String {
        switch self {
        case .live: return "Live TV"
        case .movie: return "Movies"
        case .series: return "Series"
        case .episode: return "Episodes"
        }
    }

    var plural: String {
        switch self {
        case .live: return "channels"
        case .movie: return "movies"
        case .series: return "series"
        case .episode: return "episodes"
        }
    }
}

struct Category: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

/// A channel, movie, series or episode.
struct Item: Identifiable, Hashable, Codable {
    var kind: Kind
    var streamId: String
    var name: String
    var icon: String? = nil
    var categoryId: String? = nil
    var ext: String? = nil
    var num: String? = nil
    var added: Int64 = 0
    var rating: String? = nil
    var plot: String? = nil
    var genre: String? = nil
    // episodes
    var seriesId: String? = nil
    var seriesName: String? = nil
    var cover: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var duration: String? = nil

    var id: String { kind.rawValue + ":" + streamId }

    static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var iconURL: URL? { Item.url(icon) }

    /// The picture to use on a poster card (the series' poster for episodes).
    var posterURL: URL? { Item.url(kind == .episode ? (cover ?? icon) : icon) }

    var displayTitle: String { kind == .episode ? (seriesName ?? name) : name }

    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        var s = ""
        if let se = season { s += "S\(se)" }
        if let e = episode { s += (s.isEmpty ? "" : " ") + "E\(e)" }
        return s.isEmpty ? nil : s
    }

    static func url(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let u = URL(string: s) { return u }
        return URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }
}

/// A TV guide entry.
struct Programme: Identifiable, Hashable {
    var title: String
    var desc: String
    var start: Date
    var stop: Date

    var id: String { "\(start.timeIntervalSince1970)-\(title)" }
    var isNow: Bool { let n = Date(); return start <= n && n < stop }
    var progress: Double {
        let total = stop.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }
    var timeRange: String { Fmt.hm.string(from: start) + " – " + Fmt.hm.string(from: stop) }
}

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var server: String
    var user: String
    var pass: String

    var label: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? user : name }
}

struct SeriesInfo {
    var name: String?
    var plot: String?
    var genre: String?
    var cast: String?
    var releaseDate: String?
    var rating: String?
    var cover: String?
    var backdrop: String?
    var seasons: [Int: [Item]] = [:]

    var allEpisodes: [Item] { seasons.keys.sorted().flatMap { seasons[$0] ?? [] } }
}

struct VodInfo {
    var plot: String?
    var genre: String?
    var cast: String?
    var director: String?
    var releaseDate: String?
    var duration: String?
    var rating: String?
    var trailer: String?
    var backdrop: String?
    var poster: String?
}

struct WatchProgress: Codable, Hashable {
    var item: Item
    var position: Double
    var duration: Double
    var updated: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

/// Everything remembered per account.
struct UserData: Codable {
    var favourites: [Item] = []
    var favCategories: Set<String> = []     // "kind:categoryId"
    var hiddenCategories: Set<String> = []  // hidden by you
    var alwaysShown: Set<String> = []       // brought back despite a country / language filter
    var hiddenTags: Set<String> = []        // countries, languages, writing systems
    var progress: [String: WatchProgress] = [:]
    var recentChannels: [Item] = []
}

struct PlaySession: Identifiable {
    let id = UUID()
    var item: Item
    var list: [Item]
}

enum Fmt {
    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - JSON helpers (Xtream servers mix strings, numbers and nulls freely)

func str(_ v: Any?) -> String? {
    switch v {
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "null" ? nil : t
    case let n as NSNumber:
        return n.stringValue
    default:
        return nil
    }
}

func clean(_ v: Any?) -> String { str(v) ?? "" }

func ratingText(_ v: Any?) -> String? {
    guard let s = str(v), let d = Double(s), d > 0 else { return nil }
    return String(format: "★ %.1f", d)
}

func b64(_ s: String) -> String {
    guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters), let t = String(data: d, encoding: .utf8) else { return s }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}
