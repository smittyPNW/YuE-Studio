import SwiftUI

struct StudioRoot: View {
    @EnvironmentObject var backend: Backend
    @Bindable var library: StudioLibrary
    @Bindable var player: StudioPlayer
    @Bindable var mastering: MasteringController
    @Bindable var editor: EditController
    @AppStorage("workspace") private var workspace = "create"
    @AppStorage("appearance") private var appearance = "dark"
    @State private var showImport = false
    var startServices = true
    var selected: Song? { backend.songs.first { $0.id == library.state.selected } }
    var playingSong: Song? { backend.songs.first { $0.id == player.songID } }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspace == "edit" {
                EditWorkspace(model: editor, master: { url, title in
                    workspace = "master"; mastering.importFile(url, title: title, backend: backend)
                }).frame(maxHeight: .infinity)
            } else if workspace == "master" {
                MasteringWorkspace(model: mastering, editAudio: { url, title in
                    workspace = "edit"; editor.importAudio(url, title: title)
                }).frame(maxHeight: .infinity)
            } else {
            HStack(spacing: 0) {
                LibrarySidebar(library: library, player: player)
                Divider()
                SongWorkspace(library: library, player: player, song: selected, masterSong: { song in
                    workspace = "master"; mastering.importFile(URL(fileURLWithPath: song.path), title: library.title(song), backend: backend)
                }, editSong: { song in
                    workspace = "edit"; editor.importAudio(URL(fileURLWithPath: song.path), title: library.title(song))
                }).frame(maxWidth: .infinity)
                if library.showInspector { Divider(); StudioInspector(library: library) }
            }.frame(maxHeight: .infinity)
            }
            if library.showLog {
                Divider()
                VStack(spacing: 6) {
                    HStack { Text("Diagnostics").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Copy log") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(backend.log.map { "\($0.time) \($0.message)" }.joined(separator: "\n"), forType: .string) }; Button("Close", systemImage: "xmark") { library.showLog = false }.labelStyle(.iconOnly) }.controlSize(.small)
                    LogTextView(lines: backend.log)
                }.padding(12).frame(height: 140).background(StudioTheme.sidebar)
            }
            Divider()
            if workspace == "edit" { EditTransportBar(model: editor) }
            else { PlayerBar(player: workspace == "master" ? mastering.player : player, song: workspace == "master" ? nil : playingSong) }
        }
        .background(StudioTheme.canvas).foregroundStyle(StudioTheme.ink).tint(StudioTheme.accent)
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "light" ? .light : .dark))
        .frame(minWidth: workspace == "create" && library.showInspector ? 1170 : 1060, minHeight: 720)
        .task {
            guard startServices else { return }
            editor.backend = backend
            backend.rescan(); library.register(backend.songs)
            if library.state.selected == nil, library.state.composer.style.isEmpty, let first = backend.songs.first(where: { $0.status == .ready }) { library.select(first) }
            if workspace == "create" { loadSelected(); backend.start() } else if workspace == "master" { mastering.audition() } else { editor.activate() }
        }
        .onChange(of: workspace) { _, mode in
            player.pause(); mastering.player.pause(); editor.transport.pause()
            if mode == "create" { backend.start(); loadSelected() } else if mode == "master", !mastering.busy { mastering.audition() } else if mode == "edit" { editor.activate() }
        }
        .onChange(of: editor.busy) { _, busy in if !busy && workspace == "create" { backend.start() } }
        .onChange(of: mastering.busy) { _, busy in if !busy && workspace == "create" { backend.start() } }
        .onChange(of: library.state.composer) { _, _ in library.changed() }
        .onChange(of: library.state.selected) { _, _ in loadSelected() }
        .onChange(of: backend.songs.map(\.id)) { _, _ in library.register(backend.songs) }
        .onChange(of: backend.startedPath) { _, value in
            guard let value, let song = backend.songs.first(where: { $0.id == value }) else { return }
            library.register(backend.songs)
            library.select(song)
        }
        .onChange(of: backend.completedPath) { _, value in
            if let value, value == library.state.selected, let song = selected { player.invalidate(value); player.load(song, title: library.title(song)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in backend.rescan(); library.register(backend.songs) }
        .sheet(isPresented: $showImport) { importSheet }
        .sheet(isPresented: $library.showScore) { scoreSheet }
        .alert("Studio", isPresented: Binding(get: { library.error != nil || backend.lastError != nil || player.error != nil }, set: { if !$0 { library.error = nil; backend.lastError = nil; player.error = nil } })) {
            Button("OK") { library.error = nil; backend.lastError = nil; player.error = nil }
        } message: { Text(library.error ?? backend.lastError ?? player.error ?? "") }
        .alert("Studio", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) { Button("OK") { library.notice = nil } } message: { Text(library.notice ?? "") }
    }
    private func loadSelected() { if let song = selected, song.status == .ready { player.load(song, title: library.title(song)) } }
    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSImage(named: NSImage.Name("AppIcon")) { Image(nsImage: icon).resizable().frame(width: 30, height: 30).accessibilityHidden(true) }
            Text("YuE Studio").font(.title3).fontWeight(.semibold)
            Picker("Workspace", selection: $workspace) {
                Text("Create").tag("create")
                Text("Edit").tag("edit")
                Text("Master").tag("master")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 245).padding(.leading, 18)
            Spacer()
            if backend.busy { Label("Creating", systemImage: "waveform").font(.caption).foregroundStyle(StudioTheme.highlight) }
            if workspace == "create" { Button("Import prompt", systemImage: "doc.on.clipboard") { showImport = true }.buttonStyle(.plain).help("Import the two blocks from the songwriter skill")
            } else if workspace == "edit" { Button("Open audio", systemImage: "square.and.arrow.down") { editor.chooseFile() }.buttonStyle(.plain).disabled(editor.unavailable)
            } else { Button("Import audio", systemImage: "square.and.arrow.down") { mastering.chooseFile(backend: backend) }.buttonStyle(.plain).disabled(mastering.busy || backend.busy) }
            Divider().frame(height: 18)
            Menu {
                Picker("Appearance", selection: $appearance) { Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") }
                Toggle("Show diagnostics", isOn: $library.showLog)
                Button("Refresh library") { backend.rescan(); library.register(backend.songs) }
            } label: { Image(systemName: "circle.lefthalf.filled").accessibilityLabel("Appearance and diagnostics") }.menuStyle(.borderlessButton).fixedSize()
            if workspace == "create" { Button("Song settings", systemImage: "slider.horizontal.3") { library.showInspector.toggle() }.labelStyle(.iconOnly).buttonStyle(.plain).help("Song settings") }
        }.padding(.horizontal, 22).frame(height: 58).background(StudioTheme.sidebar)
    }
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring your idea into the studio").font(.title2).fontWeight(.semibold)
            Text("Paste the songwriter response with its two fenced text blocks: musical style, then lyrics. Importing replaces the current editor text.").foregroundStyle(.secondary)
            TextEditor(text: $library.importText).font(.body).frame(minHeight: 260).accessibilityLabel("Songwriter response")
            HStack { Button("Cancel") { showImport = false }; Spacer(); Button("Import style & lyrics") { library.importPrompt(); if library.error == nil { showImport = false } }.buttonStyle(.borderedProminent).disabled(library.importText.isEmpty) }
        }.padding(26).frame(width: 570)
    }
    private var scoreSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Composition score").font(.title2); Spacer(); Button("Done") { library.showScore = false } }
            Text("The saved ABC score describes the composition. Copy it into Custom score in settings to create an edited version.").foregroundStyle(.secondary)
            ScrollView { Text(selected?.score ?? "No score available").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 370)
            Button("Copy score") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected?.score ?? "", forType: .string) }
        }.padding(24).frame(width: 650)
    }
}
