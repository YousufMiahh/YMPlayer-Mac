import Foundation
import CryptoKit
import CommonCrypto

/// Cross-device sync: the part every YM Player app shares (the Fire TV, phone and Samsung apps do
/// exactly the same; the Samsung app's sync-core.js documents the format and has the tests).
///
/// The online copy of an account's watch data is one encrypted blob in a row whose id is a one-way
/// hash of the login. The key that opens it is made from the login too and never leaves the Mac.
///
///   material = "ymplayer-sync-v1\n" + server + "\n" + user + "\n" + pass   (server normalised)
///   64 bytes = PBKDF2-HMAC-SHA256(material, "ymplayer-sync-v1", 10000 rounds)
///   row id = hex of the first 32 bytes; AES-256-GCM key = the last 32
///   blob = base64(12-byte nonce + ciphertext + 16-byte tag)
///
/// The document is maps of entries stamped with when they last changed ("t", ms); merging keeps the
/// newest per key; a removal is kept a while as {x:1, t}.
/// Self-contained on purpose: CI runs it with Tools/synccheck.swift.
enum SyncCore {
    typealias J = [String: Any]

    static let maps = ["pos", "up", "watched", "fav", "favcat", "hidecat", "showcat", "hidetag", "recblock",
                       "catname", "queue", "pic", "adelay", "settings"]
    static let tombstoneMs: Int64 = 60 * 86_400_000
    static let histKeep = 60, histShow = 40, rounds: UInt32 = 10000
    /// Every app keeps at least this many of each history (the Mac keeps 30 channels).
    static let histSure = 30

    // MARK: keys and encryption

