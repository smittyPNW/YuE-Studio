import SwiftUI
import UniformTypeIdentifiers

struct EditWorkspace: View {
    @Bindable var model: EditController
    var master: (URL, String) -> Void
    @State private var dropTarget = false
    @State private var selectionInSamples = false
    @State private var pendingDelete: EditLibraryItem?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if model.document != nil {
                VStack(alignment: .leading, spacing: 14) {
                    title
                    EditToolbar(model: model)
                    EditTimeline(model: model).frame(minHeight: 200, maxHeight: .infinity)
                    selection
                    clipStrip
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.caption).foregroundStyle(StudioTheme.muted).lineLimit(2)
                        Spacer()
                    }.frame(minHeight: 28)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector { Divider(); EditInspector(model: model).frame(width: 246) }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "waveform.path").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(StudioTheme.highlight)
                    Text("Make room for the best parts.").font(.largeTitle).fontWeight(.semibold)
                    Text("Drop a recording here. Trim, arrange, repair, and finish it.\nYour original stays untouched; every edit can be undone.")
                        .multilineTextAlignment(.center).foregroundStyle(StudioTheme.muted)
                    Button("Open a recording", systemImage: "plus") { model.chooseFile() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(model.unavailable)
                    Text("WAV · AIFF · FLAC · MP3 · M4A · CAF").font(.caption).foregroundStyle(StudioTheme.muted)
                    if model.busy { ProgressView(model.status) }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard !model.unavailable, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.importAudio(url) } } }; return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.highlight, style: StrokeStyle(lineWidth: 3, dash: [8,5])).padding(8).allowsHitTesting(false) } }
        .confirmationDialog("Move editing project to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let item = pendingDelete { model.trash(item) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This moves the project, working copies and edit history to Trash. Your external original and exports stay in place. Use Finder’s Put Back to restore the project.") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !model.busy { model.refresh() } }
        .alert("Audio editor", isPresented: Binding(get: { model.error != nil || model.transport.error != nil }, set: { if !$0 { model.error = nil; model.transport.error = nil } })) {
            Button("OK") { model.error = nil; model.transport.error = nil }
        } message: { Text(model.error ?? model.transport.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Editing projects").font(.headline)
                Spacer()
                Button("Open audio", systemImage: "plus") { model.chooseFile() }.labelStyle(.iconOnly).buttonStyle(.plain).disabled(model.unavailable)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(model.items) { item in
                        Button { model.open(item.folder) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(2)
                                Text("Reversible edit").font(.caption).foregroundStyle(StudioTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(model.folder == item.folder ? StudioTheme.accent.opacity(0.16) : .clear, in: .rect(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(model.unavailable)
                        .contextMenu {
                            Button("Show project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingDelete = item }.disabled(model.unavailable)
                        }
                    }
                }
            }
            Divider()
            Label("Originals preserved", systemImage: "lock.shield").font(.caption).foregroundStyle(StudioTheme.muted)
            Text("Edits and history are saved automatically with each project.").font(.caption).foregroundStyle(StudioTheme.muted)
        }.padding(16).frame(width: 184).background(StudioTheme.sidebar)
    }
    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("EDIT THE RECORDING").font(.caption).tracking(1.5).foregroundStyle(StudioTheme.highlight)
                Text(model.document?.title ?? "Audio editor").font(.title2).fontWeight(.semibold).lineLimit(1)
                Text("\(String(format: "%.1f", model.rate / 1000)) kHz · \(model.document?.channels == 1 ? "Mono" : "Stereo") · Float PCM workspace")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            Spacer(minLength: 4)
            Menu("Export", systemImage: "square.and.arrow.up") {
                ForEach(AudioExportFormat.allCases) { format in Button(format.title + "…") { model.export(format, selectionOnly: false) } }
                Menu("Export selection") {
                    ForEach(AudioExportFormat.allCases) { format in Button(format.title + "…") { model.export(format, selectionOnly: true) } }
                }.disabled(model.selection.isEmpty)
            }.fixedSize().disabled(model.unavailable || model.frames == 0)
            Button("Master", systemImage: "slider.horizontal.3") {
                if let preview = model.preview { model.transport.pause(); master(preview, model.document?.title ?? "Edited song") }
            }.disabled(model.unavailable || model.frames == 0).help("Send the complete edited recording to Mastering")
        }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Selection", systemImage: "selection.pin.in.out").font(.caption).fontWeight(.semibold)
                Spacer()
                Text("\(String(format: "%.3f", Double(model.selection.count64) / model.rate)) s · \(model.selection.count64) samples").font(.caption).monospacedDigit().foregroundStyle(StudioTheme.muted)
            }
            HStack {
                Text("Start").font(.caption)
                selectionField(start: true)
                Text("End").font(.caption)
                selectionField(start: false)
                Picker("Selection units", selection: $selectionInSamples) { Text("Seconds").tag(false); Text("Samples").tag(true) }.labelsHidden().frame(width: 93)
                Button("All") { model.selectAll() }
                Button("Clear") { model.clearSelection() }
            }.textFieldStyle(.roundedBorder).controlSize(.small).disabled(model.busy)
        }
    }
    private func selectionField(start: Bool) -> some View {
        TextField(start ? "Selection start" : "Selection end", value: Binding(get: {
            Double(start ? model.selectionStart : model.selectionEnd) / (selectionInSamples ? 1 : model.rate)
        }, set: { value in
            guard value.isFinite else { return }
            let frame = Int64(min(Double(model.frames), max(0, (value * (selectionInSamples ? 1 : model.rate)).rounded())))
            if start { model.selectionStart = frame } else { model.selectionEnd = frame }
        }), format: .number.grouping(.never).precision(.fractionLength(0...(selectionInSamples ? 0 : 6))))
        .frame(minWidth: 65).accessibilityLabel("Selection \(start ? "start" : "end") in \(selectionInSamples ? "samples" : "seconds")")
    }
    private var clipStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("ARRANGEMENT").font(.caption).tracking(1.2).foregroundStyle(StudioTheme.muted); Spacer(); Button("Add recording", systemImage: "plus") { model.chooseFile(append: true) }.controlSize(.small).disabled(model.unavailable) }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array((model.document?.clips ?? []).enumerated()), id: \.element.id) { index, clip in
                        Button { model.selectClip(index) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1)  \(clip.name)").font(.caption).fontWeight(.medium).lineLimit(1)
                                Text(String(format: "%.2f seconds", Double(clip.count) / model.rate)).font(.caption2).foregroundStyle(StudioTheme.muted)
                            }.frame(width: 130, alignment: .leading).padding(10)
                                .background(model.selectedClip == index ? StudioTheme.accent.opacity(0.22) : StudioTheme.editor, in: .rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).stroke(model.selectedClip == index ? StudioTheme.highlight : .clear) }
                        }.buttonStyle(.plain).disabled(model.unavailable)
                        .contextMenu {
                            Button("Move earlier") { model.change("Move clip") { $0.moveClip(index, by: -1) } }.disabled(index == 0)
                            Button("Move later") { model.change("Move clip") { $0.moveClip(index, by: 1) } }.disabled(index + 1 == model.document?.clips.count)
                            Button("Select clip") { model.selectClip(index) }
                        }
                    }
                }
            }.frame(height: 66)
        }
    }
}

