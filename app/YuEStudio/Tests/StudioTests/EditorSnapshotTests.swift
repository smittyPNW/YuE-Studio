import XCTest
import SwiftUI
import AppKit
@testable import YuEStudio

final class EditorSnapshotTests: XCTestCase {
    @MainActor func testEditorLayoutSnapshotsWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["YUE_EDITOR_SNAPSHOT_DIR"] else { throw XCTSkip("Optional local layout snapshots") }
        _ = NSApplication.shared
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let icon = NSImage(contentsOf: repository.appendingPathComponent("custom/Assets/AppIcon.png"))
        icon?.setName(NSImage.Name("AppIcon"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source: URL
        if let path = ProcessInfo.processInfo.environment["YUE_EDITOR_TEST_AUDIO"] { source = URL(fileURLWithPath: path) }
        else { source = temporary.appendingPathComponent("source.wav"); try TestAudio.write(source, seconds: 6) }
        let input = try EditAudio.file(source)
        let model = EditController(root: temporary, lock: temporary.appendingPathComponent("snapshot.lock"))
        model.project = EditProject(document: EditDocument(title: "Tool Me Fool Me", sampleRate: input.processingFormat.sampleRate, channels: input.processingFormat.channelCount, clips: [EditClip(asset: "source.wav", start: 0, count: input.length, name: "Original recording")], markers: []))
        model.preview = source; model.folder = temporary; model.waveform = try EditWaveform.read(source)
        model.statistics = try EditAudio.analyze(source); model.fit(); model.selectionStart = 0; model.selectionEnd = 0
        model.status = "Open recording · saved. Original preserved."
        model.items = [EditLibraryItem(folder: temporary, title: "Tool Me Fool Me")]
        let backend = Backend(), library = StudioLibrary(), player = StudioPlayer(), mastering = MasteringController()
        backend.rescan(); library.register(backend.songs)
        editorDefaults: do {
            let oldMode = UserDefaults.standard.object(forKey: "workspace"), oldAppearance = UserDefaults.standard.object(forKey: "appearance")
            defer {
                UserDefaults.standard.set(oldMode, forKey: "workspace"); UserDefaults.standard.set(oldAppearance, forKey: "appearance")
            }
            for (mode, dark) in [("edit", true), ("edit", false), ("create", true), ("master", false)] {
            UserDefaults.standard.set(mode, forKey: "workspace"); UserDefaults.standard.set(dark ? "dark" : "light", forKey: "appearance")
            if mode == "create", let song = backend.songs.first(where: { $0.id == library.state.selected }) { player.load(song, title: library.title(song)) }
            if mode == "master" { mastering.audition() }
            let content = StudioRoot(library: library, player: player, mastering: mastering, editor: model, startServices: false)
                .environmentObject(backend).frame(width: 1240, height: 860)
            let view = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 1240, height: 860)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let target = URL(fileURLWithPath: directory).appendingPathComponent("\(mode)-\(dark ? "dark" : "light").png")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            window.contentView = nil
            }
        }
    }
}
