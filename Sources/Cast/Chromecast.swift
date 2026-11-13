import Foundation
import Network

/// A Chromecast / Google TV found on the network.
struct CastDevice: Identifiable, Hashable {
    let id: String          // the Bonjour service name
    let name: String        // "Living Room TV"
    let model: String
    let endpoint: NWEndpoint

    static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Finds Chromecasts and Google TVs (they announce themselves as "_googlecast._tcp").
@MainActor
final class CastBrowser: ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var searching = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [CastDevice] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var friendly = name, model = ""
                if case let .bonjour(txt) = r.metadata {
                    friendly = txt["fn"] ?? name
                    model = txt["md"] ?? ""
                }
                return CastDevice(id: name, name: friendly, model: model, endpoint: r.endpoint)
            }
            Task { @MainActor in self?.devices = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        }
        b.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready: self?.searching = true
                case .failed, .cancelled: self?.searching = false
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        searching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }
}

/// Talks to one Chromecast using Google's Cast protocol: an encrypted connection on port 8009,
/// messages framed as small protobufs carrying JSON. Launches the standard media receiver on the
/// TV and tells it what to play. Everything here runs on the main thread.
@MainActor
final class ChromecastSession {
    struct Status {
        var time: Double = 0
        var duration: Double = 0
        var state = ""          // PLAYING, PAUSED, BUFFERING, IDLE
        var idleReason = ""     // FINISHED, ERROR, CANCELLED…
    }

    var onStatus: ((Status) -> Void)?
    var onClosed: ((String?) -> Void)?

    private let device: CastDevice
    private var conn: NWConnection?
    private var buffer = Data()
    private var requestId = 1
    private var transportId: String?
    private var appSessionId: String?
    private var mediaSessionId: Int?
    private var pendingLoad: [String: Any]?
    private var heartbeat: Timer?
    private var poll: Timer?
    private var closed = false

    private static let sender = "sender-ym"
    private static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private static let nsMedia = "urn:x-cast:com.google.cast.media"
    private static let mediaReceiver = "CC1AD845" // Google's Default Media Receiver

    init(device: CastDevice) { self.device = device }

    /// Connect, start the media receiver and play `url` from `at` seconds.
    func load(url: URL, contentType: String, live: Bool, at: Double, title: String, subtitle: String?, image: URL?) {
        var meta: [String: Any] = ["metadataType": 0, "title": title]
        if let s = subtitle { meta["subtitle"] = s }
        if let i = image { meta["images"] = [["url": i.absoluteString]] }
        var media: [String: Any] = ["contentId": url.absoluteString, "contentType": contentType,
                                    "streamType": live ? "LIVE" : "BUFFERED", "metadata": meta]
        if contentType.contains("mpegURL") { media["hlsSegmentFormat"] = "ts"; media["hlsVideoSegmentFormat"] = "mpeg2_ts" }
        pendingLoad = ["type": "LOAD", "autoplay": true, "currentTime": max(0, at), "media": media]
        if transportId != nil { sendLoad() } else if conn == nil { connect() }
    }

    func play() { mediaCommand(["type": "PLAY"]) }
    func pause() { mediaCommand(["type": "PAUSE"]) }
    func seek(_ t: Double) { mediaCommand(["type": "SEEK", "currentTime": max(0, t)]) }

    /// Stop the TV's player and disconnect.
    func stop() {
        if let s = appSessionId { send(Self.nsReceiver, to: "receiver-0", ["type": "STOP", "sessionId": s, "requestId": nextId()]) }
        close(nil)
    }

    // MARK: connection

