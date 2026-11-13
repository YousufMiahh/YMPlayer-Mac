import SwiftUI

struct LoginView: View {
    var isSheet = false
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(isSheet ? "Add an Account" : "Welcome to YM Player").font(.system(size: 28, weight: .bold))
            Text("Sign in with the Xtream Codes details from your provider.").foregroundStyle(.secondary)
            VStack(spacing: 10) {
                TextField("Server address, e.g. http://example.com:8080", text: $server)
                TextField("Username", text: $user)
                SecureField("Password", text: $pass)
                TextField("Name for this account (optional)", text: $name)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .frame(width: 400)
            .disableAutocorrection(true)
            if let e = error {
                Text(e).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            HStack(spacing: 12) {
                if isSheet { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(action: signIn) {
                    Group {
                        if busy { ProgressView().controlSize(.small) } else { Text("Sign In") }
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || pass.isEmpty)
            }
            if !isSheet {
                Text("Developed by Yousuf Miah").font(.caption).foregroundStyle(.tertiary).padding(.top, 20)
            }
        }
        .padding(40)
        .frame(minWidth: 540, minHeight: 540)
    }

    private func signIn() {
        busy = true
        error = nil
        let a = Account(name: name, server: XtreamAPI.normalize(server), user: user.trimmingCharacters(in: .whitespaces), pass: pass)
        Task {
            do {
                _ = try await XtreamAPI(a).login()
                store.addAccount(a)
                if isSheet { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dl: Downloader
    @AppStorage("liveFormat") private var liveFormat = "ts"
    @AppStorage("previewMode") private var previewMode = 2
    @State private var showAdd = false
    @State private var showTags = false
    @State private var showHidden = false

    private var tagsLabel: String {
        let n = store.data.hiddenTags.count
        return n == 0 ? "Showing everything" : "\(n) hidden"
    }

    var body: some View {
        Form {
            Section("Account") {
                if let i = store.accountInfo { Text(i).foregroundStyle(.secondary) }
                ForEach(store.accounts) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.label).fontWeight(.medium)
                            Text(a.server).font(.caption).foregroundStyle(.secondary)
                        }
                        if a.id == store.currentId {
                            Text("Signed in").font(.caption.bold())
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.35), in: Capsule())
                        }
                        Spacer()
                        if a.id != store.currentId { Button("Switch") { store.switchTo(a.id) } }
                        Button(role: .destructive) { store.removeAccount(a.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove this account")
                    }
                }
                Button("Add Account…") { showAdd = true }
            }

            Section("Playback") {
                Picker("Live stream format", selection: $liveFormat) {
                    Text("MPEG-TS (recommended)").tag("ts")
                    Text("HLS (m3u8)").tag("m3u8")
                }
                Picker("Live preview in the channel list", selection: $previewMode) {
                    Text("Off").tag(0)
                    Text("Muted").tag(1)
                    Text("With sound").tag(2)
                }
                Text("Player keys: Space play/pause · ← → skip 10s · ↑ ↓ change channel (live) or volume · F full screen · P picture in picture · M mute · Esc back")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hide What You Don't Watch") {
                LabeledContent("Countries & languages") {
                    Button(tagsLabel) { showTags = true }
                }
                LabeledContent("Hidden categories") {
                    Button("\(store.hiddenCategoryList().count) hidden") { showHidden = true }
                }
                Text("Right-click a category in Live TV, Movies or Series to favourite, rename or hide it. Things in categories you hide yourself still turn up in search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Downloads") {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text(dl.folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                        if dl.folder != Downloader.defaultFolder {
                            Button("Default") { dl.folder = Downloader.defaultFolder }
                        }
                    }
                }
            }

            Section("Library") {
                Button("Refresh Channels, Movies & Series") { store.refreshAll() }
                Button("Clear Continue Watching") { store.data.progress = [:] }
                Button("Clear Recently Watched Channels") { store.data.recentChannels = [] }
                Button("Clear Your Queue") { store.data.queue = [] }
                Button("Clear Watched Marks") { store.data.watched = [] }
                if !store.data.catNames.isEmpty {
                    Button("Restore Original Category Names") { store.data.catNames = [:] }
                }
            }

            Section("About") {
                LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                               + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")")
                Text("Developed by Yousuf Miah").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showAdd) { LoginView(isSheet: true).environmentObject(store) }
        .sheet(isPresented: $showTags) { TagsSheet().environmentObject(store) }
        .sheet(isPresented: $showHidden) { HiddenSheet().environmentObject(store) }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose where YM Player saves downloads"
        if p.runModal() == .OK, let u = p.url { dl.folder = u }
    }
}

struct TagsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [TagCount] = []

    var body: some View {
        let allShown = tags.allSatisfy { !store.data.hiddenTags.contains($0.tag) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Countries & Languages").font(.system(size: 22, weight: .bold))
            Text("Untick what you don't watch. Categories for those countries, languages and writing systems disappear everywhere, including search.")
                .foregroundStyle(.secondary)
            if tags.isEmpty {
                EmptyState(icon: "globe", title: "Nothing to filter yet", message: "Your provider's categories aren't loaded yet, or they don't have country tags.")
            } else {
                List {
                    ForEach(tags, id: \.tag) { t in
                        Toggle(isOn: Binding(get: { !store.data.hiddenTags.contains(t.tag) }, set: { store.setTag(t.tag, hidden: !$0) })) {
                            HStack {
                                Text(Filters.tagName(t.tag))
                                if !t.tag.hasPrefix("#") && Filters.tagName(t.tag) != t.tag { Text(t.tag).foregroundStyle(.secondary) }
                                Spacer()
                                Text("\(t.count) categor\(t.count == 1 ? "y" : "ies")").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            HStack {
                Button(allShown ? "Unselect All" : "Select All") { store.setTags(tags.map { $0.tag }, hidden: allShown) }
                    .disabled(tags.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 640)
        .onAppear { tags = store.detectedTags() }
    }
}

struct HiddenSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(Kind, Category)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden Categories").font(.system(size: 22, weight: .bold))
            Text("Everything hidden, by you or by your countries & languages choices. Untick one to bring it back.")
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                EmptyState(icon: "eye", title: "Nothing is hidden")
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        Toggle(isOn: Binding(get: { store.isHidden(r.0, r.1) }, set: { store.setHidden(r.0, r.1, $0) })) {
                            HStack {
                                Text(r.1.name)
                                Spacer()
                                Text(r.0.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 640)
        .onAppear { rows = store.hiddenCategoryList() }
    }
}
