import SwiftUI
import AppKit
import ImageIO

enum ImageMemory {
    static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 1500
        return c
    }()

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 6
        c.urlCache = URLCache(memoryCapacity: 30 << 20, diskCapacity: 400 << 20,
                              directory: Storage.caches.appendingPathComponent("images", isDirectory: true))
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()
}

/// Loads pictures once, shares them between cards, retries after a blip and remembers a
/// failure only briefly.
actor ImageLoader {
    static let shared = ImageLoader()
    private var failed: [URL: Date] = [:]
    private var tasks: [URL: Task<NSImage?, Never>] = [:]

    func image(_ url: URL, maxPixel: Int) async -> NSImage? {
        if let i = ImageMemory.cache.object(forKey: url as NSURL) { return i }
        if let f = failed[url], Date().timeIntervalSince(f) < 45 { return nil }
        if let t = tasks[url] { return await t.value }
        let t = Task<NSImage?, Never> { await ImageLoader.fetch(url, maxPixel: maxPixel) }
        tasks[url] = t
        let img = await t.value
        tasks[url] = nil
        if let img = img { ImageMemory.cache.setObject(img, forKey: url as NSURL) } else { failed[url] = Date() }
        return img
    }

    static func fetch(_ url: URL, maxPixel: Int) async -> NSImage? {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            do {
                var r = URLRequest(url: url, timeoutInterval: 15)
                r.setValue(XtreamAPI.userAgent, forHTTPHeaderField: "User-Agent")
                let (d, resp) = try await ImageMemory.session.data(for: r)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                    if h.statusCode == 404 || h.statusCode == 403 { return nil }
                    continue
                }
                return downsample(d, maxPixel)
            } catch {
                continue
            }
        }
        return nil
    }

    static func downsample(_ d: Data, _ maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: d)
    }
}

/// A picture from the web. Shows nothing until it arrives, so put a placeholder behind it.
struct RemoteImage: View {
    let url: URL?
    var maxPixel: Int = 400
    var mode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: mode)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: image != nil)
        .task(id: url) {
            guard let url = url else {
                image = nil
                return
            }
            if let c = ImageMemory.cache.object(forKey: url as NSURL) {
                var t = Transaction()
                t.disablesAnimations = true // already here: no fade
                withTransaction(t) { image = c }
                return
            }
            image = nil
            let loaded = await ImageLoader.shared.image(url, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}