    static func normServer(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("https://") { v.removeFirst(8) } else if v.hasPrefix("http://") { v.removeFirst(7) }
        while v.hasSuffix("/") { v.removeLast() }
        if v.hasSuffix(":80") { v.removeLast(3) } else if v.hasSuffix(":443") { v.removeLast(4) }
        return v
    }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    /// (id hex, key). Slow on purpose: callers keep the result.
    static func deriveKeys(server: String, user: String, pass: String) -> (id: String, key: Data) {
        let material = "ymplayer-sync-v1\n" + normServer(server) + "\n" + user.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n" + pass.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = Array(material.utf8), salt = Array("ymplayer-sync-v1".utf8)
        var dk = [UInt8](repeating: 0, count: 64)
        _ = pw.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { cp in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), cp, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &dk, 64)
            }
        }
        return (hex(dk[0..<32]), Data(dk[32..<64]))
    }

    static func encrypt(key: Data, json: Data, nonce: Data? = nil) throws -> String {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(json, using: SymmetricKey(data: key), nonce: n)
        guard let all = box.combined else { throw CocoaError(.coderInvalidValue) }
        return all.base64EncodedString()
    }

    /// The JSON bytes, or throws if the blob wasn't made with this key.
    static func decrypt(key: Data, blob: String) throws -> Data {
        guard let all = Data(base64Encoded: blob) else { throw CocoaError(.coderReadCorrupt) }
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: all), using: SymmetricKey(data: key))
    }

    static func sha256Hex(_ s: String) -> String { hex(SHA256.hash(data: Data(s.utf8))) }

    // MARK: the document

    static func num(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) ?? 0 }
        return 0
    }

    static func emptyDoc() -> J {
        var d: J = ["v": 1, "histclear": ["live": 0, "vod": 0] as J, "hist": J()]
        for m in maps { d[m] = J() }
        return d
    }

    static func normDoc(_ d: J?) -> J {
        var out = emptyDoc()
        guard let d = d else { return out }
        for m in maps + ["hist"] {
            guard let src = d[m] as? J else { continue }
            var dst = J()
            for (k, v) in src { if let e = v as? J { dst[k] = e } }
            out[m] = dst
        }
        if let hc = d["histclear"] as? J { out["histclear"] = ["live": num(hc["live"]), "vod": num(hc["vod"])] as J }
        return out
    }

    private static func histKind(_ k: String) -> String { k.hasPrefix("live:") ? "live" : "vod" }
    private static func strip(_ e: J) -> J { var o = e; o["t"] = nil; o["x"] = nil; return o }
    private static func ordered(_ m: String) -> Bool { m == "fav" || m == "queue" }

    private static func same(_ m: String, _ a: J, _ b: J) -> Bool {
        switch m {
        case "pos": return num(a["p"]) == num(b["p"])
        case "catname": return (a["n"] as? String ?? "") == (b["n"] as? String ?? "")
        case "pic": return num(a["m"]) == num(b["m"])
        case "adelay": return num(a["ms"]) == num(b["ms"])
        case "settings": return canon(a["v"]) == canon(b["v"])
        default: return true
        }
    }

    private static func map(_ d: J, _ m: String) -> J { d[m] as? J ?? J() }

    /// A setting's value as text, so true from JSON and a Swift Bool compare equal (and 1 ≠ true).
    static func canon(_ v: Any?) -> String {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let s = v as? String { return "\"" + s + "\"" }
        return "null"
    }

    /// This device's data as a document: unchanged since the last sync keeps its time, changed gets
    /// now, gone becomes a removal. `maps`: the maps this app keeps (others pass through).
    static func stamp(_ state: J, shadow shadowIn: J?, now: Int64, maps keep: [String]) -> J {
        let shadow = normDoc(shadowIn)
        var out = shadow
        for m in keep {
            let cur = map(state, m), old = map(shadow, m)
            var res = J()
            var next: Int64 = 0
            let order = cur.keys.sorted { num((cur[$0] as? J)?["o"]) < num((cur[$1] as? J)?["o"]) }
            for k in order {
                let e = cur[k] as? J ?? J()
                if let s = old[k] as? J, s["x"] == nil, same(m, s, e) { res[k] = s; continue }
                var n = strip(e)
                n["t"] = now
                if ordered(m) { n["o"] = now + next; next += 1 }
                res[k] = n
            }
            for (k, v) in old where res[k] == nil {
                let s = v as? J ?? J()
                res[k] = s["x"] != nil || m == "settings" ? s : (["x": 1, "t": now] as J) // settings: one this app doesn't have
            }
            out[m] = res
        }
        guard let sh = state["hist"] as? J else { return out }
        let oldHist = map(shadow, "hist")
        var hist = oldHist
        var clear = shadow["histclear"] as? J ?? J()
        for kind in ["live", "vod"] {
            let mine = sh.keys.filter { histKind($0) == kind }
                .sorted { num((sh[$0] as? J)?["o"]) > num((sh[$1] as? J)?["o"]) }
            var prev: Int64? = nil
            for k in mine {
                var e: J
                if let s = oldHist[k] as? J, s["x"] == nil, prev == nil || num(s["t"]) > prev! { e = s } else {
                    let o = num((sh[k] as? J)?["o"])
                    let t = prev == nil ? now - o : max(prev! + 1, now - o)
                    e = ["t": t]
                    e["i"] = (sh[k] as? J)?["i"]
                }
                hist[k] = e
                prev = num(e["t"])
            }
            // gone from this list while plenty newer stayed? Pushed off its end. Otherwise: taken off by hand
            if !mine.isEmpty {
                let kept = mine.map { num((hist[$0] as? J)?["t"]) }
                for (k, v) in oldHist {
                    let s = v as? J ?? J()
                    if histKind(k) != kind || s["x"] != nil || sh[k] != nil || num(s["t"]) <= num(clear[kind]) { continue }
                    if kept.filter({ $0 > num(s["t"]) }).count < histSure { hist[k] = ["x": 1, "t": now] as J }
                }
            }
            if mine.isEmpty {
                let had = oldHist.contains { k, v in
                    let s = v as? J ?? J()
                    return histKind(k) == kind && s["x"] == nil && num(s["t"]) > num(clear[kind])
                }
                if had { clear[kind] = now }
            }
        }
        out["hist"] = hist
        out["histclear"] = clear
        return out
    }

    private static func string(_ e: J) -> String {
        (try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func newer(_ a: J, _ b: J) -> Bool {
        let ta = num(a["t"]), tb = num(b["t"])
        return ta != tb ? ta > tb : string(a) > string(b)
    }

    /// (merged, dirty): dirty = the result differs from `remote` (save it online).
    static func merge(_ localIn: J, _ remoteIn: J, now: Int64) -> (doc: J, dirty: Bool) {
        let local = normDoc(localIn), remote = normDoc(remoteIn)
        var out = emptyDoc()
        var dirty = false
        for m in maps + ["hist"] {
            let a = map(local, m), b = map(remote, m)
            var r = J()
            for k in Set(a.keys).union(b.keys) {
                let ea = a[k] as? J, eb = b[k] as? J
                guard let rb = eb else { r[k] = ea; dirty = true; continue }
                guard let ra = ea else { r[k] = rb; continue }
                if num(ra["t"]) != num(rb["t"]) && newer(ra, rb) { r[k] = ra; dirty = true } else { r[k] = rb }
            }
            out[m] = r
        }
        var hc = J()
        let lc = local["histclear"] as? J ?? J(), rc = remote["histclear"] as? J ?? J()
        for kind in ["live", "vod"] {
            let v = max(num(lc[kind]), num(rc[kind]))
            hc[kind] = v
            if v != num(rc[kind]) { dirty = true }
        }
        out["histclear"] = hc
        for m in maps {
            var mm = map(out, m)
            let rm = map(remote, m)
            for (k, v) in mm {
                let e = v as? J ?? J()
                if e["x"] != nil && num(e["t"]) < now - tombstoneMs { mm[k] = nil; if rm[k] != nil { dirty = true } }
            }
            out[m] = mm
        }
        var h = map(out, "hist")
        let rh = map(remote, "hist")
        for kind in ["live", "vod"] {
            let ks = h.keys.filter { histKind($0) == kind && (h[$0] as? J)?["x"] == nil }
                .sorted { num((h[$0] as? J)?["t"]) > num((h[$1] as? J)?["t"]) }
            for (idx, k) in ks.enumerated() {
                let e = h[k] as? J ?? J()
                if num(e["t"]) <= num(hc[kind]) || idx >= histKeep { h[k] = nil; if rh[k] != nil { dirty = true } }
            }
            for (k, v) in h { // removals: kept a while so they spread, then dropped
                let e = v as? J ?? J()
                if histKind(k) == kind, e["x"] != nil, num(e["t"]) < now - tombstoneMs || num(e["t"]) <= num(hc[kind]) {
                    h[k] = nil; if rh[k] != nil { dirty = true }
                }
            }
        }
        out["hist"] = h
        return (out, dirty)
    }

    /// What the device should hold: maps without times (fav / queue / hist o = 0, 1, 2…).
    static func toState(_ docIn: J) -> J {
        let doc = normDoc(docIn)
        var st = J()
        for m in maps {
            let src = map(doc, m)
            var ks = src.keys.filter { (src[$0] as? J)?["x"] == nil }
            if ordered(m) { ks.sort { num((src[$0] as? J)?["o"]) < num((src[$1] as? J)?["o"]) } }
            var r = J()
            for (i, k) in ks.enumerated() {
                var e = strip(src[k] as? J ?? J())
                if ordered(m) { e["o"] = Int64(i) }
                r[k] = e
            }
            st[m] = r
        }
        var hist = J()
        let h = map(doc, "hist"), hc = doc["histclear"] as? J ?? J()
        for kind in ["live", "vod"] {
            let ks = h.keys.filter { k in
                let e = h[k] as? J ?? J()
                return histKind(k) == kind && e["x"] == nil && num(e["t"]) > num(hc[kind])
            }.sorted { num((h[$0] as? J)?["t"]) > num((h[$1] as? J)?["t"]) }
            for (i, k) in ks.prefix(histShow).enumerated() {
                var e: J = ["o": Int64(i)]
                e["i"] = (h[k] as? J)?["i"]
                hist[k] = e
            }
        }
        st["hist"] = hist
        return st
    }

    /// Same contents for map m (order counts for fav / queue / hist; duration for pos).
    static func sameMap(_ m: String, _ a: J?, _ b: J?) -> Bool {
        let a = a ?? J(), b = b ?? J()
        guard a.count == b.count else { return false }
        for (k, v) in a {
            guard let ea = v as? J, let eb = b[k] as? J else { return false }
            if !same(m, ea, eb) { return false }
            if (ordered(m) || m == "hist") && num(ea["o"]) != num(eb["o"]) { return false }
            if m == "pos" && num(ea["d"]) != num(eb["d"]) { return false }
        }
        return true
    }
}
