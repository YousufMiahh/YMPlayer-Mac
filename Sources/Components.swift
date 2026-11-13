import SwiftUI

enum Theme {
    static let accent = Color(red: 0.56, green: 0.38, blue: 1.0)
    static let pink = Color(red: 0.96, green: 0.40, blue: 0.55)
    static let card = Color.white.opacity(0.06)
    static let cardHi = Color.white.opacity(0.13)
    static let gradient = LinearGradient(colors: [Color(red: 0.36, green: 0.35, blue: 0.98), Color(red: 0.55, green: 0.24, blue: 0.92),
                                                  Color(red: 0.96, green: 0.40, blue: 0.47)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
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
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Theme.accent : Color.clear, lineWidth: 3))
                .shadow(color: .black.opacity(hover ? 0.45 : 0.2), radius: hover ? 10 : 4, y: 3)
                .scaleEffect(hover ? 1.035 : 1)
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
        .animation(.easeOut(duration: 0.15), value: hover)
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
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Theme.accent))
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
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Theme.accent : Color.clear, lineWidth: 3))
                .scaleEffect(hover ? 1.035 : 1)
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
            Text("\(rank)")
                .font(.system(size: 120, weight: .black, design: .rounded))
                .foregroundStyle(Theme.gradient)
                .shadow(color: .black.opacity(0.6), radius: 4)
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
