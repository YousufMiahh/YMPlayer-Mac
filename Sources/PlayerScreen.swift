import SwiftUI
import UniformTypeIdentifiers

/// The full-window player.
struct PlayerScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @ObservedObject var player: PlayerModel
    @ObservedObject var cast: CastController
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var monitor: Any?
    @State private var nextHidden = false   // you closed the Next card for this one
    @State private var nextFired = false

    private var item: Item? { store.session?.item }
    private var live: Bool { item?.kind == .live }

    private var title: String {
        guard let it = item else { return "" }
        return it.kind == .episode ? (it.seriesName ?? it.name) : it.name
    }

    private var subtitle: String? {
        guard let it = item else { return nil }
        switch it.kind {
        case .live:
            if let p = epg.now(it.streamId) { return p.timeRange + "   " + p.title }
            return it.num.map { "Channel \($0)" }
        case .episode:
            return [it.episodeLabel, it.name == it.seriesName ? nil : it.name].compactMap { $0 }.joined(separator: "  ·  ")
        default:
            return it.rating
        }
    }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(video: player.video)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture {
                    if !live { player.togglePause() }
                    poke()
                }
                // Trackpad pinch: out to fill the screen, in to see the whole picture
                .simultaneousGesture(MagnificationGesture().onEnded { v in
                    if v > 1.15 && player.picture != .fill { store.setPicture(.fill) }
                    else if v < 0.87 && player.picture != .fit { store.setPicture(.fit) }
                })
            if player.buffering && !player.failed {
                ProgressView().controlSize(.large)
            }
            if player.failed { failure }
            if controls || (!player.playing && !player.buffering) {
                overlay.transition(.opacity)
            }
            if showSkip {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: skipIntro) {
                            Text(skipRecap ? "Skip Recap" : "Skip Intro")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 22).padding(.vertical, 12)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .help("Skip Intro (S)")
                    }
                }
                .padding(.trailing, 34)
                .padding(.bottom, controls ? 130 : 44)
                .transition(.opacity)
            }
            if let nx = store.upNext, showNext {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        NextCard(item: nx, label: nx.kind == .episode && store.session?.list.contains(where: { $0.id == nx.id }) == true ? "Next Episode" : "Next in Queue",
                                 fill: nextFill,
                                 play: { nextFired = true; store.playNext() },
                                 close: { nextHidden = true })
                    }
                }
                .padding(.trailing, 34)
                .padding(.bottom, controls ? 130 : 44)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if cast.isCasting {
                CastingView(cast: cast, title: title, subtitle: subtitle)
                    .transition(.opacity)
            }
            if let t = store.toast {
                VStack {
                    Text(t)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 70)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .onAppear {
            installKeys()
            poke()
            if let it = item, it.kind == .live { epg.request(it) }
        }
        .onDisappear {
            removeKeys()
            hideTask?.cancel()
        }
        .onChange(of: store.session?.item.id) { _ in
            if let it = item, it.kind == .live { epg.request(it) }
            nextHidden = false
            nextFired = false
            poke()
        }
        .onChange(of: player.time) { _ in
            // Netflix-style: when the card's timer fills, the next one starts
            if showNext && nextFill >= 1 && !nextFired && player.playing {
                nextFired = true
                store.playNext()
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSkip)
        .animation(.easeOut(duration: 0.3), value: showNext)
    }

    // MARK: Skip Intro / Next card

    /// The recap is playing (rather than the intro).
    private var skipRecap: Bool {
        guard let s = store.segments, s.hasRecap else { return false }
        return player.time >= s.recapStart - 0.5 && player.time < s.recapEnd - 1.5
    }

    private var showSkip: Bool {
        guard !live, let s = store.segments, s.hasIntro || s.hasRecap, scrub == nil else { return false }
        let t = player.time
        return skipRecap || (s.hasIntro && t >= s.introStart - 0.5 && t < s.introEnd - 1.5)
    }

    private func skipIntro() {
        guard let s = store.segments else { return }
        let recap = skipRecap
        player.seek(recap ? s.recapEnd : s.introEnd)
        store.show(recap ? "Skipped the recap" : "Skipped the intro")
        poke()
    }

    private static let countdown: Double = 10

    /// When the Next card shows: as the end credits start (if known), else 30 seconds before the end.
    private var cardAt: Double {
        let d = player.duration
        if let c = store.segments?.creditsStart, c > d * 0.7, c < d - 5 { return c } // earlier = a bad match
        return d - 30
    }

    private var showNext: Bool {
        guard !live, !nextHidden, !nextFired, scrub == nil, player.duration > 120, store.upNext != nil else { return false }
        return player.time >= cardAt && player.time < player.duration - 0.5
    }

    private var nextFill: Double { min(1, max(0, (player.time - cardAt) / Self.countdown)) }

    private var failure: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
            Text("Couldn't play this").font(.title2.bold())
            Text("The stream didn't start. It may be offline, or your account may be in use on another device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("Try Again") { player.retry() }.buttonStyle(.borderedProminent)
                Button("Close") { store.closePlayer() }
            }
            .controlSize(.large)
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                // Netflix-style: Back, Play From Beginning, Next, Episodes along the top left
                Button { store.closePlayer() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 22, weight: .semibold)).frame(width: 30, height: 30)
                }
                .help("Back (Esc)")
                if !live {
                    Button { player.seek(0); if !player.playing { player.togglePause() }; store.show("Playing from the beginning") } label: {
                        Image(systemName: "gobackward").font(.system(size: 21, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .help("Play From Beginning")
                    if store.upNext != nil {
                        Button { store.playNext() } label: {
                            Image(systemName: "forward.end").font(.system(size: 20, weight: .semibold)).frame(width: 30, height: 30)
                        }
                        .help(store.hasNextEpisode ? "Next Episode" : "Next in Queue")
                    }
                    if item?.kind == .episode { episodesMenu }
                }
                Spacer()
                // The title at the top right, while paused (or always for live channels)
                if live || !player.playing {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                        if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
                    }
                    .frame(maxWidth: 520, alignment: .trailing)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 34)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(spacing: 12) {
                if !live && player.duration > 0 {
                    HStack(spacing: 12) {
                        Text(Fmt.clock(scrub ?? player.time)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }),
                               in: 0...max(player.duration, 1),
                               onEditingChanged: { editing in
                                   if !editing, let s = scrub {
                                       player.seek(s)
                                       scrub = nil
                                   }
                               })
                        Text("-" + Fmt.clock(player.duration - (scrub ?? player.time))).font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
                HStack(spacing: 24) {
                    if live {
                        Button { store.step(-1) } label: { Image(systemName: "chevron.up") }.help("Previous channel (↑)")
                        Button { store.step(1) } label: { Image(systemName: "chevron.down") }.help("Next channel (↓)")
                    } else {
                        Button { player.jump(-10) } label: { Image(systemName: "gobackward.10") }.help("Back 10 seconds (←)")
                        Button { player.togglePause() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 30))
                        }
                        .help("Play / pause (Space)")
                        Button { player.jump(10) } label: { Image(systemName: "goforward.10") }.help("Forward 10 seconds (→)")
                        if store.upNext != nil {
                            Button { nextFired = true; store.playNext() } label: {
                                Label(store.hasNextEpisode ? "Next Episode" : "Next in Queue", systemImage: "forward.end.fill")
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    Spacer()
                    tracksMenus
                    HStack(spacing: 8) {
                        Button { player.muted.toggle() } label: {
                            Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .help("Mute (M)")
                        Slider(value: $player.volume, in: 0...200).frame(width: 110).controlSize(.small)
                    }
                    AirPlayButton(cast: cast)
                        .frame(width: 26, height: 26)
                        .help("Watch on Apple TV or an AirPlay TV")
                    CastMenu(cast: cast, browser: cast.browser)
                    Button { store.enterMini() } label: { Image(systemName: "pip.enter") }.help("Picture in picture (P)")
                    Button { toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen (F)")
                }
                .font(.system(size: 20))
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
            .padding(.top, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    /// Every episode of the series, by season, with the one playing ticked; choosing one plays it.
    private var episodesMenu: some View {
        let list = (store.session?.list ?? []).filter { $0.kind == .episode }
        let seasons = Array(Set(list.compactMap { $0.season })).sorted()
        return Menu {
            if seasons.count > 1 {
                ForEach(seasons, id: \.self) { sn in
                    Menu(sn == 0 ? "Specials" : "Season \(sn)") { episodeButtons(list.filter { $0.season == sn }, all: list) }
                }
            } else {
                episodeButtons(list, all: list)
            }
        } label: { Image(systemName: "rectangle.stack").font(.system(size: 20, weight: .semibold)) }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Episodes")
    }

    @ViewBuilder
    private func episodeButtons(_ eps: [Item], all: [Item]) -> some View {
        ForEach(eps) { ep in
            Button { if ep.id != item?.id { store.play(ep, list: all) } } label: {
                let name = (ep.episode.map { "\($0). " } ?? "") + ep.name + (store.isWatched(ep) && ep.id != item?.id ? "  ✓" : "")
                if ep.id == item?.id { Label(name, systemImage: "play.fill") } else { Text(name) }
            }
        }
    }

    private var tracksMenus: some View {
        HStack(spacing: 18) {
            let audio = player.audioTracks
            if audio.count > 1 {
                Menu {
                    ForEach(audio) { t in
                        Button { player.setAudio(t.id) } label: {
                            if t.id == player.currentAudio { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                } label: { Image(systemName: "waveform") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Audio language")
            }
            Menu {
                Section("Remembered for " + (item?.kind == .episode ? "this series" : live ? "this channel" : "this film")) {
                    ForEach(PictureMode.allCases) { m in
                        Button { store.setPicture(m) } label: {
                            if m == player.picture { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                        }
                    }
                }
            } label: { Image(systemName: "aspectratio") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Picture: fit, fill, stretch, 16:9 or 4:3 (or pinch the trackpad)")
            Menu {
                ForEach(player.subtitleTracks) { t in
                    Button { player.setSubtitle(t.id) } label: {
                        if t.id == player.currentSubtitle { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
                Divider()
                Button("Add Subtitle File…") { pickSubtitle() }
                if item?.kind == .episode {
                    Divider()
                    Text("Skip Intro: " + (store.segments?.status ?? "looking up this episode…"))
                }
            } label: { Image(systemName: "captions.bubble") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles")
        }
    }

    private func pickSubtitle() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["srt", "vtt", "ass", "ssa", "sub"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        p.message = "Choose a subtitle file"
        if p.runModal() == .OK, let u = p.url { player.addSubtitle(u) }
    }

    private func poke() {
        if !controls { withAnimation(.easeOut(duration: 0.15)) { controls = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.3)) { controls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var window: NSWindow? {
        MainWindow.window ?? NSApp.mainWindow ?? NSApp.keyWindow
    }

    private func toggleFullScreen() { window?.toggleFullScreen(nil) }

    private func installKeys() {
        removeKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard store.session != nil, !store.mini else { return e }
            if cast.isCasting { // playing on the TV: the keys control the TV
                if NSApp.keyWindow?.firstResponder is NSText || e.modifierFlags.contains(.command) { return e }
                switch e.keyCode {
                case 49: cast.togglePause(); return nil
                case 123: cast.jump(-10); return nil
                case 124: cast.jump(10); return nil
                case 53: cast.stop(resumeHere: true); return nil
                default: return e
                }
            }
            if e.window is NSPanel { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e } // typing somewhere
            if e.modifierFlags.contains(.command) { return e }
            switch e.keyCode {
            case 53: // Esc
                if window?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else { store.closePlayer() }
                return nil
            case 49: // Space
                if !live { player.togglePause() }
                poke()
                return nil
            case 123: // ←
                if !live { player.jump(-10) }
                poke()
                return nil
            case 124: // →
                if !live { player.jump(10) }
                poke()
                return nil
            case 126: // ↑
                if live { store.step(-1) } else { player.volume = min(200, player.volume + 10) }
                poke()
                return nil
            case 125: // ↓
                if live { store.step(1) } else { player.volume = max(0, player.volume - 10) }
                poke()
                return nil
            default:
                break
            }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "s" where showSkip:
                skipIntro()
                return nil
            case "n" where showNext:
                nextFired = true
                store.playNext()
                return nil
            case "f":
                toggleFullScreen()
                return nil
            case "m":
                player.muted.toggle()
                poke()
                return nil
            case "p":
                store.enterMini()
                return nil
            default:
                return e
            }
        }
    }

    private func removeKeys() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Netflix-style "Next Episode" card: the button fills up, then the next one plays.
private struct NextCard: View {
    let item: Item
    let label: String
    let fill: Double
    let play: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.kind == .episode ? (item.iconURL ?? item.posterURL) : item.posterURL, maxPixel: 400)
                .frame(width: 150, height: 84)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                Text(item.kind == .episode ? (item.episodeLabel.map { $0 + "  ·  " } ?? "") + item.name : item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: 230, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: play) {
                        ZStack(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle().fill(.white).frame(width: g.size.width * fill)
                            }
                            Label("Play Now", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .blendMode(.difference)
                                .padding(.horizontal, 14)
                        }
                        .frame(width: 130, height: 32)
                        .background(.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Button(action: close) {
                        Text("Hide")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(height: 32)
                            .padding(.horizontal, 12)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .compositingGroup()
    }
}
