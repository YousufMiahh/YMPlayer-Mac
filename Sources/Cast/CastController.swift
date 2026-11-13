import SwiftUI
import AVFoundation
import AVKit

/// Watching on a TV: AirPlay (Apple TV and AirPlay TVs) now, Chromecast later. The Mac's own
/// player pauses while the TV plays; when you stop, it carries on here from where the TV got to.
@MainActor
final class CastController: NSObject, ObservableObject {
    enum Mode: Equatable { case none, airplay }

    @Published private(set) var mode: Mode = .none
    @Published private(set) var preparing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var message: String?

    weak var store: AppStore?

    /// The player AirPlay sends to the TV (never shown on the Mac).
    let avPlayer: AVPlayer = {
        let p = AVPlayer()
        p.allowsExternalPlayback = true
        p.actionAtItemEnd = .pause
        return p
    }()

    private var converter: Converter?
    private var offset: Double = 0          // a converted stream starts here
    private var item: Item?
    private var live = false
    private var timeObserver: Any?
    private var externalObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var pickerOpen = false

    override init() {
        super.init()
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }
        externalObs = avPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let on = p.isExternalPlaybackActive
            Task { @MainActor in self?.externalChanged(on) }
        }
        rateObs = avPlayer.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let r = p.rate
            Task { @MainActor in self?.playing = r > 0 }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.converter?.stop() }
        }
    }

    var isCasting: Bool { mode != .none }
    var canSeek: Bool { !live }

    // MARK: AirPlay

    /// The AirPlay list is opening: get the stream ready for the TV in the background.
    func pickerWillOpen() {
        pickerOpen = true
        guard mode == .none, let store = store, let s = store.session, let api = store.api else { return }
        let it = s.item
        if item?.id == it.id, avPlayer.currentItem != nil { return } // already prepared
        teardown()
        item = it
        live = it.kind == .live
        let at = live ? 0 : store.player.time
        duration = live ? 0 : store.player.duration
        time = at
        let ua = XtreamAPI.userAgent
        // Live channels as HLS, and MP4 films, the TV can fetch straight from the provider
        let ext = (it.ext ?? "mp4").lowercased()
        if live || ["mp4", "m4v", "mov"].contains(ext) || !Converter.available {
            guard let url = live ? api.playURL(it, liveFormat: "m3u8") : api.playURL(it, liveFormat: "ts") else { return }
            offset = 0
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPUserAgentKey": ua])
            avPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if at > 1 { avPlayer.seek(to: CMTime(seconds: at, preferredTimescale: 600)) }
            return
        }
        // Anything else: the Mac converts it while the TV plays it
        guard let src = api.playURL(it, liveFormat: "ts") else { return }
        convert(src, from: at, userAgent: ua)
    }

    private func convert(_ src: URL, from at: Double, userAgent: String) {
        converter?.stop()
        let c = Converter(startAt: at)
        converter = c
        offset = at
        preparing = true
        guard let base = LocalServer.shared.publish(c.folder) else {
            preparing = false
            message = "Couldn't share the video on your network. Check the Mac is on Wi-Fi."
            return
        }
        avPlayer.replaceCurrentItem(with: AVPlayerItem(url: base.appendingPathComponent("index.m3u8")))
        Task.detached(priority: .userInitiated) {
            let ok = c.start(input: src, userAgent: userAgent, live: false)
            await MainActor.run {
                if !ok { self.message = "Couldn't start converting this video for the TV." }
            }
            // Ready when the first pieces exist (the server also waits for them)
            for _ in 0..<120 {
                if c.isReady || !c.isRunning { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run { if self.converter === c { self.preparing = false } }
        }
    }

    func pickerDidClose() {
        pickerOpen = false
        // Nothing chosen: let go of what we prepared (a moment later, in case the TV is still connecting)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if mode == .none && !pickerOpen && !avPlayer.isExternalPlaybackActive { teardown() }
        }
    }

    private func externalChanged(_ on: Bool) {
        if on && mode == .none {
            guard let store = store else { return }
            mode = .airplay
            message = nil
            if store.player.playing { store.player.togglePause() } // the Mac stops; the TV takes over
            avPlayer.play()
        } else if !on && mode == .airplay {
            stop(resumeHere: true) // AirPlay turned off (here or from the TV)
        }
    }

    // MARK: controls

    func togglePause() {
        if avPlayer.rate > 0 { avPlayer.pause() } else { avPlayer.play() }
    }

    func seek(to t: Double) {
        guard !live else { return }
        let target = max(0, duration > 0 ? min(t, duration - 5) : t)
        time = target
        if let c = converter, let store = store, let it = item, let api = store.api, let src = api.playURL(it, liveFormat: "ts") {
            // Within what's converted already: just jump; further on: convert from there
            let local = target - offset
            let have = avPlayer.currentItem?.seekableTimeRanges.last.map { $0.timeRangeValue.end.seconds } ?? 0
            if local >= 0 && local <= have {
                avPlayer.seek(to: CMTime(seconds: local, preferredTimescale: 600))
            } else {
                _ = c
                convert(src, from: target, userAgent: XtreamAPI.userAgent)
                avPlayer.play()
            }
        } else {
            avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
    }

    func jump(_ d: Double) { seek(to: time + d) }

    /// Stop watching on the TV. `resumeHere`: carry on in the Mac's player from the same place.
    func stop(resumeHere: Bool) {
        let at = time
        let wasLive = live
        let was = mode
        mode = .none
        avPlayer.pause()
        teardown()
        guard was != .none, let store = store else { return }
        if resumeHere, store.session != nil {
            if wasLive { store.player.retry() } else {
                store.player.seek(at)
                if !store.player.playing { store.player.togglePause() }
            }
        }
    }

    private func teardown() {
        avPlayer.replaceCurrentItem(with: nil)
        converter?.stop()
        converter = nil
        item = nil
        preparing = false
        offset = 0
    }

    private func tick(_ t: CMTime) {
        guard mode != .none else { return }
        let s = t.seconds
        if s.isFinite { time = offset + s }
        if duration <= 0, let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        // Finished on the TV
        if !live, duration > 60, time >= duration - 2, avPlayer.rate == 0, !preparing {
            store?.castFinished()
        }
    }
}

/// Apple's AirPlay button, wired to the cast player.
struct AirPlayButton: NSViewRepresentable {
    @ObservedObject var cast: CastController

    func makeCoordinator() -> Coordinator { Coordinator(cast) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = cast.avPlayer
        v.delegate = context.coordinator
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1), for: .active)
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {}

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let cast: CastController
        init(_ c: CastController) { cast = c }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in cast.pickerWillOpen() }
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in cast.pickerDidClose() }
        }
    }
}

