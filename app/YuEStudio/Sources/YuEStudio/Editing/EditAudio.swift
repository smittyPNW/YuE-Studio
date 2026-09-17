import AVFoundation
import Darwin

struct EditStatistics: Sendable {
    var peak: Double = 0
    var rms: Double = 0
    var dc: [Double] = []
    var clippedSamples: Int64 = 0
    var peakDB: Double { peak > 0 ? 20 * log10(peak) : -.infinity }
    var rmsDB: Double { rms > 0 ? 20 * log10(rms) : -.infinity }
}

enum EditEffect: Sendable {
    case gain(Double), normalize(Double), fadeIn, fadeOut, ramp(Double, Double)
    case silence, reverse, invert, swap, mono, removeDC, repairClick
    case highPass(Double), lowPass(Double)
}

/// All edits are rendered to new float PCM assets. Source files are never opened for writing.
/// The preview is also the export input, so effects cannot differ between audition and delivery.
enum EditAudio {
    static let chunk: AVAudioFrameCount = 32768
    static func withLease<T>(lock url: URL = Paths.custom.appendingPathComponent("worker.lock"), _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StudioFailure("Could not reserve the audio engine.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StudioFailure("Another Studio audio job is running. Let it finish, then try again.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    static func file(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    static func validatePrecision(_ input: AVAudioFile) throws {
        let format = input.fileFormat.streamDescription.pointee
        if format.mFormatID == kAudioFormatLinearPCM {
            let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            guard format.mBitsPerChannel <= (floating ? 32 : 24) else {
                throw StudioFailure("This source has higher precision than the editor's 32-bit float workspace. It was not converted. Use a 24-bit PCM or 32-bit float working copy if you choose to reduce its precision.")
            }
        }
    }
    static func writer(_ url: URL, rate: Double, channels: UInt32) throws -> AVAudioFile {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StudioFailure("Editing never overwrites an existing audio file.") }
        return try AVAudioFile(forWriting: url, settings: AudioExportFormat.wavFloat.settings(sampleRate: rate, channels: channels), commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    static func render(_ document: EditDocument, folder: URL, destination: URL) throws {
        try document.validate()
        guard document.frames > 0 else { throw StudioFailure("The timeline is empty. Paste or import audio before exporting.") }
        let output = try writer(destination, rate: document.sampleRate, channels: document.channels)
        for clip in document.clips {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(clip.asset)
            guard url.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath() else { throw StudioFailure("A clip points outside its editing project.") }
            let input = try file(url)
            try validatePrecision(input)
            guard input.processingFormat.sampleRate == document.sampleRate, input.processingFormat.channelCount == document.channels,
                  clip.start <= input.length, clip.count <= input.length - clip.start else { throw StudioFailure("A clip is missing, shortened, or has a different sample rate or channel count.") }
            input.framePosition = clip.start
            try blocks(input, range: clip.start..<(clip.start + clip.count)) { buffer, _ in try output.write(from: buffer) }
        }
    }
    static func blocks(_ input: AVAudioFile, range: Range<Int64>, _ body: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        guard range.lowerBound >= 0, range.upperBound <= input.length, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else { throw StudioFailure("The selected audio range is invalid.") }
        input.framePosition = range.lowerBound
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), range.upperBound - position)))
            guard buffer.frameLength > 0, buffer.floatChannelData != nil else { throw StudioFailure("The audio file ended before the selected range.") }
            try body(buffer, position - range.lowerBound)
            position += Int64(buffer.frameLength)
        }
    }
    static func analyze(_ url: URL, range: Range<Int64>? = nil) throws -> EditStatistics {
        let input = try file(url), channels = Int(input.processingFormat.channelCount)
        let range = range ?? 0..<input.length
        var stats = EditStatistics(dc: [Double](repeating: 0, count: channels))
        var power = 0.0
        try blocks(input, range: range) { buffer, _ in
            let data = buffer.floatChannelData!
            for c in 0..<channels { for i in 0..<Int(buffer.frameLength) {
                let x = Double(data[c][i]); guard x.isFinite else { throw StudioFailure("The recording contains invalid samples.") }
                stats.peak = max(stats.peak, abs(x)); stats.dc[c] += x; power += x * x
                if abs(x) >= 1 { stats.clippedSamples += 1 }
            } }
        }
        if range.count64 > 0 {
            stats.dc = stats.dc.map { $0 / Double(range.count64) }
            stats.rms = sqrt(power / Double(range.count64 * Int64(channels)))
        }
        return stats
    }
    static func process(_ effect: EditEffect, source: URL, range: Range<Int64>, destination: URL) throws {
        let input = try file(source), format = input.processingFormat
        guard !range.isEmpty else { throw StudioFailure("Select the audio to process first.") }
        var stats: EditStatistics?
        switch effect { case .normalize, .removeDC: stats = try analyze(source, range: range); default: break }
        var left: [Float] = [], right: [Float] = []
        if case .repairClick = effect {
            guard range.count64 <= 128, range.lowerBound > 0, range.upperBound < input.length else {
                throw StudioFailure("Click repair interpolates a tiny defect. Zoom in and select 1–128 samples with intact audio on both sides. Longer crackles need a different repair.")
            }
            for point in [range.lowerBound - 1, range.upperBound] {
                try blocks(input, range: point..<(point + 1)) { buffer, _ in
                    let values = (0..<Int(format.channelCount)).map { buffer.floatChannelData![$0][0] }
                    if left.isEmpty { left = values } else { right = values }
                }
            }
        }
        let output = try writer(destination, rate: format.sampleRate, channels: format.channelCount)
        if case .reverse = effect {
            var end = range.upperBound
            while end > range.lowerBound {
                let start = max(range.lowerBound, end - Int64(chunk))
                try blocks(input, range: start..<end) { buffer, _ in
                    for c in 0..<Int(format.channelCount) {
                        let d = buffer.floatChannelData![c], n = Int(buffer.frameLength)
                        for i in 0..<(n / 2) { let x = d[i]; d[i] = d[n - i - 1]; d[n - i - 1] = x }
                    }
                    try output.write(from: buffer)
                }
                end = start
            }
            return
        }
        var filters = [EditBiquad](repeating: EditBiquad(), count: Int(format.channelCount))
        switch effect {
        case .highPass(let hz): filters = filters.map { _ in EditBiquad(rate: format.sampleRate, hz: hz, high: true) }
        case .lowPass(let hz): filters = filters.map { _ in EditBiquad(rate: format.sampleRate, hz: hz, high: false) }
        default: break
        }
        try blocks(input, range: range) { buffer, offset in
            let data = buffer.floatChannelData!, n = Int(buffer.frameLength)
            for i in 0..<n {
                let t = Double(offset + Int64(i)) / Double(max(1, range.count64 - 1))
                if case .swap = effect, format.channelCount == 2 { let x = data[0][i]; data[0][i] = data[1][i]; data[1][i] = x }
                if case .mono = effect, format.channelCount == 2 { let x = (data[0][i] + data[1][i]) * 0.5; data[0][i] = x; data[1][i] = x }
                for c in 0..<Int(format.channelCount) {
                    var x = Double(data[c][i])
                    switch effect {
                    case .gain(let db): x *= pow(10, db / 20)
                    case .normalize(let db): if let peak = stats?.peak, peak > 0 { x *= pow(10, db / 20) / peak }
                    case .fadeIn: x *= t
                    case .fadeOut: x *= 1 - t
                    case .ramp(let from, let to): x *= pow(10, (from + (to - from) * t) / 20)
                    case .silence: x = 0
                    case .invert: x = -x
                    case .removeDC: x -= stats!.dc[c]
                    case .repairClick: x = Double(left[c]) + Double(right[c] - left[c]) * Double(offset + Int64(i) + 1) / Double(range.count64 + 1)
                    case .highPass, .lowPass: x = filters[c].apply(x)
                    default: break
                    }
                    guard x.isFinite else { throw StudioFailure("Processing produced invalid samples. The previous edit is preserved.") }
                    data[c][i] = Float(x)
                }
            }
            try output.write(from: buffer)
        }
    }
    static func quietCrossing(_ url: URL, near frame: Int64) throws -> Int64 {
        let file = try self.file(url)
        if frame <= 0 { return 0 }; if frame >= file.length { return file.length }
        let range = max(0, frame - 512)..<min(file.length, frame + 513)
        let samples = try EditWaveform.samples(url, range: range)
        var best = frame, bestScore = Double.infinity
        for i in 1..<samples[0].count {
            guard samples[0][i] == 0 || samples[0][i - 1] * samples[0][i] < 0 else { continue }
            let energy = samples.reduce(0.0) { $0 + Double(abs($1[i]) + abs($1[i - 1])) }
            let distance = Double(abs(range.lowerBound + Int64(i) - frame)) / 512
            let score = energy + distance * 0.001
            if score < bestScore { bestScore = score; best = range.lowerBound + Int64(i) }
        }
        return best
    }
    static func silence(frames: Int64, rate: Double, channels: UInt32, destination: URL) throws {
        guard frames > 0, frames <= Int64(rate * 600) else { throw StudioFailure("Insert between one sample and ten minutes of silence.") }
        let output = try writer(destination, rate: rate, channels: channels)
        let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: chunk)!
        for c in 0..<Int(channels) { buffer.floatChannelData![c].initialize(repeating: 0, count: Int(chunk)) }
        var remaining = frames
        while remaining > 0 { try Task.checkCancellation(); buffer.frameLength = AVAudioFrameCount(min(remaining, Int64(chunk))); try output.write(from: buffer); remaining -= Int64(buffer.frameLength) }
    }
    static func crossfade(source: URL, boundary: Int64, frames: Int64, destination: URL) throws {
        let a = try file(source), b = try file(source)
        guard frames > 1, boundary >= frames, boundary + frames <= a.length else { throw StudioFailure("The overlap must fit inside both neighboring clips.") }
        let output = try writer(destination, rate: a.processingFormat.sampleRate, channels: a.processingFormat.channelCount)
        let other = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: chunk)!
        b.framePosition = boundary
        try blocks(a, range: (boundary - frames)..<boundary) { buffer, offset in
            try b.read(into: other, frameCount: buffer.frameLength)
            guard other.frameLength == buffer.frameLength else { throw StudioFailure("The transition audio ended early.") }
            for c in 0..<Int(a.processingFormat.channelCount) { for i in 0..<Int(buffer.frameLength) {
                let t = Float(offset + Int64(i)) / Float(frames - 1)
                buffer.floatChannelData![c][i] = buffer.floatChannelData![c][i] * (1 - t) + other.floatChannelData![c][i] * t
            } }
            try output.write(from: buffer)
        }
    }
}

/// Second-order Butterworth filter; state is continuous across processing blocks.
private struct EditBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    init() {}
    init(rate: Double, hz: Double, high: Bool) {
        let w = 2 * Double.pi * min(max(10, hz), rate * 0.45) / rate
        let c = cos(w), alpha = sin(w) / sqrt(2), a0 = 1 + alpha
        b0 = (high ? 1 + c : 1 - c) / 2 / a0
        b1 = (high ? -(1 + c) : 1 - c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }
    mutating func apply(_ x: Double) -> Double {
        let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y
    }
}
