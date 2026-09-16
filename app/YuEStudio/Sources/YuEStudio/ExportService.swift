import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

enum ExportService {
    @MainActor static func choose(song: Song, title: String, wav: Bool, completion: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [wav ? .wav : UTType(filenameExtension: "flac")!]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + (wav ? ".wav" : ".flac")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .utility) { try export(source: URL(fileURLWithPath: song.path), destination: destination, wav: wav) }.value
                    completion("Exported \(destination.lastPathComponent)")
                } catch { completion("Export failed: \(error.localizedDescription)") }
            }
        }
    }
    /// Mastering exports are new deliveries. An exclusive atomic rename also
    /// protects other sessions and files created after the save panel closes.
    static func exportMaster(source: URL, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StudioFailure("Choose a new filename. Existing audio is never overwritten by mastering export.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".yue-master-export-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let result = temporary.path.withCString { from in destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    static func export(source: URL, destination: URL, wav: Bool) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw CocoaError(.fileWriteFileExists) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".yue-export-\(UUID().uuidString).\(wav ? "wav" : "flac")")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if wav {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
            let output = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw CocoaError(.fileReadUnknown) }
            while input.framePosition < input.length { try input.read(into: buffer); try output.write(from: buffer) }
        } else { try FileManager.default.copyItem(at: source, to: temporary) }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
