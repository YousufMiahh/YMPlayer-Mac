import SwiftUI

/// The same look as the TV and phone apps, in their dark and light themes: near-black navy (or
/// soft grey), system blue, see-through surfaces. Each colour follows the app's light / dark mode.
enum Theme {
    static let accent = Color(hex: 0x0A84FF)            // system blue
    static let pink = Color(hex: 0xFF453A)              // hearts (the apps' red)
    static let bg = dyn(ns(0x0A0B12), ns(0xF2F2F7))
    static let card = dyn(.white.withAlphaComponent(0.10), .black.withAlphaComponent(0.07))     // SURFACE
    static let cardHi = dyn(.white.withAlphaComponent(0.18), .black.withAlphaComponent(0.13))   // SURFACE_HI
    static let text2 = dyn(ns(0xEBEBF5, 0.60), ns(0x3C3C43, 0.60))
    static let text3 = dyn(ns(0xEBEBF5, 0.30), ns(0x3C3C43, 0.36))
    static let focus = dyn(.white, ns(0x1D1D1F))         // the TV app's focus highlight
    static let onFocus = dyn(ns(0x0B0B0F), .white)
    static let ease = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.28) // the apps' decelerate curve

    static func ns(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// One colour for dark mode, another for light.
    static func dyn(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Settings → Appearance: 0 = match the Mac, 1 = light, 2 = dark.
    static func applyAppearance(_ mode: Int) {
        NSApp.appearance = mode == 1 ? NSAppearance(named: .aqua) : mode == 2 ? NSAppearance(named: .darkAqua) : nil
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The apps' ambient background: a soft glow of each section's colour at the top, fading into the
/// dark, and cross-fading as you move between sections (as on the TV and phone).
struct AmbientBackground: View {
    let page: Page
    @Environment(\.colorScheme) private var scheme

    static func base(_ p: Page) -> UInt32 {
        switch p {
        case .home: return 0x2A2F7A
        case .live: return 0x0F5C66
        case .movies: return 0x6A1F4A
        case .series: return 0x1F4E8C
        case .search: return 0x4A2A80
        case .downloads: return 0x1F5C7A
        case .settings: return 0x3A3F52
        }
    }

    /// Rich but calm (dark), or a pale wash (light): the same toning as the Android apps.
    static func tone(_ hex: UInt32, dark: Bool) -> NSColor {
        let c = Theme.ns(hex).usingColorSpace(.sRGB) ?? Theme.ns(hex)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { h = 228 / 360; s = 0.30 }
        if dark {
            s = min(0.85, max(0.35, max(s * 1.25, 0.35)))
            return NSColor(hue: h, saturation: s, brightness: 0.46, alpha: 1)
        }
        s = min(0.32, max(0.10, s * 0.55))
        return NSColor(hue: h, saturation: s, brightness: 0.97, alpha: 1)
    }

    static func gradient(_ p: Page, dark: Bool) -> LinearGradient {
        let top = tone(base(p), dark: dark)
        let bg = dark ? Theme.ns(0x0A0B12) : Theme.ns(0xF2F2F7)
        func mix(_ t: CGFloat) -> Color { Color(nsColor: top.blended(withFraction: t, of: bg) ?? bg) }
        return LinearGradient(colors: [Color(nsColor: top), mix(0.45), mix(0.85), Color(nsColor: bg)], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.bg
            ForEach(Page.allCases) { p in
                AmbientBackground.gradient(p, dark: dark).opacity(p == page ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: page)
        .ignoresSafeArea()
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

/// Movie / series / episode poster with the title underneath.
struct PosterCard: View {
    @EnvironmentObject var store: AppStore
    let item: Item
    var width: CGFloat? = 150
    var title: String? = nil
    var subtitle: String? = nil
    var progress: Double? = nil
    var showTitle = true
    let action: () -> Void
    var extraMenu: (() -> AnyView)? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: width)
                .background(Theme.card)
                .overlay(
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                )
                .overlay(RemoteImage(url: item.posterURL, maxPixel: 480))
                .overlay(alignment: .bottom) {
                    if let p = progress { ProgressLine(value: p).padding(8) }
                }
                .overlay(alignment: .topTrailing) {
                    if store.isWatched(item) { WatchedBadge().padding(7) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Theme.focus : Color.clear, lineWidth: 3))
                .shadow(color: .black.opacity(hover ? 0.5 : 0.2), radius: hover ? 14 : 4, y: hover ? 6 : 3)
                .scaleEffect(hover ? 1.06 : 1)
            if showTitle {
                Text(title ?? item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: width ?? .infinity, alignment: .leading)
                if let s = subtitle {
                    Text(s)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: width ?? .infinity, alignment: .leading)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            if item.kind != .episode {
                Button(store.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite(item) }
            }
            if item.kind == .movie || item.kind == .episode {
                Button(store.inQueue(item) ? "Remove from Queue" : "Add to Queue") { store.toggleQueue(item) }
                Button(store.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched") { store.setWatched(item, !store.isWatched(item)) }
            }
            if let m = extraMenu { m() }
        }
        .help(item.name)
    }
}

/// The ✓ in the corner of something you've watched.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(Theme.onFocus)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Theme.focus.opacity(0.95)))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// A channel: its logo on a card, name underneath.
struct ChannelCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let item: Item
    var width: CGFloat? = 190
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: width)
                .background(Theme.card)
                .overlay(
                    Text(initials(item.name))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.tertiary)
                )
                .overlay(RemoteImage(url: item.iconURL, maxPixel: 320, mode: .fit).padding(16))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Theme.focus : Color.clear, lineWidth: 3))
                .shadow(color: .black.opacity(hover ? 0.5 : 0), radius: 12, y: 5)
                .scaleEffect(hover ? 1.06 : 1)
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: width ?? .infinity, alignment: .leading)
            if let p = epg.now(item.streamId) {
                Text(p.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: width ?? .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .onAppear { epg.request(item) }
        .contextMenu {
            Button("Watch") { action() }
            Button(store.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite(item) }
        }
        .help(item.name)
    }
}

func initials(_ s: String) -> String {
    let words = s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return String(words.prefix(2).compactMap { $0.first }).uppercased()
}

/// A titled horizontal row (Netflix-style shelf).
struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 20, weight: .bold))
                if let s = subtitle { Text(s).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) { content() }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
            }
        }
    }
}