struct EditToolbar: View {
    @Bindable var model: EditController
    var body: some View {
        HStack(spacing: 10) {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(model.project?.undo.isEmpty != false).help("Undo \(model.project?.undo.last?.name ?? "edit")")
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }.disabled(model.project?.redo.isEmpty != false)
            Divider().frame(height: 18)
            Button("Split", systemImage: "scissors") { model.split() }.help("Split at the playhead")
            Menu("Edit selection") {
                Button("Copy") { model.copy() }.disabled(model.selection.isEmpty)
                Button("Cut") { model.cut() }.disabled(model.selection.isEmpty)
                Button("Paste at playhead") { model.paste() }.disabled(!model.canPaste)
                Button("Duplicate after selection") { model.duplicate() }.disabled(model.selection.isEmpty)
                Button("Delete and close gap") { model.deleteSelection() }.disabled(model.selection.isEmpty)
                Button("Snap to quiet crossings") { model.snapToQuietCrossings() }.disabled(model.selection.isEmpty)
                Button("Keep only selection") { model.trim() }.disabled(model.selection.isEmpty)
                Divider()
                Button("Select All") { model.selectAll() }
            }
            Spacer(minLength: 0)
            Button("Tools", systemImage: "slider.horizontal.3") { model.showInspector.toggle() }
        }.controlSize(.small).disabled(model.unavailable)
    }
}

