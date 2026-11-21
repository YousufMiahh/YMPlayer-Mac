import SwiftUI
import AppKit

/// A film's or series' logo in place of its name (the artwork Netflix and Apple TV show, from
/// TMDB). The name shows until the logo has loaded, and when there isn't one or the app is light.
struct TitleLogo: View {
    let kind: Tmdb.Kind
    let name: String
    let tmdb: String?
    var height: CGFloat = 90
    var maxWidth: CGFloat = 420
    var font: Font = .system(size: 28, weight: .bold)
    var alignment: Alignment = .leading

    @Environment(\.colorScheme) private var scheme
    @State private var image: NSImage?

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let img = image, scheme == .dark {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: height, alignment: alignment)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 2)
                    .transition(.opacity)
                    .accessibilityLabel(name)
            } else {
                Text(name).font(font).lineLimit(2)
            }
        }
        .task(id: name) { await load() }
    }

    @MainActor private func load() async {
        let ck = "\(kind.rawValue):\(name)"
        if let hit = TitleLogo.cache[ck] { image = hit; return }
        guard let id = await Tmdb.findId(kind, name: name, known: tmdb), let url = await Tmdb.logo(kind, id: id) else { return }
        guard let (d, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: d) else { return }
        TitleLogo.cache[ck] = img
        withAnimation(.easeOut(duration: 0.35)) { image = img }
    }
}
