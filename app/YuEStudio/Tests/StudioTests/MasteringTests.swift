import XCTest
@testable import YuEStudio

final class MasteringTests: XCTestCase {
    func testMasterExportNeverOverwritesAnyExistingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("current.wav"), other = folder.appendingPathComponent("other-session.wav"), delivery = folder.appendingPathComponent("new.wav")
        let original = Data("another session's original".utf8), mastered = Data("verified master bytes".utf8)
        try original.write(to: other); try mastered.write(to: source)
        XCTAssertThrowsError(try ExportService.exportMaster(source: source, destination: other))
        XCTAssertThrowsError(try ExportService.exportMaster(source: source, destination: source))
        XCTAssertEqual(try Data(contentsOf: other), original)
        try ExportService.exportMaster(source: source, destination: delivery)
        XCTAssertEqual(try Data(contentsOf: delivery), mastered)
        XCTAssertEqual(try Data(contentsOf: source), mastered)
    }

    func testSparseInterfacePatchPreservesUnrelatedControls() throws {
        var custom = MasterParameters(); custom.eq[4].gainDb = 3.2; custom.eq[0].frequencyHz = 62
        let patch: [String: Any] = ["eq": ["0": ["gainDb": 0.75]]]
        let result = try JSONDecoder().decode(MasterParameters.self, from: JSONSerialization.data(withJSONObject: applyingMasterPatch(patch, to: custom.dictionary)))
        XCTAssertEqual(result.eq[4], custom.eq[4])
        XCTAssertEqual(result.eq[0].frequencyHz, 62)
        XCTAssertEqual(result.eq[0].gainDb, 0.75)
    }
    func testInterfaceParametersRoundTrip() throws {
        let original = MasterParameters()
        XCTAssertEqual(try JSONDecoder().decode(MasterParameters.self, from: JSONEncoder().encode(original)), original)
    }
    func testEditedSettingsDoNotRelabelOldAudio() throws {
        let settings = MasterParameters()
        let version = MasterVersion(id: UUID(), path: "/tmp/master.wav", created: Date(), parameters: settings, measurement: MasterMeasurement(lufs: -14, truePeak: -1, samplePeak: -1.1), preset: "Neutral")
        XCTAssertFalse(masterNeedsRender(parameters: settings, version: version))
        var edited = settings; edited.warmth = 0.25
        XCTAssertTrue(masterNeedsRender(parameters: edited, version: version))
        XCTAssertTrue(masterNeedsRender(parameters: settings, version: nil))
        let recovered = try JSONDecoder().decode(MasterVersion.self, from: JSONEncoder().encode(version))
        XCTAssertEqual(recovered.parameters, settings)
    }
    @MainActor func testMasteringReservationBlocksGenerationAndReconnect() async throws {
        let backend = Backend()
        try await backend.beginMastering()
        XCTAssertTrue(backend.masteringActive)
        backend.start()
        XCTAssertNil(backend.process)
        backend.connected = true
        backend.generate(title: "Test", style: "Test", lyrics: "Test", cot: "full", seed: 1, randomSeed: false, batch: 1, maxTokens: 1, engine: "mlx", abc: "", quality: "full", instrumental: false)
        XCTAssertNotNil(backend.lastError)
        XCTAssertFalse(backend.busy)
        backend.endMastering()
        XCTAssertFalse(backend.masteringActive)
    }
    @MainActor func testGenerationPreventsMasteringReservation() async {
        let backend = Backend(); backend.busy = true
        do { try await backend.beginMastering(); XCTFail("Mastering must not enter while generation is active") }
        catch { XCTAssertFalse(backend.masteringActive) }
    }
}