struct EditInspector: View {
    @Bindable var model: EditController
    @State private var gain = 0.0
    @State private var rampEnd = -6.0
    @State private var ceiling = -1.0
    @State private var silence = 1.0
    @State private var overlap = 0.1
    @State private var cutoff = 80.0
    @State private var marker = "Verse"
    @State private var title = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SHAPE & REPAIR").font(.caption).tracking(1.5).foregroundStyle(StudioTheme.highlight)
                Text("Tools affect the selection. Select All to process the entire recording.").font(.caption).foregroundStyle(StudioTheme.muted)
                GroupBox("Level & movement") {
                    VStack(spacing: 10) {
                        number("Gain · dB", value: $gain, range: -60...24)
                        Button("Apply gain") { model.effect(.gain(gain), name: "Gain \(gain) dB") }
                        number("Ramp end · dB", value: $rampEnd, range: -60...24)
                        Button("Ramp from gain to end") { model.effect(.ramp(gain, rampEnd), name: "Volume ramp") }
                        HStack { Button("Fade in") { model.effect(.fadeIn, name: "Fade in") }; Button("Fade out") { model.effect(.fadeOut, name: "Fade out") } }
                        number("Peak target · dBFS", value: $ceiling, range: -24...0)
                        Button("Peak normalize") { model.effect(.normalize(ceiling), name: "Peak normalize") }
                        Text("Peak normalization changes gain only. Use Master for limiting and loudness targets.").font(.caption2).foregroundStyle(StudioTheme.muted)
                    }.frame(maxWidth: .infinity)
                }
                GroupBox("Timing & transitions") {
                    VStack(spacing: 10) {
                        HStack { Button("Silence selection") { model.effect(.silence, name: "Silence") }; Button("Reverse") { model.effect(.reverse, name: "Reverse") } }
                        number("Insert silence · sec", value: $silence, range: 0.001...600)
                        Button("Insert at playhead") { model.insertSilence(seconds: silence) }
                        number("Overlap · sec", value: $overlap, range: 0.001...30)
                        Button("Crossfade to next clip") { model.crossfade(seconds: overlap) }.disabled(model.selectedClip == nil)
                        Text("Select an arrangement clip first. Crossfade overlaps its end with the next clip and shortens the timeline.").font(.caption2).foregroundStyle(StudioTheme.muted)
                    }.frame(maxWidth: .infinity)
                }
                GroupBox("Repair & channels") {
                    VStack(spacing: 10) {
                        Button("Repair tiny click") { model.effect(.repairClick, name: "Click repair") }
                        Text("Select 1–128 damaged samples with clean audio on both sides. Preview, then undo if needed.").font(.caption2).foregroundStyle(StudioTheme.muted)
                        Button("Remove DC offset") { model.effect(.removeDC, name: "Remove DC") }
                        HStack { Button("Invert polarity") { model.effect(.invert, name: "Invert polarity") }; Button("Swap L / R") { model.effect(.swap, name: "Swap channels") }.disabled(model.document?.channels != 2) }
                        Button("Fold stereo to mono") { model.effect(.mono, name: "Mono fold-down") }.disabled(model.document?.channels != 2)
                        Text("Mono fold-down puts the channel average in both channels. Phase cancellation is possible; audition the result.").font(.caption2).foregroundStyle(StudioTheme.muted)
                        number("Filter cutoff · Hz", value: $cutoff, range: 10...20000)
                        HStack { Button("High-pass") { model.effect(.highPass(cutoff), name: "High-pass") }; Button("Low-pass") { model.effect(.lowPass(cutoff), name: "Low-pass") } }
                    }.frame(maxWidth: .infinity)
                }
                GroupBox("Markers & project") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Marker name", text: $marker).accessibilityLabel("Marker name")
                        Button("Mark playhead", systemImage: "bookmark") { model.mark(marker) }
                        ForEach(model.document?.markers ?? []) { item in
                            HStack {
                                Button("\(clockText(Double(item.frame) / model.rate))  \(item.name)") { model.transport.seek(item.frame); model.selectionStart = item.frame; model.selectionEnd = item.frame }
                                Spacer()
                                Button("Remove marker", systemImage: "xmark") { model.change("Remove marker") { $0.markers.removeAll { $0.id == item.id } } }.labelStyle(.iconOnly)
                            }
                        }
                        Divider()
                        TextField("Project title", text: $title).accessibilityLabel("New project title")
                        Button("Rename project") { let name = title.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { model.change("Rename project") { $0.title = name } } }
                    }
                }
                EditAnalysisView(model: model)
            }.controlSize(.small).buttonStyle(.bordered).disabled(model.unavailable).padding(16)
        }.background(StudioTheme.sidebar)
    }
    private func number(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(StudioTheme.muted)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder)
                .onChange(of: value.wrappedValue) { _, new in if !new.isFinite || !range.contains(new) { value.wrappedValue = new.isFinite ? min(range.upperBound, max(range.lowerBound, new)) : range.lowerBound } }
        }
    }
}

