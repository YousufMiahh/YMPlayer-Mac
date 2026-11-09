import Foundation

/// Hiding what you don't watch: categories named "FR | …", "AR: …" are hidden together by
/// switching off FR or AR; names written mostly in another alphabet get a writing-system tag
/// such as "#ARABIC"; single categories can be hidden by hand.
enum Filters {
    static let tagRegex = try! NSRegularExpression(
        pattern: "^[^\\p{L}\\p{N}]*(EX-YU|[A-Za-z]{2,3}|4K|8K)\\s*(?:[|:~\\-–—»▎│\\]⎮/]+|\\s{2,})")

    static func tag(_ name: String) -> String? {
        let s = name.trimmingCharacters(in: .whitespaces)
        let r = NSRange(s.startIndex..., in: s)
        if let m = tagRegex.firstMatch(in: s, range: r), let g = Range(m.range(at: 1), in: s) {
            var t = s[g].uppercased()
            if t == "USA" { t = "US" }
            if t == "GB" { t = "UK" }
            return t
        }
        return script(name)
    }

    /// The writing system most of the name's letters use, if it isn't the Latin alphabet.
    static func script(_ name: String) -> String? {
        var counts: [String: Int] = [:]
        var letters = 0
        for u in name.unicodeScalars where u.properties.isAlphabetic {
            letters += 1
            if let s = scriptOf(u.value) { counts[s, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value * 10 >= letters * 4 else { return nil }
        return best.key
    }

    static func scriptOf(_ v: UInt32) -> String? {
        switch v {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "#ARABIC"
        case 0x0400...0x052F: return "#CYRILLIC"
        case 0x0900...0x097F: return "#DEVANAGARI"
        case 0x0980...0x09FF: return "#BENGALI"
        case 0x0A00...0x0A7F: return "#GURMUKHI"
        case 0x0A80...0x0AFF: return "#GUJARATI"
        case 0x0B80...0x0BFF: return "#TAMIL"
        case 0x0C00...0x0C7F: return "#TELUGU"
        case 0x0C80...0x0CFF: return "#KANNADA"
        case 0x0D00...0x0D7F: return "#MALAYALAM"
        case 0x0D80...0x0DFF: return "#SINHALA"
        case 0x0E00...0x0E7F: return "#THAI"
        case 0x0590...0x05FF: return "#HEBREW"
        case 0x0370...0x03FF: return "#GREEK"
        case 0x0530...0x058F: return "#ARMENIAN"
        case 0x10A0...0x10FF: return "#GEORGIAN"
        case 0x1200...0x137F: return "#ETHIOPIC"
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return "#KOREAN"
        case 0x3040...0x30FF: return "#JAPANESE"
        case 0x4E00...0x9FFF: return "#CHINESE"
        default: return nil
        }
    }

    static let names: [String: String] = {
        let p = ["UK", "United Kingdom", "US", "United States", "CA", "Canada", "IE", "Ireland", "AU", "Australia",
                 "NZ", "New Zealand", "FR", "France", "DE", "Germany", "ES", "Spain", "IT", "Italy", "PT", "Portugal",
                 "NL", "Netherlands", "BE", "Belgium", "PL", "Poland", "TR", "Turkey", "AR", "Arabic", "IN", "India",
                 "PK", "Pakistan", "BD", "Bangladesh", "AF", "Africa", "NG", "Nigeria", "ZA", "South Africa", "GR", "Greece",
                 "RO", "Romania", "AL", "Albania", "EX-YU", "Balkans", "SE", "Sweden", "NO", "Norway", "DK", "Denmark",
                 "FI", "Finland", "RU", "Russia", "UA", "Ukraine", "BR", "Brazil", "MX", "Mexico", "LAT", "Latino",
                 "PH", "Philippines", "CN", "China", "KR", "Korea", "JP", "Japan", "4K", "4K channels", "8K", "8K channels",
                 "EN", "English", "VIP", "VIP", "PPV", "Pay-per-view", "KU", "Kurdish", "IR", "Iran", "IL", "Israel",
                 "CH", "Switzerland", "AT", "Austria", "HU", "Hungary", "CZ", "Czechia", "SK", "Slovakia", "BG", "Bulgaria",
                 "HR", "Croatia", "RS", "Serbia", "BA", "Bosnia", "MK", "North Macedonia", "LT", "Lithuania", "LV", "Latvia",
                 "EE", "Estonia", "CY", "Cyprus", "MT", "Malta", "SA", "Saudi Arabia", "AE", "UAE", "EG", "Egypt",
                 "MA", "Morocco", "DZ", "Algeria", "TN", "Tunisia", "SO", "Somalia", "ET", "Ethiopia", "KE", "Kenya",
                 "GH", "Ghana", "CAR", "Caribbean", "JM", "Jamaica", "TH", "Thailand", "VN", "Vietnam", "ID", "Indonesia",
                 "MY", "Malaysia", "LK", "Sri Lanka", "NP", "Nepal", "AM", "Armenia", "AZ", "Azerbaijan", "GE", "Georgia",
                 "SC", "Scotland", "WAL", "Wales", "IRL", "Ireland", "SP", "Spain", "SW", "Sweden", "LU", "Luxembourg",
                 "ASI", "Asia", "AFR", "Africa", "ARA", "Arabic", "HIN", "Hindi", "URD", "Urdu", "PUN", "Punjabi",
                 "TAM", "Tamil", "BEN", "Bengali", "SOM", "Somali", "KID", "Kids", "XXX", "Adult", "ADU", "Adult",
                 "#ARABIC", "Arabic writing", "#CYRILLIC", "Cyrillic writing (Russian, Ukrainian…)",
                 "#DEVANAGARI", "Hindi writing (Devanagari)", "#BENGALI", "Bengali writing", "#GURMUKHI", "Punjabi writing",
                 "#GUJARATI", "Gujarati writing", "#TAMIL", "Tamil writing", "#TELUGU", "Telugu writing", "#KANNADA", "Kannada writing",
                 "#MALAYALAM", "Malayalam writing", "#SINHALA", "Sinhala writing", "#THAI", "Thai writing", "#HEBREW", "Hebrew writing",
                 "#GREEK", "Greek writing", "#ARMENIAN", "Armenian writing", "#GEORGIAN", "Georgian writing", "#ETHIOPIC", "Amharic writing",
                 "#KOREAN", "Korean writing", "#JAPANESE", "Japanese writing", "#CHINESE", "Chinese writing"]
        var d: [String: String] = [:]
        var i = 0
        while i + 1 < p.count { d[p[i]] = p[i + 1]; i += 2 }
        return d
    }()

    static func tagName(_ t: String) -> String { names[t] ?? t }

    static func key(_ k: Kind, _ c: Category) -> String { k.rawValue + ":" + c.id }

    /// @param own include categories you hid yourself (search leaves those in).
    static func isHidden(_ c: Category, _ k: Kind, _ d: UserData, own: Bool = true) -> Bool {
        let ck = Filters.key(k, c)
        if own && d.hiddenCategories.contains(ck) { return true }
        if d.alwaysShown.contains(ck) { return false }
        if let t = tag(c.name) { return d.hiddenTags.contains(t) }
        return false
    }

    static func hiddenByTag(_ c: Category, _ d: UserData) -> Bool {
        if let t = tag(c.name) { return d.hiddenTags.contains(t) }
        return false
    }
}
