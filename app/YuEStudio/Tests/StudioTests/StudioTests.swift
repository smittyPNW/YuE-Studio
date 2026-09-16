import XCTest
import AVFoundation
@testable import YuEStudio

final class StudioTests: XCTestCase {
    func testSectionOffsetsPreserveUnicodeLyrics() {
        let lyrics = "[Verse]\nCafé 🎶\n\n[Chorus]\nWhat do you love?\n[Chorus]\nLove."
        let sections = lyricSections(lyrics)
        XCTAssertEqual(sections.map(\.title), ["Verse", "Chorus", "Chorus"])
        XCTAssertEqual((lyrics as NSString).substring(with: sections[1].range), "[Chorus]")
        XCTAssertNotEqual(sections[1].id, sections[2].id)
    }
    func testDraftRoundTripDoesNotChangeLyricsOrStyle() throws {
        let draft = SongDraft(title: "A song", style: "Warm organ, 104 BPM", lyrics: "[Verse]\nDon't change — my words 🎵", maxSeconds: 300, seed: 42, randomSeed: false)
        let recovered = try JSONDecoder().decode(SongDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(recovered, draft)
    }
    func testWaveformAndWAVExportKeepSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("source.wav")
        let outputURL = directory.appendingPathComponent("export.wav")
        let settings: [String:Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 0.05)) * 0.5 } }
        do { let file = try AVAudioFile(forWriting: inputURL, settings: settings); try file.write(from: buffer) }
        let waveform = try WaveformReader.read(inputURL)
        XCTAssertEqual(waveform.seconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(waveform.peaks.count, 700)
        XCTAssertGreaterThan(waveform.peaks.max()!, 0.49)
        try ExportService.export(source: inputURL, destination: outputURL, wav: true)
        let output = try AVAudioFile(forReading: outputURL)
        let recovered = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4800)!
        try output.read(into: recovered)
        XCTAssertEqual(recovered.frameLength, buffer.frameLength)
        for channel in 0..<2 { for i in 0..<4800 { XCTAssertEqual(recovered.floatChannelData![channel][i], buffer.floatChannelData![channel][i]) } }
    }
    func testScanRecognizesRecoverableCompositionAndPersistedError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let song = root.appendingPathComponent("run/song1")
        try FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: song.appendingPathComponent("semantic.npy"))
        try Data("{}".utf8).write(to: song.appendingPathComponent("plan_manifest.json"))
        try Data("{\"detail\":\"GPU failure; saved work is safe\"}".utf8).write(to: song.appendingPathComponent("studio-state.json"))
        let found = Song.scan(root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].status, .stalled)
        XCTAssertEqual(found[0].detail, "GPU failure; saved work is safe")
    }
}
