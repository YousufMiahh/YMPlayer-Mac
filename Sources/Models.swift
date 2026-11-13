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
    /// The Movie Database id (of the film, or of the series for episodes) when the provider gives one.
    var tmdb: String? = nil

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
    var tmdb: String?
    var name: String?
    var plot: String?
    var genre: String?
    var cast: String?
    var trailer: String?
    var releaseDate: String?
    var rating: String?
    var cover: String?
    var backdrop: String?
    var seasons: [Int: [Item]] = [:]

    var allEpisodes: [Item] { seasons.keys.sorted().flatMap { seasons[$0] ?? [] } }
}

struct VodInfo {
    var tmdb: String?
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
    var watched: Set<String> = []           // item ids you've finished (or marked)
    var queue: [Item] = []                  // your playback queue, in order
    var catNames: [String: String] = [:]    // "kind:categoryId" → your own name
    var recentVOD: [Item] = []              // films and episodes you've played, newest first
    var picture: [String: Int] = [:]        // picture shape per channel / film / series (see PictureMode)

    init() {}

    // Older saves don't have every field: missing ones start empty
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try c.decodeIfPresent([Item].self, forKey: .favourites) ?? []
        favCategories = try c.decodeIfPresent(Set<String>.self, forKey: .favCategories) ?? []
        hiddenCategories = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenCategories) ?? []
        alwaysShown = try c.decodeIfPresent(Set<String>.self, forKey: .alwaysShown) ?? []
        hiddenTags = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenTags) ?? []
        progress = try c.decodeIfPresent([String: WatchProgress].self, forKey: .progress) ?? [:]
        recentChannels = try c.decodeIfPresent([Item].self, forKey: .recentChannels) ?? []
        watched = try c.decodeIfPresent(Set<String>.self, forKey: .watched) ?? []
        queue = try c.decodeIfPresent([Item].self, forKey: .queue) ?? []
        catNames = try c.decodeIfPresent([String: String].self, forKey: .catNames) ?? [:]
        recentVOD = try c.decodeIfPresent([Item].self, forKey: .recentVOD) ?? []
        picture = try c.decodeIfPresent([String: Int].self, forKey: .picture) ?? [:]
    }
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

/// How the picture fills the screen (the same choices as on the TV and phone).
enum PictureMode: Int, CaseIterable, Identifiable {
    case fit, fill, stretch, wide, classic
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill Screen (Zoom)"
        case .stretch: return "Stretch"
        case .wide: return "16:9"
        case .classic: return "4:3"
        }
    }
}

/// Subtitle look (Settings → Subtitles), the same choices as the TV and phone apps.
enum SubtitleStyle {
    static let sizes = ["Small", "Medium", "Large", "Extra Large"]
    static let relSizes = [20, 17, 14, 11]                 // VLC: smaller number = bigger text
    static let colourNames = ["White", "Yellow", "Cyan", "Green", "Pink", "Orange"]
    static let colours: [UInt32] = [0xFFFFFF, 0xFFE14D, 0x5AE0FF, 0x6BEA7A, 0xFF8AD8, 0xFFA94D]
    static let opacityNames = ["25%", "50%", "75%", "100%"]
    static let opacities = [0x40, 0x80, 0xBF, 0xFF]

    static var size: Int { min(3, max(0, UserDefaults.standard.object(forKey: "subSize") as? Int ?? 1)) }
    static var colour: Int { min(colours.count - 1, max(0, UserDefaults.standard.integer(forKey: "subColour"))) }
    static var background: Bool { UserDefaults.standard.bool(forKey: "subBackground") }
    static var opacity: Int { min(3, max(0, UserDefaults.standard.object(forKey: "subOpacity") as? Int ?? 2)) }

    /// libVLC options for the text renderer.
    static var vlcOptions: [String] {
        var o = ["--freetype-color=\(colours[colour])", "--freetype-rel-fontsize=\(relSizes[size])", "--freetype-bold"]
        if background {
            o += ["--freetype-background-color=0", "--freetype-background-opacity=\(opacities[opacity])", "--freetype-shadow-opacity=0"]
        } else {
            o += ["--freetype-background-opacity=0", "--freetype-shadow-opacity=200"]
        }
        return o
    }
}
