import XCTest
@testable import YuEStudio

final class WorkerLeaseTests: XCTestCase {
    @MainActor func testIdleWorkerReleasesRealLeaseBeforeProjectMove() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("run/song1"), lock = root.appendingPathComponent("worker.lock"), ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,time,pathlib; f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(60)", lock.path, ready.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let backend = Backend(); backend.process = process
        try await backend.beginMastering()
        defer { backend.endMastering() }
        XCTAssertFalse(process.isRunning)
        let trash = root.appendingPathComponent("trash")
        try ProjectTrash.move(song, root: root, depth: 2, lock: lock, metadata: Data(), metadataName: "recovery.json") { try FileManager.default.moveItem(at: $0, to: trash) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }
}
