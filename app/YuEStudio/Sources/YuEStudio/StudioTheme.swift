import SwiftUI

enum StudioTheme {
    static let accent = Color(red: 0.76, green: 0.275, blue: 0.065)
    static let highlight = adaptive(dark: (0.98, 0.54, 0.32), light: (0.76, 0.275, 0.065))
    static let muted = adaptive(dark: (0.76, 0.71, 0.65), light: (0.43, 0.36, 0.29))
    static let canvas = adaptive(dark: (0.135, 0.112, 0.098), light: (0.966, 0.940, 0.891))
    static let sidebar = adaptive(dark: (0.100, 0.083, 0.073), light: (0.931, 0.890, 0.826))
    static let editor = adaptive(dark: (0.170, 0.141, 0.122), light: (1.000, 0.982, 0.946))
    static let ink = adaptive(dark: (0.965, 0.930, 0.864), light: (0.200, 0.145, 0.109))
    static func adaptive(dark: (Double,Double,Double), light: (Double,Double,Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

struct PlayerBar: View {
    @Bindable var player: StudioPlayer
    let song: Song?
    var body: some View {
        HStack(spacing: 20) {
            Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") { player.toggle() }
                .labelStyle(.iconOnly).font(.title2).buttonStyle(.plain).frame(width: 48, height: 48)
                .background(StudioTheme.accent, in: .circle).foregroundStyle(.white).disabled(player.songID == nil).help("Play or pause")
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(player.title).font(.headline).lineLimit(1)
                    Spacer()
                    if player.hasDraft, let song {
                        Picker("Audio version", selection: Binding(get: { player.isDraft }, set: { player.load(song, title: player.title, draft: $0, keepPosition: true) })) {
                            Text("Full").tag(false); Text("Draft").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 125).help("Compare the full render with the original draft")
                    }
                    Text("\(clockText(player.position)) / \(clockText(player.duration))").monospacedDigit().font(.caption).foregroundStyle(.secondary).accessibilityLabel("Playback time \(clockText(player.position)) of \(clockText(player.duration))")
                }
                WaveformView(peaks: player.waveform, progress: player.duration > 0 ? player.position / player.duration : 0)
                    .frame(height: 34).accessibilityHidden(true)
                    .overlay { if player.loadingWaveform { ProgressView().controlSize(.small) } }
                Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                    .accessibilityLabel("Playback position").disabled(player.songID == nil).controlSize(.mini)
            }
            VStack(spacing: 10) {
                HStack(spacing: 6) { Image(systemName: "speaker.wave.2").foregroundStyle(.secondary); Slider(value: $player.volume, in: 0...1).frame(width: 75).accessibilityLabel("Volume") }
                Toggle(isOn: $player.loop) { Label("Loop", systemImage: "repeat") }.toggleStyle(.button).controlSize(.small).help("Repeat this song")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14).background(StudioTheme.sidebar)
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let count = min(peaks.count, Int(size.width / 2))
            guard count > 0 else { return }
            for i in 0..<count {
                let amplitude = CGFloat(peaks[min(peaks.count - 1, i * peaks.count / count)])
                let height = max(1.5, amplitude * size.height)
                let x = CGFloat(i) * size.width / CGFloat(count)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: 1.4, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.7), with: .color(Double(i) / Double(count) <= progress ? StudioTheme.highlight : .secondary.opacity(0.45)))
            }
        }
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(Color(red: 1, green: 0.97, blue: 0.89))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(StudioTheme.accent.opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
    }
}
