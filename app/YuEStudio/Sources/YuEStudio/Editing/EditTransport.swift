import AVFoundation
import Observation

@MainActor @Observable final class EditTransport {
    var playing = false
    var frame: Int64 = 0
    var loop = false
    var volume: Float = 0.8 { didSet { node.volume = volume } }
    var error: String?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: Int64 = 0
    private var stopFrame: Int64 = 0
    private var playRange: Range<Int64> = 0..<0
    private var token = UUID()
    private var timer: Timer?
    init() { engine.attach(node); node.volume = volume }
    func load(_ url: URL?) throws {
        pause(); file = nil; frame = 0; engine.stop(); engine.disconnectNodeOutput(node)
        guard let url else { return }
        let opened = try EditAudio.file(url)
        engine.connect(node, to: engine.mainMixerNode, format: opened.processingFormat)
        file = opened
    }
    func pause() {
        updatePosition(); token = UUID(); node.stop(); playing = false; timer?.invalidate(); timer = nil
    }
    func seek(_ position: Int64) {
        pause(); frame = min(file?.length ?? 0, max(0, position))
    }
    func toggle(selection: Range<Int64>) {
        if playing { pause(); return }
        guard let file, file.length > 0 else { return }
        let range = selection.isEmpty ? 0..<file.length : selection
        playRange = max(0, range.lowerBound)..<min(file.length, range.upperBound)
        let start = playRange.contains(frame) ? frame : playRange.lowerBound
        play(from: start)
    }
    private func play(from start: Int64) {
        guard let file, playRange.upperBound > start else { return }
        let id = UUID(); token = id; startFrame = start; stopFrame = playRange.upperBound; frame = start
        do {
            if !engine.isRunning { try engine.start() }
            node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(stopFrame - start), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.token == id else { return }
                    self.node.stop(); self.timer?.invalidate(); self.timer = nil
                    if self.loop { self.play(from: self.playRange.lowerBound) }
                    else { self.frame = self.stopFrame; self.playing = false }
                }
            }
            node.play(); playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updatePosition() }
            }
        } catch { self.error = "Audio playback failed: \(error.localizedDescription)"; pause() }
    }
    private func updatePosition() {
        guard playing, let time = node.lastRenderTime, let position = node.playerTime(forNodeTime: time) else { return }
        frame = min(stopFrame, startFrame + max(0, position.sampleTime))
    }
}
