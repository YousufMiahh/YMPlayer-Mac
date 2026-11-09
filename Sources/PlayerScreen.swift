import SwiftUI
import UniformTypeIdentifiers

/// The full-window player.
struct PlayerScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore
    @ObservedObject var player: PlayerModel
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var monitor: Any?

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
            if player.buffering && !player.failed {
                ProgressView().controlSize(.large)
            }
            if player.failed { failure }
            if controls || (!player.playing && !player.buffering) {
                overlay.transition(.opacity)
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
        .onChange(of: player.ended) { e in if e { store.playbackEnded() } }
        .onChange(of: store.session?.item.id) { _ in
            if let it = item, it.kind == .live { epg.request(it) }
            poke()
        }
    }

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
            HStack(spacing: 16) {
                Button { store.closePlayer() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold)).frame(width: 30, height: 30)
                }
                .help("Back (Esc)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                Spacer()
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
                        if store.hasNextEpisode {
                            Button { store.step(1) } label: { Label("Next Episode", systemImage: "forward.end.fill") }
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
                ForEach(player.subtitleTracks) { t in
                    Button { player.setSubtitle(t.id) } label: {
                        if t.id == player.currentSubtitle { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
                Divider()
                Button("Add Subtitle File…") { pickSubtitle() }
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
