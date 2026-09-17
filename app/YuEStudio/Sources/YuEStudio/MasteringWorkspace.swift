import SwiftUI
import UniformTypeIdentifiers

// Extend the approved orange-and-ivory studio. Studio Mastering iOS supplies the task order:
// choose a track, choose a style or Smart Master, compare, then export.
// Detailed controls remain opt-in; neither opening this workspace nor finishing
// a generated song automatically processes its audio.
struct MasteringWorkspace: View {
    @Bindable var model: MasteringController
    @EnvironmentObject private var backend: Backend
    @State private var dropTarget = false
    @State private var pendingDelete: MasterSession?
    @State private var confirmDelete = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group { if model.session != nil { editor } else { empty } }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard !model.busy, !backend.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.importFile(url, title: nil, backend: backend) } } }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [8,5])).padding(8).allowsHitTesting(false) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.restoreReturnedSessions() }
        .alert("Move mastering session to Trash?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let item = pendingDelete { model.moveToTrash(item, backend: backend) }
                pendingDelete = nil
            }
        } message: { Text("“\(pendingDelete?.title ?? "This session")”, its working copy and saved masters will move to the Mac Trash. Your imported original and exported copies stay where they are. Use Put Back in Finder to restore it.") }
        .onChange(of: model.parameters) { _, _ in model.changed() }
        .onChange(of: model.after) { _, _ in model.audition(keepPosition: true) }
        .onChange(of: model.selectedVersion) { _, _ in if model.after { model.audition(keepPosition: true) } }
        .onChange(of: model.matchListeningLevel) { _, _ in model.updateListeningGain() }
        .sheet(isPresented: $model.showStyles) { MasterStylePicker(model: model) }
        .alert("Mastering", isPresented: Binding(get: { model.error != nil || model.player.error != nil }, set: { if !$0 { model.error = nil; model.player.error = nil } })) { Button("OK") { model.error = nil; model.player.error = nil } } message: { Text(model.error ?? model.player.error ?? "") }
        .alert("Mastering", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("OK") { model.notice = nil } } message: { Text(model.notice ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Mastering sessions").font(.headline); Spacer(); Button("Import audio", systemImage: "plus") { model.chooseFile(backend: backend) }.labelStyle(.iconOnly).buttonStyle(.plain).disabled(model.busy || backend.busy) }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.library.sessions) { session in
                        Button { model.select(session.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.headline).lineLimit(2)
                                Text(session.versions.isEmpty ? "Original · ready to shape" : "\(session.versions.count) saved \(session.versions.count == 1 ? "master" : "masters")").font(.caption).foregroundStyle(StudioTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(model.library.selected == session.id ? StudioTheme.accent.opacity(0.13) : .clear, in: .rect(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel("Open mastering session \(session.title)")
                        .contextMenu {
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingDelete = session; confirmDelete = true }.disabled(model.busy || backend.busy)
                            Button("Show session in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([session.folder]) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            if let session = model.session {
                Button("Move session to Trash…", systemImage: "trash") { pendingDelete = session; confirmDelete = true }
                    .buttonStyle(.plain).font(.caption).disabled(model.busy || backend.busy)
            }
            Label("Studio Mastering", systemImage: "waveform.path").font(.caption).foregroundStyle(StudioTheme.highlight)
            Text("Master a finished mix, or bring a song over from Create.").font(.caption).foregroundStyle(StudioTheme.muted)
        }.padding(18).frame(width: 225).background(StudioTheme.sidebar)
    }
    private var empty: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform.path").font(.system(size: 54, weight: .light)).foregroundStyle(StudioTheme.highlight).accessibilityHidden(true)
            Text("Give your mix its final touch.").font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("Drop a music file here. Start with Studio Mastering’s Smart Master or choose a style, then listen before you commit.").font(.title3).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Choose a music file", systemImage: "square.and.arrow.down") { model.chooseFile(backend: backend) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(backend.busy || model.busy)
            Text("WAV, AIFF, FLAC, MP3 or M4A\nYour original stays untouched. No song generation required.").font(.callout).foregroundStyle(StudioTheme.muted)
            if backend.busy { Label("A song is rendering. Import will be available when it finishes.", systemImage: "hourglass").font(.callout) }
            if model.busy { ProgressView(model.status) }
        }.frame(maxWidth: 560, alignment: .leading).padding(42)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.session {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Track title", text: $model.title).font(.system(size: 30, weight: .semibold, design: .rounded)).textFieldStyle(.plain).accessibilityLabel("Mastering track title").disabled(model.busy)
                        Text("\(clockText(session.duration)) · \(session.sampleRate > 0 ? String(format: "%.1f kHz", session.sampleRate / 1000) : "Audio ready") · original preserved").font(.subheadline).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                    Button("Export master", systemImage: "square.and.arrow.up") { model.export() }.disabled(model.version == nil || model.busy)
                }.padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        styleAndActions
                        comparison
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Quick fixes").font(.headline)
                                Spacer()
                                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                                    .disabled(!model.canUndo || model.busy)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                                quickFix("HiFi", icon: "hifispeaker.fill", key: "HiFi")
                                quickFix("Fix Stereo", icon: "speaker.wave.2", key: "Stereo")
                                quickFix("More Bass", icon: "waveform.path", key: "Bass")
                                quickFix("Clear Mids", icon: "slider.horizontal.3", key: "Mid")
                                quickFix("Smooth Highs", icon: "waveform", key: "High")
                            }.disabled(model.busy)
                            Text("Choose a fix, then render to hear it. Your original stays untouched.")
                                .font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                        DisclosureGroup("Fine-tune your master", isExpanded: $model.showAdvanced) {
                            MasteringControls(model: model).padding(.top, 16).disabled(model.busy)
                        }.font(.headline)
                        if let version = model.version {
                            HStack {
                                Text("Saved versions").font(.subheadline)
                                Picker("Saved master", selection: Binding(get: { model.selectedVersion ?? version.id }, set: { model.selectedVersion = $0; model.after = true })) {
                                    ForEach(Array(session.versions.enumerated()), id: \.element.id) { index, item in Text("Master \(index + 1) · \(item.preset.replacingOccurrences(of: "GENRE / ", with: ""))").tag(item.id) }
                                }.labelsHidden().frame(maxWidth: 330)
                                Spacer()
                                Button("Show files", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: version.path)]) }
                            }.disabled(model.busy)
                        }
                    }.padding(.trailing, 8).padding(.bottom, 20)
                }
                Divider()
                footer.padding(.top, 16)
            }
        }.padding(26)
    }
    private func quickFix(_ title: String, icon: String, key: String) -> some View {
        Button { model.repair(key) } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(StudioTheme.ink)
                .background(StudioTheme.highlight.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help("Apply \(title). Render a new master to hear the change; Undo restores your previous settings.")
    }
    private var styleAndActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Master style").font(.headline)
                    Button { model.showStyles = true } label: {
                        HStack { Text(model.preset.replacingOccurrences(of: "GENRE / ", with: "")).font(.title3).fontWeight(.medium); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption) }
                    }.buttonStyle(.plain).padding(13).background(StudioTheme.editor, in: .rect(cornerRadius: 10)).accessibilityLabel("Choose master style, \(model.preset)")
                }.frame(maxWidth: .infinity)
                Button { model.perform("smart", backend: backend) } label: { Label("Smart Master", systemImage: "waveform.badge.magnifyingglass").padding(.vertical, 8) }.buttonStyle(.bordered).help("Measure the whole song and suggest Studio Mastering’s conservative settings. Render to hear them.")
            }
            Text("A style is a starting point. Smart Master listens first and avoids adding processing to an already loud, dense source.").font(.callout).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.disabled(model.busy || backend.busy)
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Listen, then decide").font(.headline)
                Spacer()
                Picker("Compare audio", selection: $model.after) { Text("Before").tag(false); Text("After").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 170).disabled(model.version == nil || model.busy)
            }
            HStack(alignment: .top, spacing: 24) {
                measurement("Original", value: model.session?.measurement)
                Divider().frame(height: 44)
                measurement("Rendered master", value: model.version?.measurement)
                Spacer()
                Toggle("Match listening level", isOn: $model.matchListeningLevel).toggleStyle(.checkbox).font(.callout).disabled(model.version == nil).help("Only turns down the louder version during playback. Your export is unaffected.")
            }
            if model.version != nil && model.needsRender {
                Label("Settings changed. After plays the saved master until you render again.", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(StudioTheme.highlight)
            } else if model.version == nil { Text("Render a master to compare the full-quality result.").font(.caption).foregroundStyle(StudioTheme.muted) }
        }.padding(18).background(StudioTheme.editor, in: .rect(cornerRadius: 12))
    }
    private func measurement(_ title: String, value: MasterMeasurement?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(StudioTheme.muted)
            Text(value.map { String(format: "%.1f LUFS  ·  %.1f dBTP", $0.lufs, $0.truePeak) } ?? "Not measured yet").font(.subheadline).monospacedDigit()
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy { ProgressView(value: model.progress).tint(StudioTheme.accent) }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Full Studio Mastering processing · 24-bit WAV · source sample rate").font(.caption).foregroundStyle(StudioTheme.muted)
                }
                Spacer(minLength: 10)
                if model.busy {
                    Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.disabled(model.cancelling)
                } else {
                    Button { model.perform("render", backend: backend) } label: { Label(model.version == nil ? "Render master" : "Render new master", systemImage: "waveform.path") }.buttonStyle(StudioPrimaryButtonStyle()).disabled(backend.busy)
                }
            }
            if backend.busy { Text("Song generation is running. Mastering will be available when it finishes.").font(.caption).foregroundStyle(StudioTheme.highlight) }
        }
    }
}

struct MasterStylePicker: View {
    @Bindable var model: MasteringController
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Find the feel of your master").font(.title2).fontWeight(.semibold); Spacer(); Button("Done") { model.showStyles = false } }
            Text("Studio Mastering’s current preset collection. Choose a starting point, then make it yours.").foregroundStyle(StudioTheme.muted)
            TextField("Search styles", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.presets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }) { style in
                        Button { model.apply(style) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text(style.displayName).font(.headline); Spacer(); if model.preset == style.name { Image(systemName: "checkmark").foregroundStyle(StudioTheme.highlight) } }
                                Text(style.description.replacingOccurrences(of: "use Match Level to measure this song before export.", with: "enable Match loudness on render in Delivery for a measured loudness target.")).font(.callout).foregroundStyle(StudioTheme.muted).multilineTextAlignment(.leading)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }.padding(26).frame(width: 640, height: 600).background(StudioTheme.canvas).foregroundStyle(StudioTheme.ink)
    }
}
