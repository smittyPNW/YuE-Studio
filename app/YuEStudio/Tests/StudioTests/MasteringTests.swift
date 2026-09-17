import XCTest
@testable import YuEStudio

final class MasteringTests: XCTestCase {
    func testMasterExportNeverOverwritesAnyExistingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("current.wav"), other = folder.appendingPathComponent("other-session.wav"), delivery = folder.appendingPathComponent("new.wav")
        let original = Data("another session's original".utf8)
        try TestAudio.write(source, seconds: 0.1)
        let mastered = try Data(contentsOf: source)
        try original.write(to: other)
        XCTAssertThrowsError(try ExportService.exportMaster(source: source, destination: other))
        XCTAssertThrowsError(try ExportService.exportMaster(source: source, destination: source))
        XCTAssertEqual(try Data(contentsOf: other), original)
        try ExportService.exportMaster(source: source, destination: delivery)
        XCTAssertEqual(try Data(contentsOf: delivery), mastered)
        XCTAssertEqual(try Data(contentsOf: source), mastered)
    }

    func testQuickRepairPreservesUnrelatedCustomEQ() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("custom/Assets/StudioMasteringCatalog.json"))) as! [String:Any]
        let repairs = catalog["repairs"] as! [[String:Any]]
        var custom = MasterParameters(); custom.eq[4].gainDb = 3.2; custom.eq[0].frequencyHz = 62; custom.eq[0].enabled = false
        for name in ["Stereo", "Bass"] {
            let patch = repairs.first { $0["name"] as? String == name }!["patch"]!
            let result = try JSONDecoder().decode(MasterParameters.self, from: JSONSerialization.data(withJSONObject: applyingMasterPatch(patch, to: custom.dictionary)))
            XCTAssertEqual(result.eq[4], custom.eq[4])
            XCTAssertEqual(result.eq[0].frequencyHz, 62)
            XCTAssertFalse(result.eq[0].enabled)
            if name == "Bass" { XCTAssertEqual(result.eq[0].gainDb, 1.5) }
        }
    }
    func testPresetCatalogDecodesEveryControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("custom/Assets/StudioMasteringCatalog.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let presets = try JSONDecoder().decode([MasterPreset].self, from: JSONSerialization.data(withJSONObject: json["presets"]!))
        XCTAssertEqual(presets.count, 43)
        for preset in presets { XCTAssertEqual(preset.parameters.eq.count, 6); XCTAssertTrue(preset.parameters.targetLufs.isFinite) }
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
