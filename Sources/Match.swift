import Foundation

enum Fold {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB")).lowercased()
    }

    /// Letters and digits only: "UK: Spider-Man" → "ukspiderman".
    static func squash(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in fold(s).unicodeScalars where CharacterSet.alphanumerics.contains(u) { out.append(u) }
        return String(out)
    }

    static func words(_ s: String) -> [String] {
        fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}

/// An item prepared for searching.
struct Indexed {
    let item: Item
    let compact: String
    let words: [String]

    init(_ i: Item) {
        item = i
        compact = Fold.squash(i.name)
        words = Fold.words(i.name)
    }
}

/// Search ranking, best first: exact name > starts with it > your words together and in order >
/// all your words at the start of words > contained somewhere. Provider tags ("UK:", "4K |")
/// are ignored and shorter names win ties.
enum Match {
    struct Query {
        let whole: String
        let words: [String]
        var usable: Bool { whole.count >= 2 }

        init(_ text: String) {
            words = Fold.words(text)
            whole = words.joined()
        }
    }

    static let tags: Set<String> = ["uk", "us", "usa", "ca", "au", "ie", "en", "fr", "de", "es", "it", "nl", "pl", "pt", "tr",
                                    "ar", "in", "4k", "8k", "hd", "fhd", "uhd", "sd", "vip", "eu", "nz", "za"]

    static func score(_ x: Indexed, _ q: Query) -> Int {
        guard q.usable else { return 0 }
        let c = x.compact
        for w in q.words where !c.contains(w) { return 0 }
        let t = x.words
        let start = tagLength(t)
        let core = t[start...].joined(), full = t.joined()
        if core == q.whole || full == q.whole { return 1000 }
        if core.hasPrefix(q.whole) || full.hasPrefix(q.whole) { return 900 }
        var phrase = phraseAt(t, start, q.words)
        if phrase < 0 && start > 0 { phrase = phraseAt(t, 0, q.words) }
        if phrase >= 0 { return 800 - min(phrase, 50) }
        if q.words.allSatisfy({ w in t.contains { $0.hasPrefix(w) } }) { return 600 }
        if c.contains(q.whole) { return 400 }
        return 200
    }

    static func rank(_ all: [Indexed], _ text: String, max: Int) -> [Item] {
        let q = Query(text)
        guard q.usable else { return [] }
        var hits: [(Int, Indexed)] = []
        for x in all {
            let s = score(x, q)
            if s > 0 { hits.append((s, x)) }
        }
        hits.sort { a, b in a.0 != b.0 ? a.0 > b.0 : a.1.compact.count < b.1.compact.count }
        return hits.prefix(max).map { $0.1.item }
    }

    static func tagLength(_ t: [String]) -> Int {
        var i = 0
        while i < t.count - 1 && i < 2 && t[i].count <= 3 && tags.contains(t[i]) { i += 1 }
        return i
    }

    static func phraseAt(_ t: [String], _ from: Int, _ q: [String]) -> Int {
        guard !q.isEmpty, from <= t.count else { return -1 }
        var i = from
        while i + q.count <= t.count {
            var ok = true
            for k in 0..<q.count {
                let last = k == q.count - 1
                if last ? !t[i + k].hasPrefix(q[k]) : t[i + k] != q[k] { ok = false; break }
            }
            if ok { return i - from }
            i += 1
        }
        if q.count == 1 { // "spiderman" typed as one word for "Spider-Man"
            for i in from..<t.count {
                var b = ""
                var j = i
                while j < t.count && b.count < q[0].count { b += t[j]; j += 1 }
                if b.hasPrefix(q[0]) { return i - from }
            }
        }
        return -1
    }
}
