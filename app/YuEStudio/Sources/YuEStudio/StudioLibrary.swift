import SwiftUI
import Observation

struct SongDraft: Codable, Equatable {
    var title = "Untitled song"
    var style = ""
    var lyrics = ""
    var maxSeconds = 300.0
    var seed = 831001
    var randomSeed = true
    var instrumental = false
    var abc = ""
}

struct SongNotes: Codable {
    var title: String
    var favorite = false
}

struct SongRecovery: Codable { var note: SongNotes?; var draft: SongDraft? }

struct LibraryState: Codable {
    var composer = SongDraft()
    var selected: String?
    var notes: [String: SongNotes] = [:]
    var drafts: [String: SongDraft] = [:]
}

@MainActor @Observable
final class StudioLibrary {
    var state: LibraryState
    var search = ""
    var favoritesOnly = false
    var showInspector = false
    var showLog = false
    var showScore = false
    var importText = ""
    var error: String?
    var notice: String?
    var saveTask: Task<Void,Never>?
    private let file = Paths.custom.appendingPathComponent("library.json")

    init() {
        state = (try? JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: file))) ?? LibraryState()
    }
    var valid: Bool { !state.composer.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (state.composer.instrumental || !state.composer.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var wordCount: Int { state.composer.lyrics.split(whereSeparator: { $0.isWhitespace }).count }
    var sections: [String] { state.composer.lyrics.components(separatedBy: .newlines).filter { $0.hasPrefix("[") && $0.hasSuffix("]") } }
    func changed() {
        if let key = state.selected {
            state.drafts[key] = state.composer
            state.notes[key] = SongNotes(title: state.composer.title, favorite: state.notes[key]?.favorite ?? false)
        }
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { save() } }
    }
    func save() {
        do { try FileManager.default.createDirectory(at: Paths.custom, withIntermediateDirectories: true); try JSONEncoder().encode(state).write(to: file, options: .atomic) }
        catch { self.error = "Could not save your workspace: \(error.localizedDescription)" }
    }
    func title(_ song: Song) -> String { state.notes[song.id]?.title ?? "Song \(song.index)" }
    func favorite(_ song: Song) { var note = state.notes[song.id] ?? SongNotes(title: title(song)); note.favorite.toggle(); state.notes[song.id] = note; save() }
    func register(_ songs: [Song]) {
        for song in songs where state.notes[song.id] == nil {
            if let data = try? Data(contentsOf: song.directory.appendingPathComponent("studio-recovery.json")),
               let recovery = try? JSONDecoder().decode(SongRecovery.self, from: data) {
                state.notes[song.id] = recovery.note
                state.drafts[song.id] = recovery.draft
                if recovery.note != nil { continue }
            }
            let json = readJSON(song.directory.appendingPathComponent("studio.json"))
            let request = readJSON(song.directory.appendingPathComponent("request.json"))
            let lyric = request["lyrics"] as? String ?? ""
            let inferred = lyric.contains("Tell me what you love") ? "What Do You Love?" : "Song \(song.index) · \(song.runLabel)"
            state.notes[song.id] = SongNotes(title: json["title"] as? String ?? inferred)
        }
        save()
    }
    func select(_ song: Song) {
        changed(); saveTask?.cancel(); save()
        state.selected = song.id
        if let draft = state.drafts[song.id] { state.composer = draft }
        else {
            var request = readJSON(song.directory.appendingPathComponent("request.json"))
            if request.isEmpty { request = readJSON(song.directory.appendingPathComponent("studio-job.json")) }
            state.composer = SongDraft(title: title(song), style: request["style"] as? String ?? "", lyrics: request["lyrics"] as? String ?? "", maxSeconds: 300, seed: request["seed"] as? Int ?? song.seed, randomSeed: true, instrumental: request["instrumental"] as? Bool ?? false)
        }
        save()
    }
    func newSong() {
        changed(); saveTask?.cancel(); save()
        state.selected = nil; state.composer = SongDraft(); save()
    }
    func moveToTrash(_ song: Song, backend: Backend, player: StudioPlayer) {
        guard !backend.busy, !backend.masteringActive, !song.inFlight else { error = "Let the current audio job finish before deleting a project."; return }
        backend.withLibraryAccess { [self] in
        do {
            changed(); saveTask?.cancel(); save()
            let draft = state.selected == song.id ? state.composer : state.drafts[song.id]
            let recovery = SongRecovery(note: state.notes[song.id], draft: draft)
            try ProjectTrash.move(song.directory, root: Paths.output, depth: 2,
                                  lock: Paths.custom.appendingPathComponent("worker.lock"),
                                  metadata: JSONEncoder().encode(recovery), metadataName: "studio-recovery.json")
            if player.songID == song.id { player.clear() }
            state.notes.removeValue(forKey: song.id); state.drafts.removeValue(forKey: song.id)
            if state.selected == song.id { state.selected = nil; state.composer = SongDraft() }
            backend.songs.removeAll { $0.id == song.id }; backend.rescan(); save()
        } catch { self.error = "Could not move the song to Trash: \(error.localizedDescription)" }
    }
    }

    func filtered(_ songs: [Song]) -> [Song] {
        songs.filter { (!favoritesOnly || state.notes[$0.id]?.favorite == true) && (search.isEmpty || title($0).localizedCaseInsensitiveContains(search)) }
    }
    func readJSON(_ url: URL) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:] }
    func importPrompt() {
        // The songwriter skill emits style first, lyrics second, in fenced text blocks.
        let chunks = importText.components(separatedBy: "```")
        let blocks = stride(from: 1, to: chunks.count, by: 2).map { i -> String in
            var lines = chunks[i].components(separatedBy: "\n")
            if let first = lines.first, ["text", "plaintext", ""].contains(first.trimmingCharacters(in: .whitespaces)) { lines.removeFirst() }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard blocks.count == 2, !blocks[0].isEmpty, !blocks[1].isEmpty else { error = "Paste the songwriter response with two fenced blocks: style first, lyrics second. Your existing song has not changed."; return }
        state.composer.style = blocks[0]; state.composer.lyrics = blocks[1]; changed(); importText = ""
        notice = "Style and lyrics imported. Review them before generating."
    }
}
