import Foundation
import AVFoundation

/// The signed app carries its own encoding-only LAME helper, with no Homebrew runtime dependency.
enum MP3Encoder {
    static func deliveryRate(_ source: Double) -> Double {
        [32000.0, 44100.0, 48000.0].contains(source) ? source : 48000
    }

    static func encode(input: AVAudioFile, destination: URL) throws {
        guard (1...2).contains(input.processingFormat.channelCount) else {
            throw StudioFailure("MP3 export supports mono or stereo. Choose a lossless format for multichannel audio.")
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudioMP3Encoder")
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let development = root.appendingPathComponent("custom/build/mp3/lame-4.0/frontend/lame")
        let encoder = Bundle.main.bundleURL.pathExtension == "app" ? bundled : development
        guard FileManager.default.isExecutableFile(atPath: encoder.path) else {
            throw StudioFailure("The MP3 encoder is missing. Rebuild with custom/package-local.sh or reinstall YuE Studio.")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yue-mp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let wav = scratch.appendingPathComponent("input.wav")
        // Float PCM avoids reducing precision before perceptual encoding.
        try ExportService.transcode(input: input, destination: wav, format: .wavFloat)
        let process = Process()
        process.executableURL = encoder
        process.arguments = ["--silent", "--noreplaygain", "-q", "0", "-b", "320",
                             "--resample", String(deliveryRate(input.processingFormat.sampleRate) / 1000),
                             wav.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        let log = scratch.appendingPathComponent("encoder.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw StudioFailure("MP3 encoding failed. Your original is safe; try exporting again or choose a lossless format.")
        }
    }
}
