import XCTest
import Darwin
@testable import YuEStudio

final class ProjectTrashTests: XCTestCase {
    func testOwnedProjectMovePreservesSiblingAndRecoveryMetadata() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("songs"), song = library.appendingPathComponent("run/song1"), sibling = library.appendingPathComponent("run/song2")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let audio = Data("original audio".utf8)
        try audio.write(to: song.appendingPathComponent("audio.flac")); try audio.write(to: sibling.appendingPathComponent("audio.flac"))
        let trash = root.appendingPathComponent("trash")
        try ProjectTrash.move(song, root: library, depth: 2, lock: root.appendingPathComponent("worker.lock"), metadata: Data("settings".utf8), metadataName: "studio-recovery.json") {
            try FileManager.default.moveItem(at: $0, to: trash)
        }
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("audio.flac")), audio)
        XCTAssertEqual(try Data(contentsOf: sibling.appendingPathComponent("audio.flac")), audio)
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent("studio-recovery.json")), Data("settings".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: song.path))
    }
    func testRefusesLibraryRootExternalFolderAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("songs"), outside = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("run"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = library.appendingPathComponent("run/song1")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectTrash.validate(library, root: library, depth: 2))
        XCTAssertThrowsError(try ProjectTrash.validate(outside, root: library, depth: 2))
        XCTAssertThrowsError(try ProjectTrash.validate(link, root: library, depth: 2))
    }
    func testAudioLeaseBlocksMoveAndFailedMoveKeepsProject() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("run/song1"), lock = root.appendingPathComponent("worker.lock")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ProjectTrash.move(song, root: root, depth: 2, lock: lock, metadata: Data(), metadataName: "recovery.json") { _ in XCTFail("Must not move under an active lease") })
        flock(fd, LOCK_UN)
        XCTAssertThrowsError(try ProjectTrash.move(song, root: root, depth: 2, lock: lock, metadata: Data(), metadataName: "recovery.json") { _ in throw StudioFailure("Trash unavailable") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.path))
    }
    func testHiFiIsNonStackingAndPreservesCustomEQAndFades() {
        var custom = MasterParameters(); custom.eq[2].gainDb = -2.7; custom.fadeOutSec = 3; custom.deChirp = 0.21; custom.width = 0.42; custom.ceilingDb = -2
        let hifi = custom.hiFi()
        XCTAssertEqual(hifi.hiFi(), hifi)
        XCTAssertEqual(hifi.eq, custom.eq); XCTAssertEqual(hifi.fadeOutSec, 3)
        XCTAssertEqual(hifi.deChirp, 0.21); XCTAssertEqual(hifi.width, 0.42)
        XCTAssertEqual(hifi.ceilingDb, -2); XCTAssertTrue(hifi.useTruePeak)
        XCTAssertTrue(hifi.normalizeActive); XCTAssertEqual(hifi.normalizeGainDb, 0)
        XCTAssertEqual(hifi.targetLufs, -14); XCTAssertEqual(hifi.bass, 0.625)
        XCTAssertEqual(hifi.tapeHiss, custom.tapeHiss)
    }
}