/// Shown in place of the picture while it plays on the TV.
struct CastingView: View {
    @ObservedObject var cast: CastController
    let title: String
    let subtitle: String?
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "airplayvideo").font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accent)
            Text(cast.preparing ? "Getting it ready for your TV…" : "Playing on your TV").font(.system(size: 22, weight: .bold))
            VStack(spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            if cast.preparing { ProgressView().controlSize(.small) }
            if cast.canSeek && cast.duration > 0 {
                HStack(spacing: 12) {
                    Text(Fmt.clock(scrub ?? cast.time)).monospacedDigit()
                    Slider(value: Binding(get: { scrub ?? cast.time }, set: { scrub = $0 }), in: 0...max(cast.duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let s = scrub { cast.seek(to: s); scrub = nil }
                           })
                    Text("-" + Fmt.clock(max(0, cast.duration - (scrub ?? cast.time)))).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 560)
            }
            HStack(spacing: 30) {
                if cast.canSeek { Button { cast.jump(-10) } label: { Image(systemName: "gobackward.10") } }
                Button { cast.togglePause() } label: { Image(systemName: cast.playing ? "pause.fill" : "play.fill").font(.system(size: 30)) }
                if cast.canSeek { Button { cast.jump(10) } label: { Image(systemName: "goforward.10") } }
            }
            .font(.system(size: 22))
            Button { cast.stop(resumeHere: true) } label: {
                Label("Stop Watching on TV", systemImage: "xmark.circle").padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let m = cast.message { Text(m).font(.callout).foregroundStyle(.red) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
