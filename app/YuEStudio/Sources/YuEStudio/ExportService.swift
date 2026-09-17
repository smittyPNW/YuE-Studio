import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

enum AudioExportFormat: String, CaseIterable, Identifiable, Sendable {
    case wav24, wavFloat, flac, aiff, appleLossless, aac, mp3
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .wav24, .wavFloat: return "wav"
        case .flac: return "flac"
        case .aiff: return "aiff"
        case .appleLossless, .aac: return "m4a"
        case .mp3: return "mp3"
        }
    }
    var title: String {
        switch self {
        case .wav24: return "WAV · 24-bit"
        case .wavFloat: return "WAV · 32-bit float"
        case .flac: return "FLAC · Lossless"
        case .aiff: return "AIFF · 24-bit"
        case .appleLossless: return "Apple Lossless · M4A"
        case .aac: return "AAC · M4A sharing copy"
        case .mp3: return "MP3 · 320 kbps"
        }
    }
    var detail: String {
        switch self {
        case .wav24: return "Uncompressed 24-bit audio for sharing a studio master."
        case .wavFloat: return "Uncompressed 32-bit float audio for further editing."
        case .flac: return "Lossless 24-bit audio in a smaller file."
        case .aiff: return "Uncompressed 24-bit audio for compatible music software."
        case .appleLossless: return "Lossless 24-bit audio for Apple Music and compatible players."
        case .aac: return "Compressed sharing audio: 256 kbps stereo or 128 kbps mono. Choose a lossless format for your master."
        case .mp3: return "High-quality 320 kbps MP3 sharing copy. Sources outside 32, 44.1 or 48 kHz are converted to 48 kHz. Choose lossless for your master."
        }
    }
    func settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        var values: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch self {
        case .wav24, .wavFloat, .aiff:
            values[AVFormatIDKey] = kAudioFormatLinearPCM
            values[AVLinearPCMBitDepthKey] = self == .wavFloat ? 32 : 24
            values[AVLinearPCMIsFloatKey] = self == .wavFloat
            values[AVLinearPCMIsBigEndianKey] = self == .aiff
        case .flac:
            values[AVFormatIDKey] = kAudioFormatFLAC
            values[AVEncoderBitDepthHintKey] = 24
        case .appleLossless:
            values[AVFormatIDKey] = kAudioFormatAppleLossless
            values[AVEncoderBitDepthHintKey] = 24
        case .aac:
            values[AVFormatIDKey] = kAudioFormatMPEG4AAC
            values[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
            values[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        case .mp3:
            values[AVFormatIDKey] = kAudioFormatMPEGLayer3
        }
        return values
    }
}

enum ExportService {
    @MainActor static func choose(song: Song, title: String, format: AudioExportFormat, completion: @escaping (String) -> Void) {
        let panel = savePanel(title: title, format: format)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .utility) {
                        try export(source: URL(fileURLWithPath: song.path), destination: destination, format: format)
                    }.value
                    completion("Exported \(destination.lastPathComponent)")
                } catch { completion("Export failed: \(error.localizedDescription)") }
            }
        }
    }
    @MainActor static func savePanel(title: String, format: AudioExportFormat) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .audio]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
        panel.message = format.detail + (format == .mp3 ? "" : " The source sample rate is preserved.") + " Choose a new filename; existing audio is never overwritten."
        return panel
    }

    static func exportMaster(source: URL, destination: URL, format: AudioExportFormat = .wav24) throws {
        try export(source: source, destination: destination, format: format)
    }

    /// Every delivery is committed atomically and exclusively. The source, previous
    /// masters and files created while an export is running cannot be overwritten.
    static func export(source: URL, destination: URL, format: AudioExportFormat) throws {
        let manager = FileManager.default
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL,
              !manager.fileExists(atPath: destination.path) else {
            throw StudioFailure("Choose a new filename. Existing audio is never overwritten by export.")
        }
        guard destination.pathExtension.lowercased() == format.fileExtension else {
            throw StudioFailure("Use the .\(format.fileExtension) extension for \(format.title).")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".yue-export-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? manager.removeItem(at: temporary) }
        let input = try AVAudioFile(forReading: source)
        let pcm = input.processingFormat
        guard input.length > 0, pcm.channelCount > 0, pcm.sampleRate > 0 else { throw StudioFailure("This audio file is empty or unreadable.") }
        if format == .aac && !(8000...48000).contains(pcm.sampleRate) {
            throw StudioFailure("AAC sharing supports source rates from 8 to 48 kHz. Choose WAV, AIFF, FLAC or Apple Lossless to preserve this track's sample rate.")
        }
        // Preserve the encoded file when it already matches the delivery.
        let description = input.fileFormat.streamDescription.pointee
        let is24Bit = description.mBitsPerChannel == 24 || input.fileFormat.settings[AVEncoderBitDepthHintKey] as? Int == 24
        let matchingWAV = format == .wav24 && source.pathExtension.lowercased() == "wav" && description.mFormatID == kAudioFormatLinearPCM && is24Bit
        let matchingFLAC = format == .flac && description.mFormatID == kAudioFormatFLAC && is24Bit
        if format == .mp3 { try MP3Encoder.encode(input: input, destination: temporary) }
        else if matchingWAV || matchingFLAC { try manager.copyItem(at: source, to: temporary) }
        else { try transcode(input: input, destination: temporary, format: format) }
        // Reopen only after the writer closes and finalizes compressed-file headers.
        let delivered = try AVAudioFile(forReading: temporary)
        let expectedRate = format == .mp3 ? MP3Encoder.deliveryRate(pcm.sampleRate) : pcm.sampleRate
        let expectedFrames = Double(input.length) * expectedRate / pcm.sampleRate
        guard delivered.processingFormat.sampleRate == expectedRate,
              delivered.processingFormat.channelCount == pcm.channelCount,
              abs(Double(delivered.length) - expectedFrames) <= (format == .aac || format == .mp3 ? 2304 : 0) else {
            throw StudioFailure("Export verification failed. The original audio is safe; try a lossless format.")
        }
        let result = temporary.path.withCString { from in destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func transcode(input: AVAudioFile, destination: URL, format: AudioExportFormat) throws {
        let pcm = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: format.settings(sampleRate: pcm.sampleRate, channels: pcm.channelCount), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 32768) else { throw CocoaError(.fileReadUnknown) }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw StudioFailure("The audio ended unexpectedly during export.") }
            try output.write(from: buffer)
        }
    }
}
