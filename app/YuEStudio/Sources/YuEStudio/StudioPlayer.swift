import SwiftUI
import AVFoundation
import Observation
import CryptoKit

@MainActor @Observable
final class StudioPlayer {
    var songID: String?
    var title = "Choose a song to listen"
    var duration = 0.0
    var position = 0.0
    var playing = false
    var volume: Float = 0.85 { didSet { player.volume = volume * auditionGain } }
    var auditionGain: Float = 1 { didSet { player.volume = volume * auditionGain } }
    var loop = false
    var isDraft = false
    var hasDraft = false
    var waveform: [Float] = []
    var loadingWaveform = false
    var error: String?
    private let player = AVPlayer()
    private var tick: Any?
    private var endObserver: NSObjectProtocol?
    private var waveformTask: Task<Void,Never>?
    private var loadedURL: URL?
    private var generation = UUID()

    init() {
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite { self.position = max(0, time.seconds) }
                if self.player.currentItem?.status == .failed { self.error = self.player.currentItem?.error?.localizedDescription ?? "Could not play this audio file."; self.playing = false }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.playing = false
                if self.loop { self.seek(0); self.player.play(); self.playing = true }
                else { self.position = self.duration }
            }
        }
    }
    func load(_ song: Song, title: String, draft: Bool = false, keepPosition: Bool = false) {
        let url = song.directory.appendingPathComponent(draft ? "draft.flac" : "audio.flac")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if loadedURL == url && songID == song.id { self.title = title; return }
        let resume = keepPosition && playing
        let oldPosition = keepPosition ? position : 0
        player.pause(); playing = false; error = nil
        songID = song.id; self.title = title; isDraft = draft; loadedURL = url
        hasDraft = FileManager.default.fileExists(atPath: song.directory.appendingPathComponent("draft.flac").path)
        duration = song.seconds; position = oldPosition
        player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.volume = volume * auditionGain
        if oldPosition > 0 { player.seek(to: CMTime(seconds: oldPosition, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero) }
        if resume { player.play(); playing = true }
        waveformTask?.cancel(); waveform = []; loadingWaveform = true
        let token = UUID(); generation = token
        waveformTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try WaveformReader.read(url) }.value
                guard !Task.isCancelled, generation == token else { return }
                waveform = result.peaks; duration = result.seconds; loadingWaveform = false
            } catch { if generation == token { loadingWaveform = false; self.error = "Waveform unavailable: \(error.localizedDescription)" } }
        }
    }
    func loadFile(_ url: URL, title: String, keepPosition: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else { error = "This audio file has moved or is unavailable."; return }
        if loadedURL == url { self.title = title; return }
        let resume = keepPosition && playing
        let oldPosition = keepPosition ? position : 0
        pause(); error = nil; loadedURL = url; songID = url.path; self.title = title
        hasDraft = false; isDraft = false; waveformTask?.cancel(); waveform = []; loadingWaveform = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.volume = volume * auditionGain
        position = oldPosition
        if oldPosition > 0 { player.seek(to: CMTime(seconds: oldPosition, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero) }
        if resume { player.play(); playing = true }
        let token = UUID(); generation = token
        waveformTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try WaveformReader.read(url) }.value
                guard !Task.isCancelled, generation == token else { return }
                waveform = result.peaks; duration = result.seconds; loadingWaveform = false
            } catch { if generation == token { loadingWaveform = false; self.error = "Audio could not be read: \(error.localizedDescription)" } }
        }
    }
    func invalidate(_ path: String) { if songID == path { pause(); loadedURL = nil } }
    func toggle() {
        guard loadedURL != nil else { return }
        if playing { pause() }
        else { if position >= duration - 0.05 { seek(0) }; player.play(); playing = true }
    }
    func pause() { player.pause(); playing = false }
    func seek(_ seconds: Double) {
        let v = min(max(0, seconds), duration)
        position = v
        player.seek(to: CMTime(seconds: v, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct WaveformResult: Codable, Sendable { var peaks: [Float]; var seconds: Double }

enum WaveformReader {
    static func read(_ url: URL) throws -> WaveformResult {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = url.path + String(describing: attrs[.size]) + String(describing: attrs[.modificationDate])
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = Paths.custom.appendingPathComponent("waveforms").appendingPathComponent(digest + ".json")
        if let data = try? Data(contentsOf: cache), let value = try? JSONDecoder().decode(WaveformResult.self, from: data) { return value }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = 700
        var peaks = [Float](repeating: 0, count: count)
        let total = max(1, Int(file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw CocoaError(.fileReadUnknown) }
        var offset = 0
        while offset < total {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(32768, total - offset)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                let bucket = min(count - 1, (offset + i) * count / total)
                for channel in 0..<Int(format.channelCount) { peaks[bucket] = max(peaks[bucket], abs(data[channel][i])) }
            }
            offset += frames
        }
        let result = WaveformResult(peaks: peaks, seconds: Double(file.length) / format.sampleRate)
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: cache, options: .atomic) }
        return result
    }
}

func clockText(_ seconds: Double) -> String { let s = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%d:%02d", s / 60, s % 60) }