/// Big rank number beside the poster, for the Top 10 rows.
struct RankedCard: View {
    let rank: Int
    let item: Item
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: -14) {
            OutlinedNumber(text: "\(rank)")
                .frame(minWidth: 60)
                .offset(y: 18)
            PosterCard(item: item, width: 128, showTitle: false, action: action)
        }
        .padding(.bottom, 6)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            if let m = message {
                Text(m).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct LoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The category list on the left of Live TV, Movies and Series. Right-click to favourite or hide.
struct CategoryColumn: View {
    @EnvironmentObject var store: AppStore
    let kind: Kind
    @Binding var selection: String?
    @State private var renaming: Category?

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let icon: String
        let favourite: Bool
        let category: Category?
    }

    private var entries: [Entry] {
        var out: [Entry] = [Entry(id: Special.favourites, name: "Favourites", icon: "heart.fill", favourite: true, category: nil)]
        if kind == .live { out.append(Entry(id: Special.recent, name: "Recently Watched", icon: "clock.arrow.circlepath", favourite: false, category: nil)) }
        out.append(Entry(id: Special.all, name: "All " + kind.title, icon: "square.grid.2x2", favourite: false, category: nil))
        let cats = store.visibleCategories(kind)
        for c in cats where store.isFavCategory(kind, c) {
            out.append(Entry(id: c.id, name: c.name, icon: "heart.fill", favourite: true, category: c))
        }
        for c in cats where !store.isFavCategory(kind, c) {
            out.append(Entry(id: c.id, name: c.name, icon: "folder", favourite: false, category: c))
        }
        return out
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(list) { e in
                    Label {
                        Text(e.name).lineLimit(1)
                    } icon: {
                        Image(systemName: e.icon).foregroundStyle(e.favourite ? Theme.pink : Color.secondary)
                    }
                    .tag(e.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let c = list.first(where: { $0.id == id })?.category {
                    Button(store.isFavCategory(kind, c) ? "Remove from Favourite Categories" : "Add to Favourite Categories") {
                        store.toggleFavCategory(kind, c)
                    }
                    Button("Rename…") { renaming = c }
                    Button("Hide This Category") {
                        if selection == c.id { selection = Special.all }
                        store.hideCategory(kind, c)
                    }
                }
            }
            Divider()
            Text("Right-click a category to favourite, rename or hide it")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
        }
        .sheet(item: $renaming) { c in RenameSheet(kind: kind, category: c).environmentObject(store) }
    }
}

/// Give a category your own name (blank or "Original Name" puts the provider's back).
struct RenameSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let category: Category
    @State private var name = ""

    var body: some View {
        let original = store.originalName(kind, category)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Category").font(.title3.bold())
            Text("Original name: " + original).font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit(save)
            HStack {
                Button("Original Name") {
                    store.renameCategory(kind, category, to: "")
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .onAppear { name = category.name }
    }

    private func save() {
        store.renameCategory(kind, category, to: name)
        dismiss()
    }
}

/// Netflix-style rank number: the background colour inside, a light edge around it.
struct OutlinedNumber: View {
    let text: String

    var body: some View {
        let font = Font.system(size: 120, weight: .black, design: .rounded)
        let edge = Theme.dyn(Theme.ns(0xEBEBF5, 0.8), Theme.ns(0x3C3C43, 0.7))
        ZStack {
            ForEach(0..<16, id: \.self) { i in
                let a = Double(i) / 16 * 2 * .pi
                Text(text).font(font).foregroundStyle(edge).offset(x: 2.2 * cos(a), y: 2.2 * sin(a))
            }
            Text(text).font(font).foregroundStyle(Theme.bg)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 6)
    }
}
