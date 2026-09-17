import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class MasteringController {
    var library = MasterLibrary()
    var parameters = MasterParameters()
    var preset = "Neutral / Manual"
    var presets: [MasterPreset] = []
    var search = ""
    var busy = false
    var cancelling = false
    var progress = 0.0
    var status = "Your original stays untouched."
    var error: String?
    var notice: String?
    var after = false
    var matchListeningLevel = true
    var selectedVersion: UUID?
    var showStyles = false
    var showAdvanced = false
    var showRepairs = false
    var player = StudioPlayer()
    private var process: Process?
    private var history: [(MasterParameters,String)] = []
    private var saveTask: Task<Void,Never>?
    private var repairPatches: [String:[String:Any]] = [:]
    private let libraryURL = Paths.custom.appendingPathComponent("mastering-library.json")
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/YuE Studio Masters")
    var session: MasterSession? { library.sessions.first { $0.id == library.selected } }
    var version: MasterVersion? { session?.versions.first { $0.id == selectedVersion } ?? session?.versions.last }
    var needsRender: Bool { masterNeedsRender(parameters: parameters, version: version) }
    var title: String {
        get { session?.title ?? "" }
        set { if let index = library.sessions.firstIndex(where: { $0.id == library.selected }) { library.sessions[index].title = newValue; changed() } }
    }
    var canUndo: Bool { !history.isEmpty }

    init() {
        if let data = try? Data(contentsOf: libraryURL), let saved = try? JSONDecoder().decode(MasterLibrary.self, from: data) { library = saved }
        if let url = Bundle.main.url(forResource: "StudioMasteringCatalog", withExtension: "json"), let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String:Any] {
            if let entries = object["presets"], let encoded = try? JSONSerialization.data(withJSONObject: entries) { presets = (try? JSONDecoder().decode([MasterPreset].self, from: encoded)) ?? [] }
            for item in object["repairs"] as? [[String:Any]] ?? [] { if let name = item["name"] as? String, let patch = item["patch"] as? [String:Any] { repairPatches[name] = patch } }
        }
        restoreReturnedSessions()
        if let selected = session { parameters = selected.parameters; preset = selected.preset }
    }
    func save() {
        if let index = library.sessions.firstIndex(where: { $0.id == library.selected }) { library.sessions[index].parameters = parameters; library.sessions[index].preset = preset }
        do { try FileManager.default.createDirectory(at: Paths.custom, withIntermediateDirectories: true); try JSONEncoder().encode(library).write(to: libraryURL, options: .atomic) }
        catch { self.error = "Could not save mastering settings: \(error.localizedDescription)" }
    }
    func changed() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(300)); guard !Task.isCancelled else { return }; save() }
    }
    func control<Value: Equatable>(_ key: WritableKeyPath<MasterParameters,Value>) -> Binding<Value> {
        Binding(get: { self.parameters[keyPath: key] }, set: { value in
            guard self.parameters[keyPath: key] != value else { return }
            self.checkpoint(); self.parameters[keyPath: key] = value
        })
    }
    func checkpoint() { history.append((parameters,preset)); if history.count > 40 { history.removeFirst() } }
    func undo() { guard let previous = history.popLast() else { return }; parameters = previous.0; preset = previous.1; status = "Previous settings restored."; save() }
    func reset() { checkpoint(); parameters = MasterParameters(); preset = "Neutral / Manual"; status = "Neutral settings restored. Render when ready."; save() }
    func apply(_ style: MasterPreset) { checkpoint(); parameters = style.parameters; preset = style.name; showStyles = false; status = "\(style.displayName) selected. Render to hear these settings."; save() }
    func repair(_ name: String) {
        if name == "HiFi" {
            checkpoint(); parameters = parameters.hiFi(); preset = "HiFi"
            status = "HiFi selected: deep bass, clear detail, gentle air. Render, then compare at matched level."; save(); return
        }
        guard let patch = repairPatches[name] else { return }
        let values = applyingMasterPatch(patch, to: parameters.dictionary)
        guard let data = try? JSONSerialization.data(withJSONObject: values), let updated = try? JSONDecoder().decode(MasterParameters.self, from: data) else { return }
        checkpoint(); parameters = updated; preset = "Custom · \(name) repair"; status = "\(name) repair applied to the controls. Render to hear it."; save()
    }
    func moveToTrash(_ item: MasterSession, backend: Backend) {
        guard !busy, !backend.busy, !backend.masteringActive else { error = "Let the current audio job finish before deleting a session."; return }
        backend.withLibraryAccess { [self] in
        do {
            saveTask?.cancel(); save()
            guard let saved = library.sessions.first(where: { $0.id == item.id }) else { return }
            try ProjectTrash.move(saved.folder, root: root, depth: 1,
                                  lock: Paths.custom.appendingPathComponent("worker.lock"),
                                  metadata: JSONEncoder().encode(saved), metadataName: "studio-session.json")
            if library.selected == saved.id {
                player.clear(); library.selected = nil; selectedVersion = nil; after = false; history = []
                parameters = MasterParameters(); preset = "Neutral / Manual"
            }
            library.sessions.removeAll { $0.id == saved.id }; save()
        } catch { self.error = "Could not move the session to Trash: \(error.localizedDescription)" }
    }
    }

    func restoreReturnedSessions() {
        guard !busy else { return }
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("studio-session.json")),
                  let item = try? JSONDecoder().decode(MasterSession.self, from: data),
                  !library.sessions.contains(where: { $0.id == item.id }),
                  item.folder.standardizedFileURL == folder.standardizedFileURL,
                  FileManager.default.fileExists(atPath: item.source) else { continue }
            library.sessions.insert(item, at: 0)
        }
    }
    func select(_ id: UUID) {
        guard !busy else { return }; save(); player.pause(); library.selected = id; selectedVersion = nil; after = false; history = []
        guard let session else { return }; parameters = session.parameters; preset = session.preset; status = "Your original stays untouched."; audition(); save()
    }
    func chooseFile(backend: Backend) {
        guard !busy, !backend.busy else { error = "Let the current render finish before importing audio for mastering."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav","aiff","aif","flac","mp3","m4a"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a finished mix. Studio preserves the original and saves each master separately."
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.importFile(url, title: nil, backend: backend) } }
    }
    func importFile(_ url: URL, title: String?, backend: Backend) {
        guard !busy, !backend.busy, !backend.masteringActive else { error = "Wait for the current generation or mastering job to finish."; return }
        let allowed = ["wav","aiff","aif","flac","mp3","m4a"]
        guard url.isFileURL, allowed.contains(url.pathExtension.lowercased()) else { error = "Choose a WAV, AIFF, FLAC, MP3 or M4A music file."; return }
        if let existing = library.sessions.first(where: { $0.originalPath == url.path && FileManager.default.fileExists(atPath: $0.source) }) { select(existing.id); if let title { self.title = title }; return }
        save(); busy = true; cancelling = false; progress = 0; status = "Preparing your track…"; player.pause()
        Task {
            do {
                try await backend.beginMastering()
                let id = UUID(); let folder = root.appendingPathComponent(id.uuidString)
                let source = folder.appendingPathComponent("source.\(url.pathExtension.lowercased())")
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: source)
                }.value
                guard !cancelling else { throw StudioFailure("Import cancelled. Your original is unchanged.") }
                let item = MasterSession(id: id, title: title ?? url.deletingPathExtension().lastPathComponent, source: source.path, originalName: url.lastPathComponent, originalPath: url.path)
                library.sessions.insert(item, at: 0); library.selected = id; parameters = item.parameters; preset = item.preset; selectedVersion = nil; after = false; history = []; save()
                let response = try await run(command: "analyze", backend: backend)
                accept(response, command: "analyze"); audition()
            } catch { if !cancelling { self.error = error.localizedDescription }; status = cancelling ? "Import cancelled. Your original is unchanged." : "Import needs attention. Choose another file or try Analyze again." }
            finish(backend)
        }
    }
    func perform(_ command: String, backend: Backend) {
        guard session != nil, !busy, !backend.busy, !backend.masteringActive else { return }
        busy = true; cancelling = false; progress = 0; status = "Releasing music-generation memory…"; player.pause(); save()
        Task {
            do { try await backend.beginMastering(); guard !cancelling else { throw StudioFailure("Cancelled") }; let response = try await run(command: command, backend: backend); accept(response, command: command); if command == "render" { after = true; audition() } }
            catch { if !cancelling { self.error = error.localizedDescription }; status = cancelling ? "Cancelled. Your original and previous masters are safe." : "Could not complete this step. Your previous audio is safe." }
            finish(backend)
        }
    }
    private func finish(_ backend: Backend) { process = nil; busy = false; cancelling = false; backend.endMastering(); save() }
    func cancel() { guard busy else { return }; cancelling = true; status = "Cancelling safely…"; if let process, process.isRunning { process.terminate() } }
    private func run(command: String, backend: Backend) async throws -> MasterResponse {
        guard let session else { throw StudioFailure("Choose a song first.") }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudioMasterEngine")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw StudioFailure("The Studio Mastering engine is missing from this installation.") }
        let job = UUID().uuidString; let output = session.folder.appendingPathComponent("master-\(job).wav")
        let request = session.folder.appendingPathComponent("request-\(job).json")
        let object: [String:Any] = ["command":command,"input":session.source,"output":output.path,"lock":Paths.custom.appendingPathComponent("worker.lock").path,"parameters":parameters.dictionary,"presetName":preset,"title":session.title,"artist":session.artist]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: request, options: .atomic)
        let task = Process(); task.executableURL = helper; task.arguments = [request.path]
        let pipe = Pipe(); task.standardOutput = pipe
        let errorLog = session.folder.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorLog); task.standardError = errors
        try task.run(); process = task
        let response: MasterResponse = try await Task.detached(priority: .userInitiated) { [self] in
            defer { try? errors.close(); try? pipe.fileHandleForReading.close() }
            var buffer = Data(); var final: MasterResponse?
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }; buffer.append(data)
                while let range = buffer.range(of: Data([10])) {
                    let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound); buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String:Any] else { continue }
                    if object["event"] as? String == "progress" {
                        let fraction = object["fraction"] as? Double ?? 0; let message = object["message"] as? String ?? "Working…"
                        await MainActor.run { self.progress = fraction; if !self.cancelling { self.status = message } }
                    } else if let result = try? JSONDecoder().decode(MasterResponse.self, from: line) { final = result }
                }
            }
            task.waitUntilExit()
            guard task.terminationStatus == 0, let final, final.event == "result" else { throw StudioFailure(final?.message ?? "The mastering engine stopped. Your original and previous masters are safe.") }
            return final
        }.value
        return response
    }
    private func accept(_ response: MasterResponse, command: String) {
        guard let index = library.sessions.firstIndex(where: { $0.id == library.selected }) else { return }
        if let duration = response.duration { library.sessions[index].duration = duration }; if let rate = response.sampleRate { library.sessions[index].sampleRate = rate }
        if command == "render", let path = response.output, let measurement = response.analysis {
            let version = MasterVersion(id: UUID(), path: path, created: Date(), parameters: parameters, measurement: measurement, preset: preset)
            library.sessions[index].versions.append(version); selectedVersion = version.id
        } else {
            library.sessions[index].measurement = response.analysis
            if command == "smart", let updated = response.parameters { checkpoint(); parameters = updated; preset = "Smart Master" }
        }
        progress = 1; status = response.message ?? "Ready"
        if command == "smart" { status += " Render to hear these settings." }
        save()
    }
    func audition(keepPosition: Bool = false) {
        guard let session else { return }
        let source = after ? (version?.path ?? session.source) : session.source
        player.loadFile(URL(fileURLWithPath: source), title: session.title + (after ? " · After" : " · Before"), keepPosition: keepPosition)
        updateListeningGain()
    }
    func updateListeningGain() {
        var gain: Float = 1
        if matchListeningLevel, let before = session?.measurement?.lufs, let afterLevel = version?.measurement.lufs, before > -69, afterLevel > -69 {
            let loudness = after ? afterLevel : before
            gain = Float(pow(10, (min(before, afterLevel) - loudness) / 20))
        }
        player.auditionGain = gain
    }
    func export() {
        guard let version, let session else { return }
        let source = URL(fileURLWithPath: version.path)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.nameFieldStringValue = session.title.replacingOccurrences(of: "/", with: "-") + " — Master.wav"
        panel.message = "Export this rendered version as 24-bit WAV at the source sample rate. Listening level matching does not affect the file."
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    guard destination.resolvingSymlinksInPath().standardizedFileURL != URL(fileURLWithPath: session.originalPath).resolvingSymlinksInPath().standardizedFileURL,
                          destination.resolvingSymlinksInPath().standardizedFileURL != URL(fileURLWithPath: session.source).resolvingSymlinksInPath().standardizedFileURL,
                          !session.versions.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL }) else { throw StudioFailure("Choose a destination outside this session's source and master files.") }
                    try await Task.detached(priority: .utility) { try ExportService.exportMaster(source: source, destination: destination) }.value
                    self?.notice = "Exported \(destination.lastPathComponent)"
                } catch { self?.error = error.localizedDescription }
            }
        }
    }
}
