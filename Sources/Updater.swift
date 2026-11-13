import SwiftUI
import AppKit

/// Updates straight from the GitHub releases, like the TV and phone apps: on launch (at most every
/// few hours) it asks GitHub for the newest release, and if it's newer offers to install it. The new
/// app replaces this one and reopens. Only proper releases, never test builds.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "YousufMiahh/YMPlayer-Mac"

    struct Release {
        let number: Int
        let name: String
        let notes: String
        let dmg: URL
        let page: URL?
    }

    /// 0…1 while downloading / installing, nil otherwise (shown at the bottom of the window).
    @Published var progress: Double?
    @Published var status = ""

    private var busy = false
    private var observation: NSKeyValueObservation?

    static var installedNumber: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// - Parameter manual: from Settings / the menu: always check, and say so if there's nothing new.
    func check(manual: Bool) {
        guard !busy else { return }
        let d = UserDefaults.standard
        if !manual, Date().timeIntervalSince1970 - d.double(forKey: "updateChecked") < 3 * 3600 { return }
        busy = true
        Task {
            defer { busy = false }
            guard let r = await latest() else {
                if manual { alert("Couldn't check for updates", "Check your internet connection and try again.") }
                return
            }
            d.set(Date().timeIntervalSince1970, forKey: "updateChecked")
            if r.number <= Updater.installedNumber {
                if manual { alert("You're up to date", "YM Player 1.0.\(Updater.installedNumber) is the newest version.") }
                return
            }
            if !manual, d.integer(forKey: "updateLater") == r.number,
               Date().timeIntervalSince1970 - d.double(forKey: "updateLaterAt") < 24 * 3600 { return } // "Later" today
            offer(r)
        }
    }

    private func latest() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("YMPlayer-Updater", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let n = Int(tag.split(separator: ".").last ?? ""),
              let assets = o["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
              let dmgURL = URL(string: dmg) else { return nil }
        let notes = ((o["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(?m)^- ", with: "•  ", options: .regularExpression)
        return Release(number: n, name: "YM Player " + tag.replacingOccurrences(of: "v", with: ""), notes: notes, dmg: dmgURL,
                       page: (o["html_url"] as? String).flatMap(URL.init(string:)))
    }

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Update available"
        var text = r.name + " is ready to install. Your accounts, favourites and history stay as they are."
        if !r.notes.isEmpty { text += "\n\nWhat's new:\n" + (r.notes.count > 700 ? String(r.notes.prefix(700)) + "…" : r.notes) }
        a.informativeText = text
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            install(r)
        } else {
            UserDefaults.standard.set(r.number, forKey: "updateLater")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLaterAt")
        }
    }

    // MARK: install

    private func install(_ r: Release) {
        busy = true
        progress = 0
        status = "Downloading " + r.name + "…"
        let task = URLSession.shared.downloadTask(with: r.dmg) { [weak self] tmp, resp, err in
            // The file is deleted when this returns: keep it
            var dmg: URL?
            if let tmp = tmp, err == nil, ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("YMPlayer-update-\(r.number).dmg")
                try? FileManager.default.removeItem(at: keep)
                if (try? FileManager.default.moveItem(at: tmp, to: keep)) != nil { dmg = keep }
            }
            Task { @MainActor in self?.downloaded(r, dmg) }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in if self?.progress != nil { self?.progress = f * 0.9 } }
        }
        task.resume()
    }

    private func downloaded(_ r: Release, _ dmg: URL?) {
        observation = nil
        guard let dmg = dmg else { return fail("The download didn't finish. Check your connection and try again.", r) }
        status = "Installing " + r.name + "…"
        progress = 0.92
        let dest = Bundle.main.bundleURL
        Task.detached(priority: .userInitiated) {
            let result = Updater.prepare(dmg: dmg, replacing: dest)
            await MainActor.run {
                switch result {
                case .success(let newApp): self.relaunch(into: newApp, replacing: dest)
                case .failure(let why):
                    // Can't replace it in place (e.g. run from the disk image): open the download to drag across
                    NSWorkspace.shared.open(dmg)
                    self.fail(why + "\n\nThe new version is open in Finder: drag YM Player into Applications to replace this one.", r)
                }
            }
        }
    }

    enum Prepared { case success(URL), failure(String) }

    /// Mounts the disk image and copies the new app next to a temporary folder. Background thread.
    nonisolated static func prepare(dmg: URL, replacing dest: URL) -> Prepared {
        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()
        if dest.path.contains("/AppTranslocation/") || !fm.isWritableFile(atPath: parent.path) {
            return .failure("YM Player can't replace itself where it is now.")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("YMPlayer-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            return .failure("Couldn't open the downloaded update.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else {
            return .failure("The update didn't contain the app.")
        }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else { return .failure("Couldn't copy the update.") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return .success(staged)
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A tiny script swaps the apps once this one has quit, then opens the new one.
    private func relaunch(into newApp: URL, replacing dest: URL) {
        progress = 1
        status = "Restarting…"
        let pid = ProcessInfo.processInfo.processIdentifier
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(q(dest.path)) && mv \(q(newApp.path)) \(q(dest.path)) && open \(q(dest.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            fail("Couldn't restart into the new version.", nil)
        }
    }

    private func fail(_ message: String, _ r: Release?) {
        progress = nil
        status = ""
        busy = false
        alert("Update didn't install", message)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// "Downloading YM Player 1.0.12… 45%" along the bottom of the window.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let p = updater.progress {
            HStack(spacing: 12) {
                ProgressView(value: p).frame(width: 160)
                Text(updater.status + "  \(Int(p * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.opacity)
        }
    }
}