struct EditAnalysisView: View {
    @Bindable var model: EditController
    var body: some View {
        GroupBox("Signal analysis") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Analyze selection / whole song") { model.analyze() }
                if let stats = model.statistics {
                    Text(model.spectrum == nil ? "Complete edited recording" : model.spectrumLabel).font(.caption).foregroundStyle(StudioTheme.muted)
                    Text("Peak: \(db(stats.peakDB)) dBFS\nRMS: \(db(stats.rmsDB)) dBFS\nSamples at / above 0 dBFS: \(stats.clippedSamples)").font(.caption).monospacedDigit()
                    Text("DC: \(stats.dc.map { String(format: "%.5f", $0) }.joined(separator: " / "))").font(.caption2).monospacedDigit()
                    if stats.peak > 1 { Label("Over 0 dBFS. Lower the gain before fixed-point export.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(StudioTheme.highlight) }
                }
                if let spectrum = model.spectrum {
                    Canvas { context, size in
                        var path = Path()
                        for i in 0..<Int(size.width) {
                            let hz = 20 * pow(max(1, spectrum.rate / 2 / 20), Double(i) / max(1, size.width - 1))
                            let bin = min(spectrum.magnitudes.count - 1, max(1, Int(hz * 4096 / spectrum.rate)))
                            let y = size.height * (1 - CGFloat(max(-100, min(0, spectrum.magnitudes[bin])) + 100) / 100)
                            if i == 0 { path.move(to: CGPoint(x: 0, y: y)) } else { path.addLine(to: CGPoint(x: CGFloat(i), y: y)) }
                        }
                        context.stroke(path, with: .color(StudioTheme.highlight), lineWidth: 1.5)
                    }.frame(height: 95).background(StudioTheme.editor).accessibilityLabel("Average frequency spectrum of the analyzed selection")
                    Text("20 Hz → \(Int(spectrum.rate / 2000)) kHz · logarithmic frequency\nAverage spectrum, −100 to 0 dB scale.").font(.caption2).foregroundStyle(StudioTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func db(_ value: Double) -> String { value.isFinite ? String(format: "%.2f", value) : "−∞" }
}
