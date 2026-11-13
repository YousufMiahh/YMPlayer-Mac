import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        Theme.applyAppearance(UserDefaults.standard.integer(forKey: "appearance"))
    }
}

@main
struct YMPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("YM Player", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(store.guide)
                .environmentObject(store.downloads)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Page.allCases) { p in
                    Button(p.title) { store.page = p }
                        .keyboardShortcut(KeyEquivalent(Character(String(Page.allCases.firstIndex(of: p).map { $0 + 1 } ?? 1))), modifiers: .command)
                }
                Divider()
                Button("What's New") { store.showWhatsNew() }
                Button("Show Tutorial") { store.showTour = true }
                Button("Check for Updates…") { Updater.shared.check(manual: true) }
                Button("Refresh Library") { store.refreshAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var epg: EpgStore

    var body: some View {
        Group {
            if store.current == nil {
                LoginView()
            } else {
                main
            }
        }
        .sheet(isPresented: Binding(get: { store.whatsNew != nil && store.session == nil && !store.showTour },
                                    set: { if !$0 { store.whatsNew = nil } })) {
            WhatsNewSheet(lines: store.whatsNew ?? [])
        }
        .sheet(isPresented: Binding(get: { store.showTour && store.current != nil && store.session == nil },
                                    set: { if !$0 { store.finishTour() } })) {
            TourSheet().environmentObject(store)
        }
        .overlay(alignment: .bottom) { UpdateBanner(updater: Updater.shared) }
        .task {
            // New version on GitHub? Once things have settled (not over the What's New or the tour)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if store.whatsNew == nil && !store.showTour && store.session == nil { Updater.shared.check(manual: false) }
        }
        .tint(Theme.accent)
        .background(WindowFinder())
    }

    private var playing: Bool { store.session != nil && !store.mini }

    private var main: some View {
        ZStack {
            NavigationSplitView {
                List(selection: Binding<Page?>(get: { store.page }, set: { if let p = $0 { store.page = p } })) {
                    ForEach(Page.allCases) { p in
                        Label(p.title, systemImage: p.icon).tag(p)
                    }
                    if store.session != nil && store.mini {
                        Section("Now Playing") {
                            Button { store.exitMini() } label: {
                                Label(store.session?.item.displayTitle ?? "", systemImage: "play.rectangle.fill").lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            } detail: {
                ZStack {
                    Group {
                        switch store.page {
                        case .home: HomeView()
                        case .live: LiveView()
                        case .movies: VODView(kind: .movie)
                        case .series: VODView(kind: .series)
                        case .search: SearchView()
                        case .downloads: DownloadsView(dl: store.downloads)
                        case .settings: SettingsView()
                        }
                    }
                    .id(store.page)
                    // As on the TV and phone: the new page fades in sliding from the side you moved to
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 36 * store.pageDir)),
                                            removal: .opacity.combined(with: .offset(x: -24 * store.pageDir))))
                }
                .animation(Theme.ease, value: store.page)
                .background(AmbientBackground(page: store.page))
                .overlay(alignment: .bottom) {
                    if let t = store.toast, !playing {
                        Text(t)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                }
            }
            .toolbar(playing ? .hidden : .visible, for: .windowToolbar)

            if playing {
                PlayerScreen(player: store.player)
                    .environment(\.colorScheme, .dark) // video: always dark, whatever the app's mode
                    .zIndex(1)
            }
        }
        .sheet(item: $store.detail) { it in
            DetailSheet(item: it)
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(store.downloads)
                .tint(Theme.accent)
        }
    }
}

enum MainWindow {
    static weak var window: NSWindow?
}

/// Remembers the main window so the player can take it full screen.
private struct WindowFinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            MainWindow.window = v.window
            v.window?.collectionBehavior.insert(.fullScreenPrimary)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if MainWindow.window == nil { DispatchQueue.main.async { MainWindow.window = nsView.window } }
    }
}

/// "What's New in YM Player 1.0.N", after an update.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lines: [String]

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.system(size: 24, weight: .bold))
                    Text("YM Player " + version).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(y: -2)
                            line(l)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            HStack {
                Spacer()
                Button("Got It") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    /// "Skip Intro: a button…" — the part before the colon in bold.
    private func line(_ l: String) -> Text {
        if let r = l.range(of: ": "), l.distance(from: l.startIndex, to: r.lowerBound) < 40 {
            return Text(String(l[..<r.lowerBound])).bold() + Text(": " + String(l[r.upperBound...]))
        }
        return Text(l)
    }
}
