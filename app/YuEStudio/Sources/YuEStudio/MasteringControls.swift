import SwiftUI

struct MasteringControls: View {
    @Bindable var model: MasteringController
    @EnvironmentObject private var backend: Backend
    private let columns = [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Small moves can make a big difference.").font(.callout).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Reset") { model.reset() }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                section("Tone") {
                    tone("Bass", value: $model.parameters.bass)
                    tone("Mid body", value: $model.parameters.mid)
                    tone("Treble", value: $model.parameters.treble)
                    amount("Mud cut", value: $model.parameters.mud)
                    HStack { Toggle("Low cut", isOn: model.control(\.lowCut)); Toggle("High cut", isOn: model.control(\.hiCut)) }.toggleStyle(.checkbox)
                }
                section("Repair & dynamics") {
                    amount("Drum punch", value: $model.parameters.punch)
                    amount("AI tone repair", value: $model.parameters.deChirp)
                    amount("De-esser", value: $model.parameters.deEsser)
                    Text("Repair is optional. Add only what the source needs.").font(.caption).foregroundStyle(StudioTheme.muted)
                }
                section("Character") {
                    amount("Warmth", value: $model.parameters.warmth)
                    amount("Analog life", value: $model.parameters.analogLife)
                    amount("Warm exciter", value: $model.parameters.warmExciter)
                    amount("Air exciter", value: $model.parameters.airExciter)
                    amount("Tape texture", value: $model.parameters.tapeHiss)
                }
                section("Stereo image") {
                    amount("Bass center", value: $model.parameters.monoLow)
                    amount("High focus", value: $model.parameters.monoHigh)
                    MasterSlider(label: "Stereo width", value: $model.parameters.width, range: 0...1, display: { String(format: "%.2f×", $0 <= 0.5 ? 0.75 + $0 * 0.5 : 1 + ($0 - 0.5) * 0.7) }, checkpoint: model.checkpoint)
                    Text("1.00× preserves the original width.").font(.caption).foregroundStyle(StudioTheme.muted)
                }
            }
            Divider()
            DisclosureGroup("Six-band equalizer") {
                VStack(spacing: 14) {
                    ForEach(0..<6, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Toggle("Band \(i + 1)", isOn: model.control(\.eq[i].enabled)).toggleStyle(.checkbox).frame(width: 95, alignment: .leading)
                                Picker("Band \(i + 1) filter", selection: model.control(\.eq[i].type)) {
                                    Text("Bell").tag(0); Text("Low shelf").tag(1); Text("High shelf").tag(2); Text("High pass").tag(3); Text("Low pass").tag(4)
                                }.labelsHidden().frame(width: 125)
                                Spacer()
                            }
                            HStack(spacing: 20) {
                                MasterSlider(label: "Frequency \(i + 1)", value: $model.parameters.eq[i].frequencyHz, range: 20...22000, display: { String(format: "%.0f Hz", $0) }, checkpoint: model.checkpoint)
                                MasterSlider(label: "Gain \(i + 1)", value: $model.parameters.eq[i].gainDb, range: -18...18, display: { String(format: "%+.1f dB", $0) }, checkpoint: model.checkpoint)
                                MasterSlider(label: "Q \(i + 1)", value: $model.parameters.eq[i].q, range: 0.1...12, display: { String(format: "%.2f", $0) }, checkpoint: model.checkpoint)
                            }.disabled(!model.parameters.eq[i].enabled)
                        }
                        if i < 5 { Divider() }
                    }
                }.padding(.top, 14)
            }
            Divider()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                section("Flow & finish") {
                    MasterSlider(label: "Fade in", value: $model.parameters.fadeInSec, range: 0...10, display: { String(format: "%.1f s", $0) }, checkpoint: model.checkpoint)
                    MasterSlider(label: "Fade out", value: $model.parameters.fadeOutSec, range: 0...15, display: { String(format: "%.1f s", $0) }, checkpoint: model.checkpoint)
                    MasterSlider(label: "Output drive", value: $model.parameters.masterVolDb, range: -12...18, display: { String(format: "%+.1f dB", $0) }, checkpoint: model.checkpoint)
                    Picker("Final character", selection: model.control(\.finalCharacter)) {
                        Text("Clean & Safe").tag(0); Text("Analog Console").tag(1); Text("Warm Tube").tag(2); Text("Magnetic Tape").tag(3); Text("Soft Clip").tag(4)
                    }
                }
                section("Delivery") {
                    Toggle("Match loudness on render", isOn: model.control(\.normalizeActive)).toggleStyle(.checkbox)
                    MasterSlider(label: "Target loudness", value: $model.parameters.targetLufs, range: -24 ... -7, display: { String(format: "%.1f LUFS", $0) }, checkpoint: model.checkpoint).disabled(!model.parameters.normalizeActive)
                    Toggle("True-peak protection", isOn: model.control(\.useTruePeak)).toggleStyle(.checkbox)
                    MasterSlider(label: "Peak ceiling", value: $model.parameters.ceilingDb, range: -6...0, display: { String(format: "%.1f dBTP", $0) }, checkpoint: model.checkpoint).disabled(!model.parameters.useTruePeak)
                    Text("Loudness is measured across the whole song. The report records the delivered result.").font(.caption).foregroundStyle(StudioTheme.muted)
                }
            }
            Button("Analyze original again", systemImage: "waveform.badge.magnifyingglass") { model.perform("analyze", backend: backend) }.disabled(backend.busy)
        }.font(.body)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.headline); content() }.frame(maxHeight: .infinity, alignment: .top)
    }
    private func amount(_ title: String, value: Binding<Double>) -> some View { MasterSlider(label: title, value: value, range: 0...1, display: { String(format: "%.0f%%", $0 * 100) }, checkpoint: model.checkpoint) }
    private func tone(_ title: String, value: Binding<Double>) -> some View { MasterSlider(label: title, value: value, range: 0...1, display: { String(format: "%+.1f dB", $0 * 12 - 6) }, checkpoint: model.checkpoint) }
}

struct MasterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: (Double) -> String
    let checkpoint: () -> Void
    var body: some View {
        VStack(spacing: 5) {
            HStack { Text(label).font(.callout); Spacer(); Text(display(value)).font(.caption).monospacedDigit().foregroundStyle(StudioTheme.muted) }
            Slider(value: $value, in: range, onEditingChanged: { if $0 { checkpoint() } }).accessibilityLabel(label).accessibilityValue(display(value)).controlSize(.small)
        }
    }
}
