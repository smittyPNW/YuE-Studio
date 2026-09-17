import XCTest
import AVFoundation
@testable import YuEStudio

enum TestAudio {
    static func write(_ url: URL, rate: Double = 48000, channels: AVAudioChannelCount = 2, seconds: Double = 3, amplitude: Float = 0.2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = amplitude * Float(sin(Double(frame) * (channel == 0 ? 0.071 : 0.043)))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: AudioExportFormat.wav24.settings(sampleRate: rate, channels: channels))
        try file.write(from: buffer)
    }
    static func samples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
        var result = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw StudioFailure("Decoded audio ended early") }
            for channel in result.indices {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }
}

final class AudioDeliveryTests: XCTestCase {
    func testEveryFormatFromGeneratedFLACAndMasteredWAV() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (rate, channels) in [(44100.0, UInt32(2)), (48000.0, UInt32(1)), (96000.0, UInt32(2))] {
            let wav = folder.appendingPathComponent("source-\(rate).wav")
            let flac = folder.appendingPathComponent("source-\(rate).flac")
            try TestAudio.write(wav, rate: rate, channels: channels, seconds: 0.5)
            let original = try Data(contentsOf: wav)
            let samples = try TestAudio.samples(wav)
            try ExportService.export(source: wav, destination: flac, format: .flac)
            for (index, source) in [wav, flac].enumerated() {
                for format in AudioExportFormat.allCases {
                    let delivery = folder.appendingPathComponent("\(rate)-\(index)-\(format.rawValue).\(format.fileExtension)")
                    if format == .aac && rate > 48000 {
                        XCTAssertThrowsError(try ExportService.export(source: source, destination: delivery, format: format))
                        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.path))
                        continue
                    }
                    try ExportService.exportMaster(source: source, destination: delivery, format: format)
                    let file = try AVAudioFile(forReading: delivery)
                    let expectedRate = format == .mp3 ? MP3Encoder.deliveryRate(rate) : rate
                    XCTAssertEqual(file.processingFormat.sampleRate, expectedRate, format.title)
                    XCTAssertEqual(file.processingFormat.channelCount, channels, format.title)
                    if format != .aac && format != .mp3 {
                        let decoded = try TestAudio.samples(delivery)
                        let maximumError = zip(decoded.flatMap { $0 }, samples.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
                        XCTAssertTrue(decoded == samples, "\(format.title), rate \(rate), source \(index): max error \(maximumError), decoded counts \(decoded.map(\.count)), expected \(samples.map(\.count)), file frames \(file.length)")
                    }
                    else {
                        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, format == .mp3 ? kAudioFormatMPEGLayer3 : kAudioFormatMPEG4AAC)
                        XCTAssertLessThanOrEqual(abs(Double(file.length) / expectedRate - 0.5), 2304 / expectedRate)
                        let decoded = try TestAudio.samples(delivery).flatMap { $0 }
                        let reference = samples.flatMap { $0 }
                        let energy = decoded.reduce(0.0) { $0 + Double($1 * $1) } / Double(decoded.count)
                        let referenceEnergy = reference.reduce(0.0) { $0 + Double($1 * $1) } / Double(reference.count)
                        XCTAssertTrue((0.8...1.2).contains(sqrt(energy / referenceEnergy)), "Compressed export must preserve listening level")
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }

    func testFailedExportsLeaveNoPartialFileAndNeverOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        try TestAudio.write(source, seconds: 0.1)
        let original = try Data(contentsOf: source)
        for format in AudioExportFormat.allCases {
            let target = folder.appendingPathComponent("existing.\(format.fileExtension)")
            if !FileManager.default.fileExists(atPath: target.path) { try original.write(to: target) }
            XCTAssertThrowsError(try ExportService.export(source: source, destination: target, format: format))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
        let broken = folder.appendingPathComponent("broken.wav")
        try Data("invalid audio".utf8).write(to: broken)
        XCTAssertThrowsError(try ExportService.export(source: broken, destination: folder.appendingPathComponent("new.flac"), format: .flac))
        XCTAssertThrowsError(try ExportService.export(source: source, destination: folder.appendingPathComponent("wrong.mp3"), format: .aiff))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".yue-export") || $0 == "new.flac" || $0 == "wrong.mp3" })
    }

    func testMaxVolumePreservesToneAndEnforcesSafeDelivery() {
        var settings = MasterParameters()
        settings.bass = 0.62; settings.eq[3].gainDb = 1.5; settings.width = 0.56
        settings.masterVolDb = 18; settings.finalCharacter = 4; settings.useTruePeak = false
        let result = settings.maxVolume()
        XCTAssertEqual(result.bass, settings.bass)
        XCTAssertEqual(result.eq, settings.eq)
        XCTAssertEqual(result.width, settings.width)
        XCTAssertTrue(result.normalizeActive)
        XCTAssertTrue(result.useTruePeak)
        XCTAssertEqual(result.targetLufs, -9)
        XCTAssertEqual(result.ceilingDb, -1)
        XCTAssertEqual(result.masterVolDb, 0)
        XCTAssertEqual(result.finalCharacter, 0)
        settings.ceilingDb = -2
        XCTAssertEqual(settings.maxVolume().ceilingDb, -2)
    }

    @MainActor func testABSwitchingUsesCorrectAudioAndPreservesPositionAndTransport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = folder.appendingPathComponent("before.wav")
        let after = folder.appendingPathComponent("after.wav")
        let second = folder.appendingPathComponent("second.wav")
        try TestAudio.write(before)
        try TestAudio.write(after, amplitude: 0.6)
        try TestAudio.write(second, amplitude: 0.4)
        let model = MasteringController(libraryURL: folder.appendingPathComponent("library.json"), root: folder.appendingPathComponent("sessions"))
        var session = MasterSession(title: "A/B regression", source: before.path, originalName: "before.wav")
        session.measurement = MasterMeasurement(lufs: -20, truePeak: -10, samplePeak: -10)
        let one = MasterVersion(id: UUID(), path: after.path, created: Date(), parameters: MasterParameters(), measurement: MasterMeasurement(lufs: -10, truePeak: -1, samplePeak: -1), preset: "One")
        let two = MasterVersion(id: UUID(), path: second.path, created: Date(), parameters: MasterParameters(), measurement: MasterMeasurement(lufs: -14, truePeak: -1, samplePeak: -1), preset: "Two")
        session.versions = [one, two]
        model.library = MasterLibrary(sessions: [session], selected: session.id)
        model.selectedVersion = one.id
        model.audition()
        try await settle(model.player)
        model.player.seek(1.25)
        try await settle(model.player)
        model.after = true
        try await settle(model.player)
        XCTAssertEqual(model.player.currentAssetURL, after)
        XCTAssertEqual(model.player.actualPosition, 1.25, accuracy: 0.03)
        XCTAssertFalse(model.player.playing)
        XCTAssertEqual(model.player.effectiveVolume, 0.85 * Float(pow(10, -10.0 / 20)), accuracy: 0.001)
        model.matchListeningLevel = false
        XCTAssertEqual(model.player.effectiveVolume, 0.85, accuracy: 0.001)
        model.matchListeningLevel = true
        model.selectedVersion = two.id
        try await settle(model.player)
        XCTAssertEqual(model.player.currentAssetURL, second)
        XCTAssertEqual(model.player.actualPosition, 1.25, accuracy: 0.03)
        XCTAssertEqual(model.player.effectiveVolume, 0.85 * Float(pow(10, -6.0 / 20)), accuracy: 0.001)
        // Silence the test while exercising the real AVPlayer transport.
        model.player.volume = 0
        model.player.toggle()
        model.after = false; model.after = true; model.after = false
        try await settle(model.player)
        XCTAssertEqual(model.player.currentAssetURL, before)
        XCTAssertTrue(model.player.playing)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(model.player.actualPosition, 1.25)
        model.player.pause()
        model.after = true
        model.player.pause()
        try await settle(model.player)
        XCTAssertFalse(model.player.playing)
        // A missing master must stop playback, never leave Before playing as After.
        try FileManager.default.removeItem(at: after)
        model.selectedVersion = one.id
        XCTAssertNil(model.player.currentAssetURL)
        XCTAssertFalse(model.player.playing)
        XCTAssertNotNil(model.player.error)
        model.after = false
        try await settle(model.player)
        XCTAssertEqual(model.player.currentAssetURL, before)
        XCTAssertNil(model.player.error)
        model.player.clear()
    }

    @MainActor private func settle(_ player: StudioPlayer) async throws {
        for _ in 0..<100 {
            if !player.isSwitching { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("AVPlayer did not finish seeking")
    }
}
