import Foundation
import Network

/// A tiny web server on your Wi-Fi that hands the TV the converted stream (Apple TVs and
/// Chromecasts fetch it from the Mac). Serves files from registered folders only.
final class LocalServer {
    static let shared = LocalServer()
    private let queue = DispatchQueue(label: "ymplayer.localserver")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var folders: [String: URL] = [:]   // token → folder
    private let lock = NSLock()

    /// "http://192.168.1.20:52114/<token>/" for a folder, or nil if there's no Wi-Fi / network.
    func publish(_ folder: URL) -> URL? {
        guard ensureRunning(), let ip = LocalServer.lanAddress() else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.lock(); folders[token] = folder; lock.unlock()
        return URL(string: "http://\(ip):\(port)/\(token)/")
    }

    func unpublish(_ folder: URL) {
        lock.lock(); folders = folders.filter { $0.value != folder }; lock.unlock()
    }

    private func ensureRunning() -> Bool {
        if listener != nil && port != 0 { return true }
        guard let l = try? NWListener(using: .tcp, on: .any) else { return false }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            switch st {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let p = l.port?.rawValue, p != 0 else { l.cancel(); return false }
        listener = l
        port = p
        return true
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let head = String(data: data, encoding: .utf8),
                  let line = head.components(separatedBy: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { c.cancel(); return }
            let method = String(parts[0]), path = String(parts[1]).components(separatedBy: "?")[0]
            if method == "OPTIONS" { return self.send(c, 204, "text/plain", Data(), head: true) }
            let bits = path.split(separator: "/").map(String.init)
            guard bits.count == 2, !bits[1].contains(".."), let folder = self.folder(bits[0]) else {
                return self.send(c, 404, "text/plain", Data("Not found".utf8), head: false)
            }
            let file = folder.appendingPathComponent(bits[1])
            self.serve(c, file, head: method == "HEAD", tries: 0)
        }
    }

    private func folder(_ token: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return folders[token]
    }

    /// The playlist appears a few seconds after converting starts: wait for it rather than fail.
    private func serve(_ c: NWConnection, _ file: URL, head: Bool, tries: Int) {
        if let d = try? Data(contentsOf: file), !d.isEmpty {
            let ext = file.pathExtension.lowercased()
            let type = ext == "m3u8" ? "application/vnd.apple.mpegurl" : ext == "ts" ? "video/mp2t"
                : ext == "m4s" || ext == "mp4" ? "video/mp4" : "application/octet-stream"
            return send(c, 200, type, d, head: head)
        }
        if tries < 120 {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.serve(c, file, head: head, tries: tries + 1) }
        } else {
            send(c, 404, "text/plain", Data("Not ready".utf8), head: false)
        }
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, head: Bool) {
        let reason = code == 200 ? "OK" : code == 204 ? "No Content" : "Not Found"
        var h = "HTTP/1.1 \(code) \(reason)\r\n"
        h += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        h += "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
        h += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(h.utf8)
        if !head { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// This Mac's address on the local network (Wi-Fi or Ethernet).
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name.hasPrefix("en") { return ip } // Wi-Fi / Ethernet first
            if best == nil && !ip.hasPrefix("169.254") { best = ip }
        }
        return best
    }
}
