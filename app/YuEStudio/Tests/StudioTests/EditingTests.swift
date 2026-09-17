import XCTest
import AVFoundation
@testable import YuEStudio

final class EditingTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Studio-edit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    @discardableResult private func write(_ samples: [[Float]], name: String = "source.wav", rate: Double = 48000) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let output = try EditAudio.writer(url, rate: rate, channels: UInt32(samples.count))
        let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: UInt32(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for c in samples.indices { for i in samples[c].indices { buffer.floatChannelData![c][i] = samples[c][i] } }
        try output.write(from: buffer); return url
    }
    private func doc(_ count: Int64, channels: UInt32 = 2) -> EditDocument {
        EditDocument(title: "Test", sampleRate: 48000, channels: channels, clips: [EditClip(asset: "source.wav", start: 0, count: count, name: "Original")])
    }
    private func render(_ document: EditDocument) throws -> [[Float]] {
        let output = folder.appendingPathComponent("render-\(UUID().uuidString).wav")
        try EditAudio.render(document, folder: folder, destination: output)
        return try TestAudio.samples(output)
    }
    private func processed(_ effect: EditEffect, count: Int64, range: Range<Int64>? = nil) throws -> [[Float]] {
        let output = folder.appendingPathComponent("effect-\(UUID().uuidString).wav")
        try EditAudio.process(effect, source: folder.appendingPathComponent("source.wav"), range: range ?? 0..<count, destination: output)
        return try TestAudio.samples(output)
    }
    func testCutSplitPasteTrimAndReorderPreserveExactSamples() throws {
        let samples: [[Float]] = [(0..<1000).map { Float($0) / 1024 }, (0..<1000).map { -Float($0) / 2048 }]
        let source = try write(samples); let original = try Data(contentsOf: source)
        var document = doc(1000)
        document.split(at: 333)
        XCTAssertEqual(document.clips.count, 2); XCTAssertEqual(try render(document), samples)
        let copied = document.slice(100..<200)
        document.replace(100..<200, with: [])
        document.replace(700..<700, with: copied)
        var expected = samples.map { Array($0[0..<100]) + Array($0[200..<800]) + Array($0[100..<200]) + Array($0[800..<1000]) }
        XCTAssertEqual(try render(document), expected)
        document.trim(to: 50..<950); expected = expected.map { Array($0[50..<950]) }
        XCTAssertEqual(try render(document), expected)
        document = doc(1000); document.split(at: 400); document.moveClip(0, by: 1)
        XCTAssertEqual(try render(document), samples.map { Array($0[400..<1000]) + Array($0[0..<400]) })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testMarkersFollowRippleTrimAndContentReorder() {
        var document = doc(1000)
        document.markers = [EditMarker(frame: 50, name: "Intro"), EditMarker(frame: 550, name: "Chorus"), EditMarker(frame: 900, name: "Outro")]
        document.replace(100..<300, with: [])
        XCTAssertEqual(document.markers.map(\.frame), [50,350,700])
        document.trim(to: 100..<800)
        XCTAssertEqual(document.markers.map(\.frame), [250,600])
        document.split(at: 300); document.moveClip(0, by: 1)
        // Existing delete seams produce several clips; test a clean two-clip permutation separately.
        document = doc(1000); document.split(at: 400)
        document.markers = [EditMarker(frame: 100, name: "A"), EditMarker(frame: 500, name: "B")]
        document.moveClip(0, by: 1)
        XCTAssertEqual(document.markers.map(\.frame), [700,100])
    }
    func testSavedUndoRedoRestoresOriginalArrangementAndClearsRedoBranch() throws {
        let original = doc(1000)
        var project = EditProject(document: original), next = original
        next.replace(200..<500, with: []); project.record(next, name: "Cut")
        try project.save(folder)
        project = try EditProject.read(folder); project.stepBack()
        XCTAssertEqual(project.document, original)
        project.stepForward(); XCTAssertEqual(project.document, next)
        project.stepBack(); project.record(original, name: "New branch")
        XCTAssertTrue(project.redo.isEmpty)
    }
    func testReverseAcrossBlockBoundariesAndStereoTools() throws {
        let samples: [[Float]] = [(0..<70001).map { Float($0 % 100) / 100 }, (0..<70001).map { -Float($0 % 70) / 100 }]
        try write(samples)
        XCTAssertEqual(try processed(.reverse, count: 70001), samples.map { Array($0.reversed()) })
        XCTAssertEqual(try processed(.swap, count: 70001), [samples[1],samples[0]])
        XCTAssertEqual(try processed(.invert, count: 70001), samples.map { $0.map { -$0 } })
        let mono = try processed(.mono, count: 70001)
        XCTAssertEqual(mono[0], mono[1]); XCTAssertEqual(mono[0][1234], (samples[0][1234] + samples[1][1234]) * 0.5)
    }
    func testFadesGainRampNormalizationSilenceAndDC() throws {
        let samples = [[Float](repeating: 0.25, count: 1000), [Float](repeating: -0.5, count: 1000)]
        try write(samples)
        let fadeIn = try processed(.fadeIn, count: 1000), fadeOut = try processed(.fadeOut, count: 1000)
        XCTAssertEqual(fadeIn[0].first, 0); XCTAssertEqual(fadeIn[0].last, 0.25)
        XCTAssertEqual(fadeOut[1].first, -0.5); XCTAssertEqual(fadeOut[1].last, 0)
        let norm = try processed(.normalize(-1), count: 1000)
        XCTAssertEqual(abs(norm[1][0]), Float(pow(10, -1.0 / 20)), accuracy: 1e-7)
        XCTAssertEqual(norm[0][0] / norm[1][0], -0.5)
        XCTAssertTrue(try processed(.removeDC, count: 1000).flatMap { $0 }.allSatisfy { $0 == 0 })
        XCTAssertTrue(try processed(.silence, count: 1000).flatMap { $0 }.allSatisfy { $0 == 0 })
        let ramp = try processed(.ramp(0, -6), count: 1000)
        XCTAssertEqual(ramp[0][0], 0.25); XCTAssertEqual(ramp[0][999], Float(0.25 * pow(10, -6.0 / 20)), accuracy: 1e-7)
        XCTAssertEqual(try processed(.gain(0), count: 1000), samples)
    }
    func testSelectionEffectDoesNotChangeSurroundingSamples() throws {
        let samples = [(0..<1000).map { Float($0) / 2000 }]; try write(samples)
        let output = folder.appendingPathComponent("edit.wav")
        try EditAudio.process(.gain(-6), source: folder.appendingPathComponent("source.wav"), range: 300..<600, destination: output)
        var document = doc(1000, channels: 1)
        document.replace(300..<600, with: [EditClip(asset: "edit.wav", start: 0, count: 300, name: "Gain")])
        let result = try render(document)[0]
        XCTAssertEqual(Array(result[..<300]), Array(samples[0][..<300])); XCTAssertEqual(Array(result[600...]), Array(samples[0][600...]))
        XCTAssertEqual(result[400], samples[0][400] * Float(pow(10,-6.0 / 20)), accuracy: 1e-7)
    }
    func testClickRepairUsesSurroundingAudioAndRejectsBroadSelections() throws {
        var samples: [Float] = (0..<1000).map { Float($0) / 2000 }; samples[500] = 0.99
        try write([samples])
        XCTAssertEqual(try processed(.repairClick, count: 1000, range: 500..<501)[0][0], 0.25, accuracy: 1e-7)
        XCTAssertThrowsError(try processed(.repairClick, count: 1000, range: 0..<1))
        XCTAssertThrowsError(try processed(.repairClick, count: 1000, range: 200..<400))
    }
    func testCrossfadeDurationEndpointsAndConstantSignal() throws {
        try write([[Float](repeating: 0.5, count: 2000), [Float](repeating: -0.5, count: 2000)])
        let output = folder.appendingPathComponent("overlap.wav")
        try EditAudio.crossfade(source: folder.appendingPathComponent("source.wav"), boundary: 1000, frames: 100, destination: output)
        var document = doc(2000)
        document.replace(900..<1100, with: [EditClip(asset: "overlap.wav", start: 0, count: 100, name: "Crossfade")])
        let result = try render(document)
        XCTAssertEqual(result[0].count, 1900)
        for sample in result[0] { XCTAssertEqual(sample, 0.5, accuracy: 1e-7) }
    }
    func testFilterAttenuationWithoutChangingFrameCount() throws {
        let dc = [Float](repeating: 0.5, count: 48000); try write([dc])
        let high = try processed(.highPass(80), count: 48000)[0]
        XCTAssertEqual(high.count, dc.count); XCTAssertLessThan(abs(high.last!), 1e-5)
        let low = try processed(.lowPass(1000), count: 48000)[0]
        XCTAssertEqual(low.last!, 0.5, accuracy: 1e-5)
    }
    func testWaveformPyramidAndSpectrumKeepOutOfPhaseStereoVisible() throws {
        let samples: [Float] = (0..<48000).map { 0.5 * Float(sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        let source = try write([samples, samples.map { -$0 }])
        let wave = try EditWaveform.read(source)
        XCTAssertEqual(wave.frames, 48000); XCTAssertEqual(wave.levels[0].count, 2)
        XCTAssertEqual(try EditWaveform.samples(source, range: 123..<333)[0], Array(samples[123..<333]))
        let spectrum = try EditSpectrum.read(source, range: 0..<48000)
        let peak = spectrum.magnitudes.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(Double(peak) * 48000 / 4096, 1000, accuracy: 12)
        XCTAssertGreaterThan(spectrum.magnitudes[peak], -15)
    }
    func testInvalidAssetsRangesAndOverwriteAreRejected() throws {
        let source = try write([[0.0, 0.5, -0.5]])
        let original = try Data(contentsOf: source)
        var document = doc(3, channels: 1)
        document.clips[0].asset = "../source.wav"; XCTAssertThrowsError(try render(document))
        document = doc(4, channels: 1); XCTAssertThrowsError(try render(document))
        XCTAssertThrowsError(try EditAudio.render(doc(3, channels: 1), folder: folder, destination: source))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor func testEditorImportUndoReopenAndGenerationExclusion() async throws {
        let source = try write([[Float](repeating: 0.2, count: 1000)])
        let backend = Backend(), model = EditController(root: folder.appendingPathComponent("Projects"), lock: folder.appendingPathComponent("test.lock"))
        model.backend = backend
        model.importAudio(source)
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.error); XCTAssertEqual(model.frames, 1000)
        model.selectionStart = 100; model.selectionEnd = 200; model.deleteSelection()
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.frames, 900); XCTAssertNil(model.error)
        model.undo()
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.frames, 1000)
        let saved = try EditProject.read(XCTUnwrap(model.folder))
        XCTAssertEqual(saved.document.frames, 1000); XCTAssertEqual(saved.redo.count, 1)
        try await backend.beginMastering()
        model.importAudio(source); XCTAssertNotNil(model.error)
        XCTAssertTrue(backend.masteringActive); backend.endMastering()
        model.transport.pause()
    }
    func testQuietCrossingFindsNearbyLowEnergyBoundary() throws {
        let samples: [Float] = (0..<2048).map { Float(sin(Double($0) * .pi / 32)) }
        let url = try write([samples])
        let frame = try EditAudio.quietCrossing(url, near: 1000)
        XCTAssertLessThan(abs(samples[Int(frame)]), 0.1)
        XCTAssertEqual(try EditAudio.quietCrossing(url, near: 0), 0)
    }
    @MainActor func testTransportStopsAtSelectionAndLoopsWithinBounds() async throws {
        let source = try write([[Float](repeating: 0.1, count: 48000)])
        let player = EditTransport(); player.volume = 0
        try player.load(source); player.seek(12000); player.toggle(selection: 12000..<14400)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(player.playing); XCTAssertEqual(player.frame, 14400)
        player.loop = true; player.toggle(selection: 12000..<14400)
        try await Task.sleep(for: .milliseconds(175))
        XCTAssertTrue(player.playing); XCTAssertTrue((12000...14400).contains(player.frame))
        player.pause(); XCTAssertFalse(player.playing)
        player.seek(100); XCTAssertEqual(player.frame, 100)
    }
    func testMalformedFrameCountsAreRejectedWithoutOverflow() {
        var document = doc(10)
        document.clips[0].count = Int64.min; XCTAssertThrowsError(try document.validate())
        document.clips[0].count = Int64.max; XCTAssertThrowsError(try document.validate())
        document.clips[0].count = 10; document.clips[0].start = Int64.max; XCTAssertThrowsError(try document.validate())
    }
    func testRealRecordingRoundTripWhenSupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["YUE_EDITOR_TEST_AUDIO"] else { throw XCTSkip("Set YUE_EDITOR_TEST_AUDIO for a local existing-song regression") }
        let source = URL(fileURLWithPath: path), original = try Data(contentsOf: source)
        let input = try EditAudio.file(source)
        let asset = "original." + source.pathExtension
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(asset))
        let document = EditDocument(title: "Existing recording", sampleRate: input.processingFormat.sampleRate, channels: input.processingFormat.channelCount,
            clips: [EditClip(asset: asset, start: 0, count: input.length, name: "Existing")])
        let rendered = folder.appendingPathComponent("preview.wav")
        try EditAudio.render(document, folder: folder, destination: rendered)
        let compared = try EditAudio.file(rendered)
        XCTAssertEqual(compared.length, input.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: compared.processingFormat, frameCapacity: EditAudio.chunk)!
        try EditAudio.blocks(input, range: 0..<input.length) { reference, _ in
            try compared.read(into: buffer, frameCount: reference.frameLength)
            XCTAssertEqual(reference.frameLength, buffer.frameLength)
            for channel in 0..<Int(input.processingFormat.channelCount) {
                let a = UnsafeBufferPointer(start: reference.floatChannelData![channel], count: Int(reference.frameLength))
                let b = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
                XCTAssertTrue(a.elementsEqual(b))
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

}
