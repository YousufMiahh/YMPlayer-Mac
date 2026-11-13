import SwiftUI
import WebKit

/// A YouTube trailer, played right here in the app (the same embedded player the TV and phone use).
struct TrailerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let videoId: String
    let title: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            YouTubePlayer(videoId: videoId)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
            .help("Close (Esc)")
        }
        .frame(width: 960, height: 540)
        .environment(\.colorScheme, .dark)
    }

    /// "https://www.youtube.com/watch?v=abc", "youtu.be/abc" or just "abc" → "abc".
    static func youtubeId(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let r = s.range(of: "[?&]v=([A-Za-z0-9_-]{6,})", options: .regularExpression) {
            s = String(s[r]).components(separatedBy: "v=").last ?? s
        } else if let r = s.range(of: "(youtu\\.be/|/embed/|/shorts/)([A-Za-z0-9_-]{6,})", options: .regularExpression) {
            s = String(String(s[r]).split(separator: "/").last ?? "")
        }
        s = s.components(separatedBy: CharacterSet(charactersIn: "?&#")).first ?? s
        return s.range(of: "^[A-Za-z0-9_-]{6,}$", options: .regularExpression) != nil ? s : nil
    }
}

private struct YouTubePlayer: NSViewRepresentable {
    let videoId: String

    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.setValue(false, forKey: "drawsBackground")
        let html = """
        <!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{border:0;width:100%;height:100%}</style>
        </head><body><iframe src='https://www.youtube-nocookie.com/embed/\(videoId)?autoplay=1&rel=0&modestbranding=1&playsinline=1'
        allow='autoplay; encrypted-media; fullscreen; picture-in-picture' allowfullscreen referrerpolicy='strict-origin-when-cross-origin'></iframe>
        </body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {}

    static func dismantleNSView(_ w: WKWebView, coordinator: ()) {
        w.loadHTMLString("", baseURL: nil) // stop the sound when the sheet closes
    }
}
