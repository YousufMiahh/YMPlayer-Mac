// CI: SyncCore must give exactly what the other apps give (same test vector as the Samsung app's
// tests and the Android apps). Run as: cat Sources/SyncCore.swift Tools/synccheck.swift > x.swift && swift x.swift

func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); exit(1) }
    print("ok \(what)")
}

let k = SyncCore.deriveKeys(server: "HTTP://Example.com:80/", user: "user1", pass: "p@ss")
check(k.id == "ae08bc466b590e674b630cab58c367667533e7c70fe3619833c3a4f71fa02cc9", "id")
check(SyncCore.hex(k.key) == "3e9ee9fe8e62906119bba43ac6009185ae44e5aa724ef2fce95e5ee9cbff3e89", "key")
let blob = try! SyncCore.encrypt(key: k.key, json: Data("{\"v\":1,\"hello\":\"wörld\"}".utf8), nonce: Data(0..<12))
check(blob == "AAECAwQFBgcICQoLGMrYpSJHJ7+tKuNmtDWAWOqqBLxvlha4GzMJcRt7hXGHawuIPp6PZg==", "blob")
check(String(data: try! SyncCore.decrypt(key: k.key, blob: blob), encoding: .utf8) == "{\"v\":1,\"hello\":\"wörld\"}", "decrypt")

typealias J = SyncCore.J
func st(_ extra: J) -> J { var s = J(); for m in SyncCore.maps { s[m] = J() }; s["hist"] = J(); for (a, b) in extra { s[a] = b }; return s }
let all = SyncCore.maps
let s1 = SyncCore.stamp(st(["watched": ["movie:7": J()] as J]), shadow: nil, now: 1000, maps: all)
check(SyncCore.num(((s1["watched"] as! J)["movie:7"] as! J)["t"]) == 1000, "stamp new")
let s2 = SyncCore.stamp(st(["watched": ["movie:7": J()] as J]), shadow: s1, now: 5000, maps: all)
check(SyncCore.num(((s2["watched"] as! J)["movie:7"] as! J)["t"]) == 1000, "stamp keeps")
let s3 = SyncCore.stamp(st([:]), shadow: s2, now: 9000, maps: all)
check(((s3["watched"] as! J)["movie:7"] as! J)["x"] != nil, "stamp removal")
let a1 = SyncCore.stamp(st(["pos": ["episode:1": ["p": 1000] as J] as J]), shadow: nil, now: 100, maps: all)
let b1 = SyncCore.stamp(st(["pos": ["episode:1": ["p": 5000] as J] as J]), shadow: nil, now: 200, maps: all)
let m1 = SyncCore.merge(a1, b1, now: 300)
check(SyncCore.num(((SyncCore.toState(m1.doc)["pos"] as! J)["episode:1"] as! J)["p"]) == 5000 && !m1.dirty, "newer pos")
let hA = SyncCore.stamp(st(["hist": ["movie:1": ["o": 1, "i": J()] as J, "movie:2": ["o": 0, "i": J()] as J] as J]), shadow: nil, now: 1000, maps: all)
let hB = SyncCore.stamp(st(["hist": ["movie:3": ["o": 0, "i": J()] as J] as J]), shadow: nil, now: 2000, maps: all)
let hs = SyncCore.toState(SyncCore.merge(hA, hB, now: 2000).doc)["hist"] as! J
check(hs.keys.sorted { SyncCore.num((hs[$0] as! J)["o"]) < SyncCore.num((hs[$1] as! J)["o"]) } == ["movie:3", "movie:2", "movie:1"], "history order")
// a document from the Samsung app reads the same here
let js = "{\"v\":1,\"histclear\":{\"live\":0,\"vod\":0},\"hist\":{\"movie:9\":{\"i\":{\"type\":\"movie\",\"id\":\"9\"},\"t\":50}},\"pos\":{\"movie:9\":{\"p\":1234,\"d\":5000,\"t\":50}},\"fav\":{\"live:1\":{\"o\":70,\"i\":{\"type\":\"live\",\"id\":\"1\"},\"t\":70}}}"
let jd = try! JSONSerialization.jsonObject(with: Data(js.utf8)) as! J
let jst = SyncCore.toState(jd)
check(SyncCore.num(((jst["pos"] as! J)["movie:9"] as! J)["p"]) == 1234 && (jst["hist"] as! J)["movie:9"] != nil, "reads JS doc")
var sd = SyncCore.emptyDoc(); sd["settings"] = ["home_fav_movie": ["v": false, "t": 5] as J, "sub_bg": ["v": true, "t": 5] as J] as J
let ss = SyncCore.stamp(st(["settings": ["sub_bg": ["v": true] as J] as J]), shadow: sd, now: 10, maps: all)
check(SyncCore.num(((ss["settings"] as! J)["home_fav_movie"] as! J)["t"]) == 5, "keeps settings this app lacks")
check(SyncCore.num(((ss["settings"] as! J)["sub_bg"] as! J)["t"]) == 5, "Bool and JSON true are the same")
check(SyncCore.canon(1) != SyncCore.canon(true), "1 is not true")
let h3 = SyncCore.stamp(st(["hist": ["live:1": ["o": 0, "i": J()] as J, "live:2": ["o": 1, "i": J()] as J, "live:3": ["o": 2, "i": J()] as J] as J]), shadow: nil, now: 1000, maps: all)
let r3 = SyncCore.stamp(st(["hist": ["live:1": ["o": 0, "i": J()] as J, "live:3": ["o": 1, "i": J()] as J] as J]), shadow: h3, now: 2000, maps: all)
check(((r3["hist"] as! J)["live:2"] as! J)["x"] != nil, "channel removal stamped")
let o3 = SyncCore.merge(r3, h3, now: 2000).doc
check((SyncCore.toState(o3)["hist"] as! J)["live:2"] == nil && (o3["hist"] as! J)["live:2"] != nil, "removal spreads and is kept")
print("SyncCore OK")