    private func connect() {
        let tls = NWProtocolTLS.Options()
        // Chromecasts use their own certificates: accept them (it's on your own network)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .main)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(to: device.endpoint, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self = self else { return }
                switch st {
                case .ready:
                    self.send(Self.nsConnection, to: "receiver-0", ["type": "CONNECT"])
                    self.send(Self.nsReceiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.mediaReceiver, "requestId": self.nextId()])
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.send(Self.nsHeartbeat, to: "receiver-0", ["type": "PING"]) }
                    }
                    self.receive()
                case .failed(let e):
                    self.close("Couldn't connect to \(self.device.name): \(e.localizedDescription)")
                case .cancelled:
                    self.close(nil)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self = self else { return }
                if let d = data { self.buffer.append(d); self.drain() }
                if done || err != nil { self.close(self.closed ? nil : "The TV disconnected.") } else { self.receive() }
            }
        }
    }

    /// Splits the incoming bytes into messages (4-byte length, then the protobuf).
    private func drain() {
        while buffer.count >= 4 {
            let n = Int(buffer[buffer.startIndex]) << 24 | Int(buffer[buffer.startIndex + 1]) << 16
                | Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            guard buffer.count >= 4 + n else { return }
            let msg = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + n)
            if let m = Self.decode(msg) { handle(m.0, m.1) }
        }
    }

    private func handle(_ ns: String, _ payload: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        let type = o["type"] as? String ?? ""
        switch (ns, type) {
        case (Self.nsHeartbeat, "PING"):
            send(Self.nsHeartbeat, to: "receiver-0", ["type": "PONG"])
        case (Self.nsReceiver, "RECEIVER_STATUS"):
            let apps = ((o["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
            if let app = apps.first(where: { ($0["appId"] as? String) == Self.mediaReceiver }),
               let t = app["transportId"] as? String {
                if transportId != t {
                    transportId = t
                    appSessionId = app["sessionId"] as? String
                    send(Self.nsConnection, to: t, ["type": "CONNECT"])
                    sendLoad()
                }
            } else if transportId != nil {
                close(nil) // the media app was closed on the TV
            }
        case (Self.nsReceiver, "LAUNCH_ERROR"):
            close("The TV couldn't start its player.")
        case (Self.nsMedia, "MEDIA_STATUS"):
            guard let st = (o["status"] as? [[String: Any]])?.first else { return }
            if let id = st["mediaSessionId"] as? Int { mediaSessionId = id }
            var s = Status()
            s.time = (st["currentTime"] as? NSNumber)?.doubleValue ?? 0
            s.duration = ((st["media"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue ?? 0
            s.state = st["playerState"] as? String ?? ""
            s.idleReason = st["idleReason"] as? String ?? ""
            onStatus?(s)
        case (Self.nsMedia, "LOAD_FAILED"), (Self.nsMedia, "LOAD_CANCELLED"):
            close("The TV couldn't play this.")
        default: break
        }
    }

    private func sendLoad() {
        guard let t = transportId, var l = pendingLoad else { return }
        pendingLoad = nil
        l["requestId"] = nextId()
        send(Self.nsMedia, to: t, l)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let t = self.transportId else { return }
                self.send(Self.nsMedia, to: t, ["type": "GET_STATUS", "requestId": self.nextId()])
            }
        }
    }

    private func mediaCommand(_ m: [String: Any]) {
        guard let t = transportId, let id = mediaSessionId else { return }
        var m = m
        m["mediaSessionId"] = id
        m["requestId"] = nextId()
        send(Self.nsMedia, to: t, m)
    }

    private func nextId() -> Int {
        requestId += 1
        return requestId
    }

    private func send(_ ns: String, to dest: String, _ json: [String: Any]) {
        guard let c = conn, let d = try? JSONSerialization.data(withJSONObject: json), let s = String(data: d, encoding: .utf8) else { return }
        let body = Self.encode(source: Self.sender, dest: dest, ns: ns, payload: s)
        var frame = Data([UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        frame.append(body)
        c.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func close(_ error: String?) {
        if closed { return }
        closed = true
        heartbeat?.invalidate()
        poll?.invalidate()
        if let c = conn, transportId != nil {
            // Say goodbye politely, then hang up
            let body = Self.encode(source: Self.sender, dest: transportId ?? "receiver-0", ns: Self.nsConnection, payload: "{\"type\":\"CLOSE\"}")
            var frame = Data([UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
            frame.append(body)
            c.send(content: frame, completion: .contentProcessed { _ in c.cancel() })
        } else {
            conn?.cancel()
        }
        conn = nil
        onClosed?(error)
    }

    // MARK: the CastMessage protobuf (just the fields used)

    private static func encode(source: String, dest: String, ns: String, payload: String) -> Data {
        var d = Data()
        func varint(_ v: Int) {
            var v = UInt64(v)
            repeat {
                var b = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { b |= 0x80 }
                d.append(b)
            } while v != 0
        }
        func string(_ field: Int, _ s: String) {
            let bytes = Data(s.utf8)
            d.append(UInt8(field << 3 | 2))
            varint(bytes.count)
            d.append(bytes)
        }
        d.append(0x08); varint(0)          // protocol_version = CASTV2_1_0
        string(2, source)                  // source_id
        string(3, dest)                    // destination_id
        string(4, ns)                      // namespace
        d.append(0x28); varint(0)          // payload_type = STRING
        string(6, payload)                 // payload_utf8
        return d
    }

    /// (namespace, payload) from a received message.
    private static func decode(_ data: Data) -> (String, String)? {
        let b = [UInt8](data)
        var i = 0
        var ns: String?, payload: String?
        func varint() -> Int? {
            var result = 0, shift = 0
            while i < b.count {
                let byte = b[i]; i += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 0: _ = varint()
            case 2:
                guard let len = varint(), len >= 0, i + len <= b.count else { return nil }
                let s = String(decoding: b[i ..< i + len], as: UTF8.self)
                if field == 4 { ns = s } else if field == 6 { payload = s }
                i += len
            case 5: i += 4
            case 1: i += 8
            default: return nil
            }
        }
        guard let n = ns, let p = payload else { return nil }
        return (n, p)
    }
}
