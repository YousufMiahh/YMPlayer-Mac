import SwiftUI
import AppKit
import VLCKit

/// The view VLC draws into. One per player; it's moved between the full-window player, the
/// picture-in-picture window and the live preview as needed.
final class VideoHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct VideoSurface: NSViewRepresentable {
    let video: NSView

    func makeNSView(context: Context) -> NSView {
        let c = NSView()
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.black.cgColor
        VideoSurface.attach(video, to: c)
        return c
    }

    func updateNSView(_ c: NSView, context: Context) {
        if video.superview !== c { VideoSurface.attach(video, to: c) }
    }

    static func attach(_ v: NSView, to c: NSView) {
        v.removeFromSuperview()
        v.frame = c.bounds
        v.autoresizingMask = [.width, .height]
        c.addSubview(v)
    }
}

struct Track: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// libVLC playback, the same engine as the TV app's live preview: plays the TS / MKV / HLS
/// streams Xtream providers send, with all audio and subtitle tracks.
@MainActor
final class PlayerModel: ObservableObject {
    let vlc = VLCMediaPlayer()
    let video = VideoHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = false
    @Published var failed = false
    @Published var ended = false
    @Published var volume: Double = (UserDefaults.standard.object(forKey: "volume") as? Double) ?? 100 {
        didSet {
            applyVolume()
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    @Published var muted = false { didSet { applyVolume() } }

    private(set) var url: URL?
    private(set) var isLive = false
    private var timer: Timer?
    private var retries = 0
    private var lastRetry = Date.distantPast

    init() {
        vlc.drawable = video
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func play(url: URL, start: Double = 0, live: Bool) {
        self.url = url
        isLive = live
        retries = 0
        open(url, start: start)
    }

    private func open(_ url: URL, start: Double) {
        let m = VLCMedia(url: url)
        m.addOption(":http-user-agent=\(XtreamAPI.userAgent)")
        m.addOption(":network-caching=\(isLive ? 2000 : 4000)")
        m.addOption(":http-reconnect")
        if start > 1 { m.addOption(":start-time=\(Int(start))") }
        vlc.media = m
        failed = false
        ended = false
        buffering = true
        time = max(0, start)
        duration = 0
        vlc.play()
        applyVolume()
    }

    func retry() {
        guard let u = url else { return }
        open(u, start: isLive ? 0 : time)
    }

    func stop() {
        url = nil
        vlc.stop()
        playing = false
        buffering = false
        failed = false
        ended = false
    }

    func togglePause() {
        if vlc.isPlaying { vlc.pause() } else { vlc.play() }
    }

    func seek(_ seconds: Double) {
        var s = max(0, seconds)
        if duration > 0 { s = min(s, duration - 2) }
        vlc.time = VLCTime(int: Int32(s * 1000))
        time = s
    }

    func jump(_ d: Double) { seek(time + d) }

    private func applyVolume() {
        let a: VLCAudio? = vlc.audio
        a?.volume = Int32(muted ? 0 : volume)
    }

    private func tick() {
        guard url != nil else { return }
        let st = vlc.state
        let t = Double(vlc.time.intValue) / 1000
        let m: VLCMedia? = vlc.media
        let len = Double(m?.length.intValue ?? 0) / 1000
        if abs(t - time) > 0.3 && t >= 0 { time = t }
        if len > 0 && abs(len - duration) > 0.5 { duration = len }
        let p = vlc.isPlaying
        if p != playing { playing = p }
        let b = !p && (st == .opening || st == .buffering)
        if b != buffering { buffering = b }

        // Live streams sometimes drop: reconnect quietly a few times before giving up
        if isLive && (st == .ended || st == .error) && retries < 5 && Date().timeIntervalSince(lastRetry) > 3 {
            retries += 1
            lastRetry = Date()
            retry()
            return
        }
        let f = st == .error
        if f != failed { failed = f }
        let e = st == .ended && !isLive
        if e != ended { ended = e }
        if p { retries = 0 }
    }

    // MARK: tracks

    var audioTracks: [Track] { tracks(vlc.audioTrackIndexes, vlc.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(vlc.videoSubTitlesIndexes, vlc.videoSubTitlesNames) }

    var currentAudio: Int32 { vlc.currentAudioTrackIndex }
    var currentSubtitle: Int32 { vlc.currentVideoSubTitleIndex }

    func setAudio(_ id: Int32) {
        vlc.currentAudioTrackIndex = id
        objectWillChange.send()
    }

    func setSubtitle(_ id: Int32) {
        vlc.currentVideoSubTitleIndex = id
        objectWillChange.send()
    }

    func addSubtitle(_ url: URL) {
        _ = vlc.addPlaybackSlave(url, type: .subtitle, enforce: true)
        objectWillChange.send()
    }

    private func tracks(_ ids: [Any]?, _ names: [Any]?) -> [Track] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { "\($0)" }
        return zip(i, n).map { Track(id: $0.0, name: $0.1) }
    }
}

/// Picture in picture: a small always-on-top window you can drag anywhere, over other apps too.
@MainActor
final class MiniWindow: NSObject, NSWindowDelegate {
    static let shared = MiniWindow()
    private var panel: NSPanel?
    private weak var store: AppStore?
    private var closingOurselves = false

    func show(store: AppStore) {
        self.store = store
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentAspectRatio = NSSize(width: 16, height: 9)
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .black
            p.delegate = self
            p.contentView = NSHostingView(rootView: MiniPlayerView(player: store.player).environmentObject(store))
            if let s = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: s.maxX - 500, y: s.minY + 24))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        closingOurselves = true
        p.contentView = nil
        p.close()
        closingOurselves = false
    }

    func windowWillClose(_ notification: Notification) {
        if closingOurselves { return }
        panel?.contentView = nil
        panel = nil
        store?.closePlayer()
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var player: PlayerModel
    @State private var hover = false

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(video: player.video)
            if player.buffering { ProgressView().controlSize(.small) }
            if hover {
                ZStack {
                    Color.black.opacity(0.35)
                    HStack(spacing: 26) {
                        Button { store.exitMini() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Back to the full player")
                        Button { player.togglePause() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                        Button { store.closePlayer() } label: { Image(systemName: "xmark") }
                            .help("Stop")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
        }
        .onHover { hover = $0 }
        .ignoresSafeArea()
    }
}
