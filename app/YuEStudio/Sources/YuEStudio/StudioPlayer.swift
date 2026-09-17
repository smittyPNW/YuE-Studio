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
    private(set) var isSwitching = false
    private(set) var loadedURL: URL?
    // These reflect the actual AVPlayer item and gain, rather than the UI selection.
    var currentAssetURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }
    var effectiveVolume: Float { player.volume }
    var actualPosition: Double { player.currentTime().seconds }
    private let player = AVPlayer()
    private var tick: Any?
    private var endObserver: NSObjectProtocol?
    private var waveformTask: Task<Void,Never>?
    private var generation = UUID()
    private var seekID = UUID()

    init() {
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSwitching else { return }
                let seconds = self.player.currentTime().seconds
                if seconds.isFinite { self.position = max(0, seconds) }
                if self.player.currentItem?.status == .failed {
                    self.error = self.player.currentItem?.error?.localizedDescription ?? "Could not play this audio file."
                    self.pause()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem, !self.isSwitching else { return }
                if self.loop { self.playing = true; self.seek(0) }
                else { self.playing = false; self.position = self.duration }
            }
        }
    }
    func load(_ song: Song, title: String, draft: Bool = false, keepPosition: Bool = false) {
        let url = song.directory.appendingPathComponent(draft ? "draft.flac" : "audio.flac")
        guard loadFile(url, title: title, keepPosition: keepPosition) else { return }
        songID = song.id; isDraft = draft
        hasDraft = FileManager.default.fileExists(atPath: song.directory.appendingPathComponent("draft.flac").path)
    }
    @discardableResult
    func loadFile(_ url: URL, title: String, keepPosition: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            clear(); error = "This audio file has moved or is unavailable."; return false
        }
        if loadedURL == url && player.currentItem?.status != .failed { self.title = title; return true }
        let resume = keepPosition && playing
        let oldPosition = keepPosition ? position : 0
        let seconds: Double
        do {
            let file = try AVAudioFile(forReading: url)
            seconds = Double(file.length) / file.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0 else { throw StudioFailure("This audio file is empty.") }
        } catch {
            clear(); self.error = "Audio could not be read: \(error.localizedDescription)"; return false
        }
        pause(); error = nil; seekID = UUID()
        loadedURL = url; songID = url.path; self.title = title
        hasDraft = false; isDraft = false
        waveformTask?.cancel(); waveform = []; loadingWaveform = true
        duration = seconds; position = min(max(0, oldPosition), duration)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.volume = volume * auditionGain
        playing = resume
        // A/B and saved-version changes resume only after the sample-accurate seek.
        seek(position)
        let token = UUID(); generation = token
        waveformTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try WaveformReader.read(url) }.value
                guard !Task.isCancelled, generation == token else { return }
                waveform = result.peaks; loadingWaveform = false
            } catch {
                if generation == token { loadingWaveform = false; self.error = "Waveform unavailable: \(error.localizedDescription)" }
            }
        }
        return true
    }
    func clear() {
        pause(); waveformTask?.cancel(); generation = UUID(); seekID = UUID(); isSwitching = false
        player.replaceCurrentItem(with: nil); loadedURL = nil; songID = nil
        title = "Choose a song to listen"; duration = 0; position = 0
        waveform = []; loadingWaveform = false; hasDraft = false; isDraft = false; error = nil
    }
    func invalidate(_ path: String) { if songID == path { clear() } }
    func toggle() {
        guard loadedURL != nil else { return }
        if playing { pause() }
        else {
            playing = true
            if position >= duration - 0.05 { seek(0) }
            else if !isSwitching { player.play() }
        }
    }
    func pause() { player.pause(); playing = false }
    func seek(_ seconds: Double) {
        guard loadedURL != nil else { return }
        let value = min(max(0, seconds), duration)
        let token = UUID(); seekID = token; isSwitching = true
        position = value
        player.pause()
        player.seek(to: CMTime(seconds: value, preferredTimescale: 192000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekID == token else { return }
                self.isSwitching = false
                guard finished else {
                    self.pause(); self.error = "Playback could not seek to this position. Try Play again."; return
                }
                if self.playing { self.player.play() }
            }
        }
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
