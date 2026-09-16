import SwiftUI

struct StudioInspector: View {
    @Bindable var library: StudioLibrary
    @EnvironmentObject var backend: Backend
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Song settings").font(.headline); Spacer(); Button("Close settings", systemImage: "xmark") { library.showInspector = false }.labelStyle(.iconOnly).buttonStyle(.plain) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Maximum duration"); Spacer(); Text(clockText(library.state.composer.maxSeconds)).monospacedDigit().foregroundStyle(StudioTheme.highlight) }
                    Slider(value: $library.state.composer.maxSeconds, in: 30...360, step: 10).accessibilityLabel("Maximum duration")
                    Text("A ceiling, not a target. The song can finish naturally before this limit.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Instrumental", isOn: $library.state.composer.instrumental)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("QUALITY").font(.caption).tracking(1).foregroundStyle(.secondary)
                    Label("Full · 32 synthesis steps", systemImage: "checkmark.seal")
                    Label("GPU · Apple MLX", systemImage: "cpu")
                    Label("48 kHz lossless stereo", systemImage: "waveform")
                    Text("Original model precision and full musical planning. One song per job.").font(.caption).foregroundStyle(.secondary)
                }.font(.subheadline)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Variations").font(.headline)
                    Toggle("Use a fresh seed", isOn: $library.state.composer.randomSeed)
                    TextField("Seed", value: $library.state.composer.seed, format: .number).textFieldStyle(.roundedBorder).disabled(library.state.composer.randomSeed)
                    Text("A fresh seed creates another interpretation. Re-rendering a saved composition keeps its original seed.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Custom score (ABC)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("An optional edited score for a new version. The original recording stays in your library.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $library.state.composer.abc).font(.system(.caption, design: .monospaced)).frame(height: 150).accessibilityLabel("Custom ABC score")
                    }.padding(.top, 8)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Memory").font(.headline); Spacer(); Text(backend.memoryPressure).font(.caption).foregroundStyle(["Normal", "Monitoring"].contains(backend.memoryPressure) ? Color.secondary : StudioTheme.highlight) }
                    Text(backend.memoryMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Working memory is released after rendering. The idle model unloads after two minutes.").font(.caption).foregroundStyle(.secondary)
                    Button("Free model memory", systemImage: "memorychip") { backend.send(["cmd":"unload"]) }.disabled(backend.busy || !backend.connected)
                }
            }.padding(20)
        }.frame(width: 250).background(StudioTheme.sidebar)
    }
}
