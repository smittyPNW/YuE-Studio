import SwiftUI
import UniformTypeIdentifiers

struct EditLibraryItem: Identifiable {
    var folder: URL
    var title: String
    var id: String { folder.path }
}

@MainActor @Observable final class EditController {
    var project: EditProject?
    var folder: URL?
    var preview: URL?
    var waveform: EditWaveform?
    var statistics: EditStatistics?
    var spectrum: EditSpectrum?
    var spectrumLabel = ""
    var items: [EditLibraryItem] = []
    var selectionStart: Int64 = 0
    var selectionEnd: Int64 = 0
    var viewStart: Int64 = 0
    var viewFrames: Int64 = 1
    var busy = false
    var status = "Your recording. Room to shape it."
    var error: String?
    var notice: String?
    var showInspector = true
    var selectedClip: Int?
    var transport = EditTransport()
    @ObservationIgnored weak var backend: Backend?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<EditJobResult, Error>?
    @ObservationIgnored private var clipboard: [EditClip] = []
    @ObservationIgnored private var clipboardFolder: URL?
    let root: URL
    let lock: URL
    var document: EditDocument? { project?.document }
    var frames: Int64 { document?.frames ?? 0 }
    var rate: Double { document?.sampleRate ?? 48000 }
    var selection: Range<Int64> {
        let start = min(frames, max(0, min(selectionStart, selectionEnd)))
        return start..<min(frames, max(start, max(selectionStart, selectionEnd)))
    }
    var canPaste: Bool { !clipboard.isEmpty && clipboardFolder == folder }
    var unavailable: Bool { busy || backend?.busy == true || backend?.masteringActive == true }
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/YuE Studio Edits"), lock: URL = Paths.custom.appendingPathComponent("worker.lock")) { self.root = root; self.lock = lock; refresh() }
    func refresh() {
        items = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).compactMap { url in
            guard let project = try? EditProject.read(url) else { return nil }
            return EditLibraryItem(folder: url, title: project.document.title)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func activate() {
        guard project == nil, !busy, let path = UserDefaults.standard.string(forKey: "lastEditProject"),
              let item = items.first(where: { $0.folder.path == path }) else { return }
        open(item.folder)
    }
    func chooseFile(append: Bool = false) {
        guard !unavailable else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["wav", "aif", "aiff", "flac", "mp3", "m4a", "caf"].compactMap { UTType(filenameExtension: $0) }
        panel.message = append ? "Add an alternate take. Its sample rate and channel count must match the project." : "Open a recording. Studio keeps an independent copy for reversible editing."
        panel.begin { [weak self] result in if result == .OK, let url = panel.url { self?.importAudio(url, append: append) } }
    }
    func importAudio(_ url: URL, title: String? = nil, append: Bool = false) {
        guard !unavailable else { error = "Let the current audio job finish before importing."; return }
        let destination = append ? folder : root.appendingPathComponent(UUID().uuidString)
        guard let destination else { return }
        launch(name: append ? "Add recording" : "Open recording", folder: destination) { previous, _ in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let input = try EditAudio.file(url)
            try EditAudio.validatePrecision(input)
            guard input.length > 0, input.processingFormat.channelCount <= 2,
                  input.length <= Int64(input.processingFormat.sampleRate * 60 * 60 * 4) else { throw StudioFailure("Choose a mono or stereo recording up to four hours long.") }
            if append, let previous {
                guard input.processingFormat.sampleRate == previous.document.sampleRate, input.processingFormat.channelCount == previous.document.channels else {
                    throw StudioFailure("This recording has a different sample rate or channel count. Open it as its own project to preserve its format.")
                }
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let asset = "source-\(UUID().uuidString).\(url.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(asset))
            let clip = EditClip(asset: asset, start: 0, count: input.length, name: title ?? url.deletingPathExtension().lastPathComponent)
            if append, var result = previous {
                var next = result.document; next.clips.append(clip); result.record(next, name: "Add recording"); return result
            }
            return EditProject(document: EditDocument(title: title ?? url.deletingPathExtension().lastPathComponent, sampleRate: input.processingFormat.sampleRate, channels: input.processingFormat.channelCount, clips: [clip]))
        }
    }
    func trash(_ item: EditLibraryItem) {
        guard !unavailable, let backend else { return }
        busy = true; transport.pause()
        task = Task {
            var reserved = false
            defer { if reserved { backend.endMastering() }; busy = false; task = nil }
            do {
                try await backend.beginMastering(); reserved = true
                let saved = try EditProject.read(item.folder)
                try ProjectTrash.move(item.folder, root: root, depth: 1, lock: lock,
                    metadata: JSONEncoder().encode(saved), metadataName: "edit-project.json")
                if folder == item.folder {
                    try transport.load(nil); project = nil; folder = nil; preview = nil; waveform = nil; statistics = nil; spectrum = nil
                    selectionStart = 0; selectionEnd = 0; clipboard = []; clipboardFolder = nil
                    UserDefaults.standard.removeObject(forKey: "lastEditProject")
                }
                refresh(); status = "Project moved to Trash. Use Finder’s Put Back to restore it."
            } catch { self.error = error.localizedDescription }
        }
    }
    func open(_ folder: URL) {
        launch(name: "Open project", folder: folder) { _, _ in try EditProject.read(folder) }
    }
    private func launch(name: String, folder target: URL, operation: @escaping @Sendable (EditProject?, URL?) throws -> EditProject) {
        guard !unavailable, let backend else { error = "Let the current audio job finish first."; return }
        error = nil
        let previous = project, oldPreview = preview, sameProject = folder == target
        let lock = self.lock
        let oldFrame = transport.frame
        busy = true; transport.pause(); status = "\(name)…"
        task = Task {
            var reserved = false
            defer { if reserved { backend.endMastering() }; busy = false; worker = nil; task = nil }
            do {
                try await backend.beginMastering(); reserved = true
                try Task.checkCancellation()
                let job = Task.detached(priority: .userInitiated) {
                    try EditAudio.withLease(lock: lock) {
                        let next = try operation(previous, oldPreview)
                        let rendered = target.appendingPathComponent("preview-\(UUID().uuidString).wav")
                        var complete = false
                        defer { if !complete { try? FileManager.default.removeItem(at: rendered) } }
                        var wave: EditWaveform?, stats: EditStatistics?
                        if next.document.frames > 0 {
                            try EditAudio.render(next.document, folder: target, destination: rendered)
                            wave = try EditWaveform.read(rendered); stats = try EditAudio.analyze(rendered)
                        }
                        try Task.checkCancellation()
                        try next.save(target)
                        complete = true
                        return EditJobResult(project: next, preview: next.document.frames > 0 ? rendered : nil, waveform: wave, statistics: stats)
                    }
                }
                worker = job
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                // Once the atomic project save succeeds, adopt it even if Cancel arrives at completion.
                project = result.project; folder = target; preview = result.preview; waveform = result.waveform; statistics = result.statistics
                spectrum = nil; selectedClip = nil
                selectionStart = min(selectionStart, frames); selectionEnd = min(selectionEnd, frames)
                if !sameProject { selectionStart = 0; selectionEnd = 0; fit(); clipboard = []; clipboardFolder = nil }
                else { viewFrames = min(max(32, viewFrames), max(1, frames)); viewStart = min(viewStart, max(0, frames - viewFrames)) }
                try transport.load(result.preview); transport.seek(sameProject ? min(oldFrame, frames) : 0)
                status = "\(name) · saved. Original preserved."
                UserDefaults.standard.set(target.path, forKey: "lastEditProject"); refresh()
                // Only disposable previews are removed. Assets and history travel with the project.
                for url in (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("preview-") && url != result.preview {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                if error is CancellationError { status = "Cancelled. Previous edit preserved." }
                else { self.error = error.localizedDescription; status = "Previous edit preserved." }
            }
        }
    }
    func cancel() { worker?.cancel(); task?.cancel(); status = "Cancelling safely…" }
    func change(_ name: String, _ operation: @escaping @Sendable (inout EditDocument) -> Void) {
        guard let folder else { return }
        launch(name: name, folder: folder) { previous, _ in
            guard var next = previous else { throw StudioFailure("Open a recording first.") }
            var document = next.document; operation(&document); next.record(document, name: name); return next
        }
    }
    func undo() {
        guard let folder, project?.undo.isEmpty == false else { return }
        launch(name: "Undo", folder: folder) { previous, _ in var next = previous!; next.stepBack(); return next }
    }
    func redo() {
        guard let folder, project?.redo.isEmpty == false else { return }
        launch(name: "Redo", folder: folder) { previous, _ in var next = previous!; next.stepForward(); return next }
    }
    func snapToQuietCrossings() {
        guard !busy, let preview, !selection.isEmpty else { return }
        do {
            let start = try EditAudio.quietCrossing(preview, near: selection.lowerBound)
            let end = try EditAudio.quietCrossing(preview, near: selection.upperBound)
            guard end > start else { return }
            selectionStart = start; selectionEnd = end; transport.seek(start)
            status = "Selection snapped to nearby quiet crossings. Audition the cut; a short crossfade can smooth difficult joins."
        } catch { self.error = error.localizedDescription }
    }
    func selectAll() { selectionStart = 0; selectionEnd = frames }
    func clearSelection() { selectionStart = transport.frame; selectionEnd = transport.frame }
    func copy() {
        guard let document, !selection.isEmpty, !busy else { return }
        clipboard = document.slice(selection); clipboardFolder = folder; status = "Selection copied. Paste at the playhead in this project."
    }
    func cut() { copy(); deleteSelection() }
    func deleteSelection() {
        let range = selection; guard !range.isEmpty else { return }
        change("Delete selection") { $0.replace(range, with: []) }; selectionEnd = selectionStart
    }
    func trim() { let range = selection; guard !range.isEmpty else { return }; change("Trim to selection") { $0.trim(to: range) }; selectionStart = 0; selectionEnd = range.count64 }
    func paste() {
        guard canPaste else { return }; let clips = clipboard.map { EditClip(asset: $0.asset, start: $0.start, count: $0.count, name: $0.name) }, frame = transport.frame
        change("Paste") { $0.replace(frame..<frame, with: clips) }
    }
    func duplicate() { copy(); let end = selection.upperBound; transport.seek(end); paste() }
    func split() { let frame = transport.frame; change("Split clip") { $0.split(at: frame) } }
    func effect(_ effect: EditEffect, name: String) {
        let range = selection
        guard let folder, !range.isEmpty else { error = "Select a passage, or choose Select All, before processing."; return }
        launch(name: name, folder: folder) { previous, preview in
            guard var next = previous, let preview else { throw StudioFailure("Open a recording first.") }
            let asset = "edit-\(UUID().uuidString).wav"
            try EditAudio.process(effect, source: preview, range: range, destination: folder.appendingPathComponent(asset))
            var doc = next.document
            doc.replace(range, with: [EditClip(asset: asset, start: 0, count: range.count64, name: name)])
            next.record(doc, name: name); return next
        }
    }
    func insertSilence(seconds: Double) {
        guard seconds.isFinite, let folder else { return }
        let frame = transport.frame, count = Int64(min(600, max(0, seconds)) * rate)
        launch(name: "Insert silence", folder: folder) { previous, _ in
            guard var next = previous else { throw StudioFailure("Open a recording first.") }
            let asset = "silence-\(UUID().uuidString).wav"
            try EditAudio.silence(frames: count, rate: next.document.sampleRate, channels: next.document.channels, destination: folder.appendingPathComponent(asset))
            var doc = next.document; doc.replace(frame..<frame, with: [EditClip(asset: asset, start: 0, count: count, name: "Silence")]); next.record(doc, name: "Insert silence"); return next
        }
    }
    func crossfade(seconds: Double) {
        guard seconds.isFinite, let index = selectedClip, let folder, let doc = document, index + 1 < doc.clips.count else { error = "Select a clip with another clip immediately after it."; return }
        let count = Int64(max(0, min(seconds, 30)) * rate)
        guard count > 1, count <= min(doc.clips[index].count, doc.clips[index + 1].count) else { error = "Choose an overlap shorter than both neighboring clips."; return }
        let boundary = doc.clips.prefix(index + 1).reduce(Int64(0)) { $0 + $1.count }
        launch(name: "Crossfade", folder: folder) { previous, preview in
            var next = previous!; let asset = "crossfade-\(UUID().uuidString).wav"
            try EditAudio.crossfade(source: preview!, boundary: boundary, frames: count, destination: folder.appendingPathComponent(asset))
            var document = next.document
            document.replace((boundary - count)..<(boundary + count), with: [EditClip(asset: asset, start: 0, count: count, name: "Crossfade")])
            next.record(document, name: "Crossfade"); return next
        }
    }
    func mark(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), frame = transport.frame
        guard !name.isEmpty else { return }
        change("Add marker") { $0.markers.append(EditMarker(frame: frame, name: name)) }
    }
    func selectClip(_ index: Int) {
        guard let doc = document, doc.clips.indices.contains(index) else { return }
        selectedClip = index; selectionStart = doc.clips.prefix(index).reduce(0) { $0 + $1.count }; selectionEnd = selectionStart + doc.clips[index].count
        transport.seek(selectionStart)
    }
    func fit() { viewStart = 0; viewFrames = max(1, frames) }
    func zoom(_ factor: Double) {
        let center = selection.isEmpty ? transport.frame : selection.lowerBound + selection.count64 / 2
        viewFrames = min(max(1, frames), max(32, Int64(Double(viewFrames) * factor)))
        viewStart = min(max(0, frames - viewFrames), max(0, center - viewFrames / 2))
    }
    func zoomSelection() { guard !selection.isEmpty else { return }; viewFrames = max(1, selection.count64); viewStart = selection.lowerBound }
    func analyze() {
        guard !unavailable, let preview, let backend else { return }
        let range = selection.isEmpty ? 0..<frames : selection
        let lock = self.lock
        busy = true; status = "Analyzing selection…"
        task = Task {
            var reserved = false
            defer { if reserved { backend.endMastering() }; busy = false; task = nil }
            do {
                try await backend.beginMastering(); reserved = true
                let job = Task.detached(priority: .utility) { try EditAudio.withLease(lock: lock) { (try EditAudio.analyze(preview, range: range), try EditSpectrum.read(preview, range: range)) } }
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                statistics = result.0; spectrum = result.1; spectrumLabel = "\(String(format: "%.3f", Double(range.lowerBound) / rate))–\(String(format: "%.3f", Double(range.upperBound) / rate)) s"
                status = "Selection analysis complete. RMS and sample peaks are not LUFS or true-peak measurements."
            } catch { self.error = error.localizedDescription }
        }
    }
    func export(_ format: AudioExportFormat, selectionOnly: Bool) {
        guard !unavailable, let preview, let project, let folder, let backend else { return }
        let range = selection
        let lock = self.lock
        if selectionOnly && range.isEmpty { error = "Select a passage to export."; return }
        let panel = ExportService.savePanel(title: project.document.title + (selectionOnly ? " — Selection" : " — Edit"), format: format)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url, !self.unavailable else { return }
            self.busy = true; self.status = "Exporting…"
            self.task = Task {
                var reserved = false
                defer { if reserved { backend.endMastering() }; self.busy = false; self.task = nil }
                do {
                    try await backend.beginMastering(); reserved = true
                    let job = Task.detached(priority: .utility) {
                        try EditAudio.withLease(lock: lock) {
                            let temporary = folder.appendingPathComponent("selection-\(UUID().uuidString).wav")
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            if selectionOnly {
                                var doc = project.document; doc.trim(to: range)
                                try EditAudio.render(doc, folder: folder, destination: temporary)
                            }
                            try ExportService.export(source: selectionOnly ? temporary : preview, destination: destination, format: format)
                        }
                    }
                    try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                    self.status = "Exported \(destination.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct EditJobResult: Sendable {
    var project: EditProject
    var preview: URL?
    var waveform: EditWaveform?
    var statistics: EditStatistics?
}
