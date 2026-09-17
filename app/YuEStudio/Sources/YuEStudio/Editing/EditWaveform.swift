import AVFoundation
import Accelerate

struct EditPeak: Sendable { var low: Float = 0; var high: Float = 0 }
struct EditWaveform: Sendable {
    var frames: Int64
    var rate: Double
    var levels: [[[EditPeak]]]
    // Each level contains channels, each channel contains min/max buckets.
    static func read(_ url: URL) throws -> Self {
        let input = try EditAudio.file(url), channels = Int(input.processingFormat.channelCount)
        var base = [[EditPeak]](repeating: [], count: channels)
        var current = [EditPeak](repeating: EditPeak(), count: channels)
        var used = 0
        try EditAudio.blocks(input, range: 0..<input.length) { buffer, _ in
            for i in 0..<Int(buffer.frameLength) {
                for c in 0..<channels {
                    let x = buffer.floatChannelData![c][i]
                    if used == 0 { current[c] = EditPeak(low: x, high: x) }
                    else { current[c].low = min(current[c].low, x); current[c].high = max(current[c].high, x) }
                }
                used += 1
                if used == 256 { for c in 0..<channels { base[c].append(current[c]) }; used = 0 }
            }
        }
        if used > 0 { for c in 0..<channels { base[c].append(current[c]) } }
        var levels = [base]
        while let previous = levels.last, previous[0].count > 512 {
            let next = previous.map { channel in
                stride(from: 0, to: channel.count, by: 2).map { i in
                    let other = channel[min(i + 1, channel.count - 1)]
                    return EditPeak(low: min(channel[i].low, other.low), high: max(channel[i].high, other.high))
                }
            }
            levels.append(next)
        }
        return Self(frames: input.length, rate: input.processingFormat.sampleRate, levels: levels)
    }
    func peaks(start: Int64, end: Int64, pixels: Int, channel: Int) -> [EditPeak] {
        guard !levels.isEmpty, levels[0].indices.contains(channel), end > start else { return [] }
        var level = 0, bucket: Int64 = 256
        while level + 1 < levels.count && (end - start) / bucket > Int64(max(1, pixels) * 2) { level += 1; bucket *= 2 }
        let values = levels[level][channel]
        return (0..<max(1, pixels)).map { i in
            let lower = max(0, Int((start + (end - start) * Int64(i) / Int64(max(1, pixels))) / bucket))
            let upper = min(values.count, max(lower + 1, Int((start + (end - start) * Int64(i + 1) / Int64(max(1, pixels))) / bucket) + 1))
            guard lower < upper else { return EditPeak() }
            return values[lower..<upper].reduce(EditPeak(low: values[lower].low, high: values[lower].high)) {
                EditPeak(low: min($0.low, $1.low), high: max($0.high, $1.high))
            }
        }
    }
    static func samples(_ url: URL, range: Range<Int64>) throws -> [[Float]] {
        let file = try EditAudio.file(url)
        guard range.count64 <= 16384 else { return [] }
        var values = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        try EditAudio.blocks(file, range: range) { buffer, _ in
            for c in values.indices { values[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        }
        return values
    }
}

struct EditSpectrum: Sendable {
    var magnitudes: [Float]
    var rate: Double
    /// Hann-windowed average power spectrum of a selection, not a loudness measurement.
    static func read(_ url: URL, range: Range<Int64>) throws -> Self {
        let file = try EditAudio.file(url)
        let n = 4096, half = 2048
        guard range.count64 >= 32, let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2)) else { throw StudioFailure("Select at least 32 samples for frequency analysis.") }
        defer { vDSP_destroy_fftsetup(setup) }
        var accumulated = [Float](repeating: 0, count: half)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let windows = min(128, max(1, Int(range.count64 / Int64(n))))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(n))!
        for step in 0..<windows {
            try Task.checkCancellation()
            let offset = range.lowerBound + (max(0, range.count64 - Int64(n)) * Int64(step) / Int64(max(1, windows - 1)))
            file.framePosition = offset
            try file.read(into: buffer, frameCount: UInt32(min(Int64(n), range.upperBound - offset)))
            // Average channel powers, not channel samples: out-of-phase stereo remains visible.
            for channel in 0..<Int(file.processingFormat.channelCount) {
                var real = [Float](repeating: 0, count: half), imag = real
                for i in 0..<Int(buffer.frameLength) {
                    let x = buffer.floatChannelData![channel][i] * window[i]
                    if i % 2 == 0 { real[i / 2] = x } else { imag[i / 2] = x }
                }
                real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))
                    accumulated[0] += r[0] * r[0]
                    for i in 1..<half { accumulated[i] += r[i] * r[i] + im[i] * im[i] }
                } }
            }
        }
        let divisor = Float(windows * Int(file.processingFormat.channelCount)) * Float(n * n)
        return Self(magnitudes: accumulated.map { 10 * log10(max(1e-12, $0 / divisor)) }, rate: file.processingFormat.sampleRate)
    }
}
