import SwiftUI

struct LiveView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @State private var category: String? = Special.all
    @State private var selected: String?
    @State private var query = ""
    @State private var results: [Item]?
    @State private var guide = false
    @State private var previewTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?

    private var channels: [Item] { results ?? store.itemsFor(.live, category) }
    private var selectedItem: Item? {
        guard let id = selected else { return nil }
        return channels.first { $0.id == id } ?? store.data.recentChannels.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            CategoryColumn(kind: .live, selection: $category)
                .frame(width: 250)
            Divider()
            if store.items[.live] == nil {
                if let e = store.loadError[.live] {
                    EmptyState(icon: "wifi.exclamationmark", title: "Couldn't load channels", message: e)
                } else {
                    LoadingView(text: "Loading channels…")
                }
            } else if guide {
                GuideView(channels: channels, title: title)
            } else {
                channelList
                    .frame(minWidth: 320)
                Divider()
                PreviewPane(preview: store.preview, channel: selectedItem) {
                    if let c = selectedItem { play(c) }
                }
                .frame(width: 430)
            }
        }
        .navigationTitle("Live TV")
        .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $guide) {
                    Label("Channels", systemImage: "list.bullet").tag(false)
                    Label("TV Guide", systemImage: "calendar").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Switch between the channel list and the TV guide")
            }
        }
        .onChange(of: query) { _ in runSearch() }
        .onChange(of: category) { _ in
            if !query.isEmpty { query = "" }
        }
        .onChange(of: selected) { _ in schedulePreview() }
        .onChange(of: guide) { g in if g { store.preview.stop() } else { schedulePreview() } }
        .onChange(of: store.session == nil) { idle in if idle && !guide { schedulePreview() } }
        .onDisappear {
            previewTask?.cancel()
            store.preview.stop()
        }
        .task { await store.ensureLoaded(.live) }
    }

    private var title: String { results != nil ? "Results for “\(query)”" : store.categoryName(.live, category) }

    private var channelList: some View {
        let list = channels
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 18, weight: .bold)).lineLimit(1)
                Spacer()
                Text("\(list.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if list.isEmpty {
                EmptyState(icon: category == Special.favourites ? "heart" : "tv",
                           title: results != nil ? "No channels found" : category == Special.favourites ? "No favourite channels yet" : "Nothing here",
                           message: category == Special.favourites ? "Right-click a channel and choose Add to Favourites." : nil)
            } else {
                List(selection: $selected) {
                    ForEach(list) { ch in
                        ChannelRow(channel: ch).tag(ch.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let ch = list.first(where: { $0.id == id }) {
                        Button("Watch") { play(ch) }
                        Button(store.isFavourite(ch) ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite(ch) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let ch = list.first(where: { $0.id == id }) { play(ch) }
                }
                Text("Click to preview  ·  Double-click or Return to watch  ·  Right-click to favourite")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
        }
    }

    private func play(_ ch: Item) {
        previewTask?.cancel()
        store.play(ch, list: channels)
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard !guide, store.session == nil, let ch = selectedItem, store.previewMode > 0 else {
            if store.session == nil { store.preview.stop() }
            return
        }
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            store.startPreview(ch)
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard Match.Query(q).usable else {
            results = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let idx = await store.searchIndex(.live)
            let hits = await Task.detached { Match.rank(idx, q, max: 300) }.value
            if !Task.isCancelled { results = hits }
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let channel: Item

    var body: some View {
        HStack(spacing: 12) {
            Text(channel.num ?? "")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.card)
                Text(initials(channel.name)).font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                RemoteImage(url: channel.iconURL, maxPixel: 160, mode: .fit).padding(4)
            }
            .frame(width: 60, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let p = epg.now(channel.streamId) {
                    HStack(spacing: 6) {
                        Text(p.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        ProgressLine(value: p.progress).frame(width: 40)
                    }
                }
            }
            Spacer(minLength: 0)
            if store.isFavourite(channel) {
                Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(Theme.pink)
            }
        }
        .padding(.vertical, 3)
        .onAppear { epg.request(channel) }
    }
}

struct PreviewPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @ObservedObject var preview: PlayerModel
    let channel: Item?
    let watch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color.black
                    if store.session == nil { VideoSurface(video: preview.video) }
                    if channel == nil {
                        Text("Pick a channel to preview it").foregroundStyle(.secondary)
                    } else if store.previewMode == 0 {
                        Text("Live preview is off (Settings)").foregroundStyle(.secondary)
                    } else if preview.failed {
                        Text("This channel isn't playing right now").foregroundStyle(.secondary)
                    } else if preview.buffering {
                        ProgressView()
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if channel != nil && store.previewMode > 0 {
                        Button { preview.muted.toggle() } label: {
                            Image(systemName: preview.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .padding(8)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help(preview.muted ? "Unmute preview" : "Mute preview")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { watch() }

                if let ch = channel {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.card)
                            RemoteImage(url: ch.iconURL, maxPixel: 200, mode: .fit).padding(6)
                        }
                        .frame(width: 76, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ch.name).font(.system(size: 18, weight: .bold)).lineLimit(2)
                            if let n = ch.num { Text("Channel \(n)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    HStack(spacing: 10) {
                        Button(action: watch) {
                            Label("Watch Full Screen", systemImage: "play.fill").padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button { store.toggleFavourite(ch) } label: {
                            Image(systemName: store.isFavourite(ch) ? "heart.fill" : "heart")
                        }
                        .controlSize(.large)
                        .help(store.isFavourite(ch) ? "Remove from Favourites" : "Add to Favourites")
                    }
                    programmes(ch)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func programmes(_ ch: Item) -> some View {
        if let list = epg.get(ch.streamId) {
            if list.isEmpty {
                Text("No guide information for this channel.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(list.prefix(6)) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(p.timeRange).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                                if p.isNow {
                                    Text("NOW").font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.accent, in: Capsule())
                                }
                            }
                            Text(p.title).font(.system(size: 14, weight: .semibold))
                            if p.isNow { ProgressLine(value: p.progress).frame(maxWidth: 220) }
                            if !p.desc.isEmpty {
                                Text(p.desc).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(p.isNow ? 6 : 2)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).onAppear { epg.request(ch) }
        }
    }
}

// MARK: - TV guide

struct GuideView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let channels: [Item]
    let title: String
    @State private var start = GuideView.roundedNow()
    private let span: TimeInterval = 3 * 3600
    private let chanW: CGFloat = 190

    static func roundedNow() -> Date {
        let t = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 1800))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 18, weight: .bold)).lineLimit(1)
                Spacer()
                Text(Fmt.day.string(from: start)).foregroundStyle(.secondary)
                Button { start = start.addingTimeInterval(-3600) } label: { Image(systemName: "chevron.left") }
                    .disabled(start <= GuideView.roundedNow())
                    .help("Earlier")
                Button("Now") { start = GuideView.roundedNow() }
                Button { start = start.addingTimeInterval(3600) } label: { Image(systemName: "chevron.right") }
                    .help("Later")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if channels.isEmpty {
                EmptyState(icon: "calendar", title: "No channels here")
            } else {
                GeometryReader { g in
                    let w = max(200, g.size.width - chanW - 20)
                    VStack(spacing: 0) {
                        timeHeader(w)
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(channels) { ch in
                                    GuideRow(channel: ch, channels: channels, start: start, span: span, width: w, chanW: chanW)
                                }
                            }
                            .padding(.bottom, 12)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            Text("Double-click a channel to watch  ·  Click a programme for details")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
        }
    }

    private func timeHeader(_ w: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: chanW + 4, height: 26)
            ZStack(alignment: .topLeading) {
                ForEach(0..<6, id: \.self) { i in
                    Text(Fmt.hm.string(from: start.addingTimeInterval(Double(i) * 1800)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(i) * w / 6 + 4, y: 5)
                }
            }
            .frame(width: w, height: 26, alignment: .topLeading)
            .clipped()
        }
    }
}

struct GuideRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    let channel: Item
    let channels: [Item]
    let start: Date
    let span: TimeInterval
    let width: CGFloat
    let chanW: CGFloat
    @State private var shown: String?

    private let rowH: CGFloat = 54

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    Text(initials(channel.name)).font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    RemoteImage(url: channel.iconURL, maxPixel: 160, mode: .fit)
                }
                .frame(width: 50, height: 30)
                Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: chanW, height: rowH)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.play(channel, list: channels) }
            .help("Double-click to watch \(channel.name)")

            ZStack(alignment: .topLeading) {
                Color.clear
                if let progs = epg.get(channel.streamId) {
                    let visible = progs.filter { $0.stop > start && $0.start < start.addingTimeInterval(span) }
                    if visible.isEmpty {
                        Text("No guide information")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                            .frame(height: rowH)
                    }
                    ForEach(visible) { p in block(p) }
                } else {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 12).frame(height: rowH)
                }
                let nx = x(Date())
                if nx >= 0 && nx <= width {
                    Rectangle().fill(Theme.accent).frame(width: 2, height: rowH).offset(x: nx)
                }
            }
            .frame(width: width, height: rowH, alignment: .topLeading)
            .clipped()
        }
        .onAppear { epg.request(channel) }
    }

    private func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / span) * width }

    private func block(_ p: Programme) -> some View {
        let x1 = max(0, x(p.start)), x2 = min(width, x(p.stop))
        return Button { shown = p.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(p.timeRange).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: max(0, x2 - x1 - 3), height: rowH, alignment: .leading)
            .background(p.isNow ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x1)
        .popover(isPresented: Binding(get: { shown == p.id }, set: { if !$0 { shown = nil } }), arrowEdge: .bottom) {
            ProgrammeDetail(programme: p, channel: channel) {
                shown = nil
                store.play(channel, list: channels)
            }
        }
    }
}

struct ProgrammeDetail: View {
    let programme: Programme
    let channel: Item
    let watch: () -> Void

    private var status: String {
        let now = Date()
        if programme.isNow { return "On now, \(Int(programme.stop.timeIntervalSince(now) / 60)) min left" }
        if programme.start > now {
            let m = Int((programme.start.timeIntervalSince(now) + 59) / 60)
            return m >= 60 ? "Starts in \(m / 60) hr \(m % 60) min" : "Starts in \(m) min"
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(programme.title).font(.system(size: 17, weight: .bold))
            Text(channel.name + "  ·  " + programme.timeRange + (status.isEmpty ? "" : "  ·  " + status))
                .font(.callout).foregroundStyle(.secondary)
            if !programme.desc.isEmpty {
                ScrollView { Text(programme.desc).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
            }
            Button(action: watch) { Label("Watch \(channel.name)", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .frame(width: 380)
    }
}
