import SwiftUI
import AppKit
@MainActor
final class Backend: ObservableObject {
    @Published var log: [LogLine] = []
    @Published var songs: [Song] = []
    @Published private(set) var masteringActive = false
    private var generationReserved = false
    private var pendingGenerations = 0
    @Published var busy = false                  // anything queued or in a stage
    @Published var connected = false
    @Published var lastError: String?
    @Published var completedPath: String?
    @Published var startedPath: String?
    @Published var memoryMessage = "Model loads when needed"

    private var pendingRender: String?
    @Published var memoryPressure = "Monitoring"
    private var memoryMonitor: DispatchSourceMemoryPressure?

    init() {
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryMonitor = monitor
        monitor.setEventHandler { [weak self] in
            guard let self, let flags = self.memoryMonitor?.data else { return }
            self.memoryPressure = flags.contains(.critical) ? "High" : (flags.contains(.warning) ? "Elevated" : "Normal")
        }
        monitor.resume()
    }

    var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()

    func start() {
        guard process == nil, !masteringActive else { return }
        guard FileManager.default.fileExists(atPath: Paths.python.path) else { lastError = "The YuE runtime is missing. Restore the original installation before starting Studio."; return }
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-u", Paths.worker.path]
        p.currentDirectoryURL = Paths.support
        p.environment = Paths.workerEnvironment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                for line in text.split(separator: "\n") where !line.contains("Warning") && !line.contains("warn") && !line.contains("Running MIL") && !line.contains("passes/s") && !line.contains("torch_dtype") && !line.contains("Fetching") && !line.contains("coremltools") && !line.contains("has not been tested") && !line.isEmpty {
                    self?.append("stderr: \(line)")
                }
            }
        }
        p.terminationHandler = { [weak self, weak p] _ in
            Task { @MainActor [weak self] in
                guard let self, let p, self.process === p else { return }
                self.workerStopped()
            }
        }
        do {
            try p.run()
            process = p; stdin = inPipe.fileHandleForWriting
            append("Worker started: \(p.executableURL!.path)")
        } catch {
            append("Could not start worker: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = obj["event"] as? String else { continue }
            let path = obj["path"] as? String ?? ""
            switch event {
            case "ready": connected = true; append("Worker ready")
            case "log":
                let message = obj["message"] as? String ?? ""
                append(message)
                if message.contains("Model ready") || message.contains("Model reloaded") { memoryMessage = "Model loaded · original precision" }
                if message.contains("memory:") || message.contains("working memory:") || message.contains("Unloaded the model") { memoryMessage = message }
            case "memory_released": memoryMessage = "Model unloaded · memory available for other apps"
            case "started":
                pendingGenerations = max(0, pendingGenerations - 1)
                pendingRender = nil
                // Placeholders for the queued songs appear at once; a song already listed (a render of a
                // draft, or a stalled song) goes back into the pipeline.
                songs.removeAll { $0.status == .failed }
                let run = URL(fileURLWithPath: obj["output"] as? String ?? "").lastPathComponent
                for entry in obj["songs"] as? [[String: Any]] ?? [] {
                    let path = entry["path"] as? String ?? ""
                    if let i = songs.firstIndex(where: { $0.path == path }) {
                        songs[i].status = .queued; songs[i].detail = "queued"; songs[i].fraction = nil
                    } else {
                        songs.append(Song(run: run, index: entry["index"] as? Int ?? 0, path: path, score: "", seconds: 0,
                                          seed: entry["seed"] as? Int ?? 0, truncated: false, status: .queued, detail: "queued"))
                    }
                }
                sortSongs(); updateBusy()
                startedPath = (obj["songs"] as? [[String: Any]])?.first?["path"] as? String
            case "stage":
                guard let i = songs.firstIndex(where: { $0.path == path }) else { break }
                let detail = obj["detail"] as? String ?? ""
                if songs[i].startedAt == nil { songs[i].startedAt = Date() }
                if obj["stage"] as? String == "synth", songs[i].status != .synth { songs[i].progressStartedAt = nil; songs[i].progressStartedFraction = nil }
                if let engine = obj["engine"] as? String { songs[i].engine = engine }
                songs[i].gflops = nil
                switch obj["stage"] as? String ?? "" {
                case "queued": songs[i].status = .queued; songs[i].detail = detail; songs[i].fraction = nil
                case "planning": songs[i].status = .planning; songs[i].detail = detail; songs[i].fraction = nil
                case "tokens": songs[i].status = .tokens; songs[i].detail = detail; songs[i].fraction = nil
                case "synth": songs[i].status = .synth; songs[i].detail = detail; songs[i].fraction = nil
                case "decode": songs[i].status = .decode; songs[i].detail = detail; songs[i].fraction = nil
                case "ready": songs[i].status = .ready; songs[i].detail = ""; songs[i].fraction = nil
                case "failed": songs[i].status = .failed; songs[i].detail = detail; songs[i].fraction = nil
                case "cancelled": songs.remove(at: i); rescan()          // back to whatever is on disk (audio, tokens, or nothing)
                default: break
                }
                updateBusy()
            case "progress":
                guard let i = songs.firstIndex(where: { $0.path == path }) else { break }
                if songs[i].status == .synth, songs[i].progressStartedAt == nil, let fraction = obj["fraction"] as? Double, fraction > 0 {
                    songs[i].progressStartedAt = Date(); songs[i].progressStartedFraction = fraction
                }
                songs[i].fraction = obj["fraction"] as? Double
                songs[i].detail = obj["detail"] as? String ?? songs[i].detail
                songs[i].gflops = obj["gflops"] as? Double              // absent = no rate to show (e.g. a finished row)
            case "song":
                let song = Song(run: URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                                index: obj["index"] as? Int ?? 0, path: path, score: obj["score"] as? String ?? "",
                                seconds: obj["seconds"] as? Double ?? 0, seed: obj["seed"] as? Int ?? 0,
                                truncated: obj["truncated"] as? Bool ?? false, status: .ready, quality: obj["quality"] as? String ?? "full",
                                engine: obj["engine"] as? String ?? "")
                if let i = songs.firstIndex(where: { $0.path == path }) { songs[i] = song } else { songs.append(song) }
                sortSongs(); updateBusy()
                completedPath = path
            case "failed":
                if let i = songs.firstIndex(where: { $0.path == path }) { songs[i].status = .failed; songs[i].detail = obj["message"] as? String ?? "failed" }
                updateBusy()
            case "idle": generationReserved = false; updateBusy(); rescan()
            case "error":
                generationReserved = false; pendingGenerations = max(0, pendingGenerations - 1)
                lastError = obj["message"] as? String ?? "Unknown worker error"
                append("Worker: \(lastError ?? "error")")
                if let path = pendingRender, let i = songs.firstIndex(where: { $0.path == path }) { songs[i].status = .failed; songs[i].detail = lastError ?? "Could not start the render" }
                pendingRender = nil; updateBusy()
            default: break
            }
        }
    }

    private func workerStopped() {
        connected = false; process = nil; stdin = nil; pendingRender = nil; generationReserved = false; pendingGenerations = 0
        for i in songs.indices where songs[i].inFlight {
            songs[i].status = .failed
            songs[i].detail = "The music engine stopped. Saved work is safe. Reconnect to continue."
        }
        updateBusy(); append("Worker exited"); rescan()
    }

    func append(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append(LogLine(time: f.string(from: Date()), message: message))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    private func updateBusy() { busy = generationReserved || pendingGenerations > 0 || songs.contains { $0.inFlight } }

    /// Newest run first, songs in order within a run.
    private func sortSongs() {
        songs.sort { $0.run != $1.run ? $0.run > $1.run : $0.index < $1.index }
    }

    /// Reconcile with the songs folder: everything on disk is listed (finished songs, and songs whose
    /// tokens were saved but never synthesized), and entries whose files are gone disappear. Songs
    /// the worker is still working on, and failures of this session, are kept as they are.
    func rescan() {
        let kept = songs.filter { $0.inFlight || $0.status == .failed }
        let onDisk = Song.scan(Paths.output)
        let known = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { (a: Song, _: Song) in a })
        let keptPaths = Set(kept.map(\.path))
        songs = onDisk.filter { !keptPaths.contains($0.path) }.map { (disk: Song) -> Song in
            // A ready song we already know keeps its in-memory copy (score text etc.); stalled ones come from disk.
            if let k = known[disk.path], k.status == .ready, disk.status == .ready { return k }
            return disk
        } + kept
        sortSongs(); updateBusy()
    }

    func send(_ obj: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do { try stdin.write(contentsOf: data); try stdin.write(contentsOf: Data([0x0A])) }
        catch { lastError = "The music engine disconnected. Your saved work is safe."; workerStopped() }
    }

    /// Queue a run; the worker announces its songs with a "started" event.
    func generate(title: String, style: String, lyrics: String, cot: String, seed: Int, randomSeed: Bool, batch: Int, maxTokens: Int, engine: String, abc: String, quality: String, instrumental: Bool) {
        guard !masteringActive, connected else { lastError = "Finish mastering before starting music generation."; return }
        generationReserved = true; pendingGenerations += 1; updateBusy()
        send(["cmd": "generate", "title": title, "style": style, "lyrics": lyrics, "cot": cot, "seed": seed, "random_seed": randomSeed,
              "batch": batch, "max_tokens": maxTokens, "engine": engine, "abc": abc, "quality": quality, "instrumental": instrumental])
    }

    /// Synthesize a song from its saved tokens: a full-quality render of a draft, or a stalled song.
    func render(_ song: Song, engine: String, quality: String) {
        guard !masteringActive, connected, let i = songs.firstIndex(where: { $0.id == song.id }), !songs[i].inFlight else { return }
        generationReserved = true
        songs[i].status = .queued; songs[i].detail = "queued"; songs[i].fraction = nil; songs[i].quality = quality
        updateBusy()
        songs[i].startedAt = Date(); songs[i].progressStartedAt = nil; songs[i].progressStartedFraction = nil
        pendingRender = song.path
        send(["cmd": "render", "path": song.directory.path, "engine": engine, "quality": quality])
    }

    /// Reserve the entire audio workstation before releasing the model process.
    /// The helper also takes the same flock as the Python worker across app copies.
    func beginMastering() async throws {
        guard !busy, !masteringActive else { throw StudioFailure("Wait for the current song or mastering job to finish.") }
        masteringActive = true
        if let p = process {
            send(["cmd": "quit"])
            connected = false
            if p.isRunning { p.terminate() }
            for _ in 0..<300 {
                if !p.isRunning { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !p.isRunning else { masteringActive = false; throw StudioFailure("The music engine is still releasing memory. Try again shortly.") }
            if process === p { process = nil; stdin = nil }
        }
        buffer = Data()
        memoryMessage = "Music models released for mastering"
    }
    func endMastering() { masteringActive = false }

    /// Idle workers hold the process lease too. Release ours before a library
    /// mutation; another app instance remains protected by ProjectTrash's flock.
    func withLibraryAccess(_ operation: @escaping @MainActor () throws -> Void) {
        Task {
            let reconnect = process != nil
            do {
                try await beginMastering()
                defer { endMastering(); if reconnect { start() } }
                try operation()
            } catch { lastError = error.localizedDescription }
        }
    }

    func cancel(_ song: Song) { send(["cmd": "cancel", "path": song.path]) }
    func stop() { send(["cmd": "stop"]); append("Stop sent") }
    func quit() {
        guard let p = process else { return }
        send(["cmd": "quit"]); p.terminate(); process = nil
    }
}
