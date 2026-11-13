import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
        .preferredColorScheme(.dark)
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
                Group {
                    switch store.page {
                    case .home: HomeView()
                    case .live: LiveView()
                    case .movies: VODView(kind: .movie).id("movies")
                    case .series: VODView(kind: .series).id("series")
                    case .search: SearchView()
                    case .downloads: DownloadsView(dl: store.downloads)
                    case .settings: SettingsView()
                    }
                }
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
                    .zIndex(1)
            }
        }
        .sheet(item: $store.detail) { it in
            DetailSheet(item: it)
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(store.downloads)
                .preferredColorScheme(.dark)
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
