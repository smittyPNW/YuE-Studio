import XCTest
@testable import YuEStudio

final class ComposerTests: XCTestCase {
    func testExistingWorkspaceLoadsAtFullQualityAndKeepsAllText() throws {
        let json = #"{"composer":{"title":"Existing","style":"Ambient rock","lyrics":"[Verse]\nKeep my song","maxSeconds":300,"seed":42,"randomSeed":false,"instrumental":false,"abc":""},"notes":{},"drafts":{}}"#
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
        XCTAssertEqual(state.composer.quality, .full)
        XCTAssertEqual(state.composer.lyrics, "[Verse]\nKeep my song")
        var draft = state.composer
        draft.quality = .draft
        XCTAssertEqual(try JSONDecoder().decode(SongDraft.self, from: JSONEncoder().encode(draft)).quality, .draft)
        XCTAssertEqual(SongDraft().quality, .full)
    }

    @MainActor func testClearAndUndoAreIndependentAndCannotReplaceNewWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = StudioLibrary(file: root.appendingPathComponent("library.json"))
        defer { library.saveTask?.cancel() }
        let lyrics = "[Verse]\nCafé 🎶 — every word"
        library.state.composer.style = "Slow electric soul"
        library.state.composer.lyrics = lyrics
        library.clearPrompt(.style); library.clearPrompt(.lyrics)
        XCTAssertTrue(library.canRestore(.style)); XCTAssertTrue(library.canRestore(.lyrics))
        XCTAssertEqual(library.state.composer.style, ""); XCTAssertEqual(library.state.composer.lyrics, "")
        library.restorePrompt(.style); library.restorePrompt(.lyrics)
        XCTAssertEqual(library.state.composer.style, "Slow electric soul")
        XCTAssertEqual(library.state.composer.lyrics, lyrics)
        library.clearPrompt(.lyrics)
        library.state.composer.lyrics = "New work"
        library.restorePrompt(.lyrics)
        XCTAssertEqual(library.state.composer.lyrics, "New work")
        library.changed()
        library.state.composer.lyrics = ""
        XCTAssertFalse(library.canRestore(.lyrics))
        library.clearPrompt(.style); library.newSong()
        XCTAssertFalse(library.canRestore(.style))
    }

    @MainActor func testRenderActivityCoversQueueAndEndsOnWorkerIdleOrError() throws {
        let backend = Backend()
        func event(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            backend.consume(data)
        }
        backend.connected = true
        backend.generate(title: "Test", style: "Test", lyrics: "Test", cot: "full", seed: 42, randomSeed: false, batch: 1, maxTokens: 7500, engine: "mlx", abc: "", quality: "full", instrumental: false)
        XCTAssertTrue(backend.renderActivity.isActive)
        try event(["event": "error", "message": "Admission rejected"])
        XCTAssertFalse(backend.renderActivity.isActive)
        let path = "/tmp/test-song-activity/audio.flac"
        try event(["event": "started", "output": "/tmp/test-song-activity", "songs": [["path": path, "index": 1, "seed": 42]]])
        XCTAssertTrue(backend.renderActivity.isActive)
        try event(["event": "stage", "path": path, "stage": "synth"])
        XCTAssertTrue(backend.renderActivity.isActive)
        try event(["event": "stage", "path": path, "stage": "failed", "detail": "Test failure"])
        try event(["event": "idle"])
        XCTAssertFalse(backend.renderActivity.isActive)
    }
}
