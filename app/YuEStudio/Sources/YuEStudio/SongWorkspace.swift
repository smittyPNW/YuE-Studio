import SwiftUI

struct SongWorkspace: View {
    @Bindable var library: StudioLibrary
    @Bindable var player: StudioPlayer
    @EnvironmentObject var backend: Backend
    @State private var jump: EditorJump?
    let song: Song?
    var masterSong: ((Song) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(song == nil ? "NEW COMPOSITION" : "SONG WORKSPACE").font(.caption).tracking(1.5).foregroundStyle(StudioTheme.highlight)
                    TextField("Song title", text: $library.state.composer.title).font(.system(size: 30, weight: .semibold, design: .rounded)).textFieldStyle(.plain).accessibilityLabel("Song title")
                }
                Spacer(minLength: 8)
                if let song, song.status == .ready {
                    Menu {
                        Button("Export lossless FLAC…") { ExportService.choose(song: song, title: library.title(song), wav: false) { library.notice = $0 } }
                        Button("Export WAV…") { ExportService.choose(song: song, title: library.title(song), wav: true) { library.notice = $0 } }
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: song.path)]) }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Musical direction").font(.headline); Spacer(); Text("Genre · voice · instruments · mood").font(.caption).foregroundStyle(.secondary) }
                TextEditor(text: $library.state.composer.style).font(.body).scrollContentBackground(.hidden).padding(10).frame(height: 96)
                    .background(StudioTheme.editor, in: .rect(cornerRadius: 10)).accessibilityLabel("Musical style prompt")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(library.state.composer.instrumental ? "Arrangement" : "Lyrics").font(.headline)
                    Spacer()
                    Text("\(library.wordCount) words").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let song, !song.score.isEmpty { Button("Score", systemImage: "music.note.list") { library.showScore = true }.buttonStyle(.plain).font(.caption) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lyricSections(library.state.composer.lyrics)) { section in
                            Button(section.title) { jump = EditorJump(range: section.range) }
                                .font(.caption).buttonStyle(.plain).padding(.horizontal, 11).padding(.vertical, 5)
                                .background(.primary.opacity(0.05), in: .capsule).help("Jump to \(section.title)")
                        }
                    }
                }.frame(height: library.sections.isEmpty ? 0 : 26)
                LyricEditor(text: $library.state.composer.lyrics, jump: jump)
                    .frame(minHeight: 130).background(StudioTheme.editor, in: .rect(cornerRadius: 10))
            }.frame(maxHeight: .infinity)
            if library.wordCount > 500 {
                Label("These lyrics are long. Allow enough duration or revise them yourself; Studio keeps every line.", systemImage: "text.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let song, song.truncated {
                Label("This version reached its duration limit. Increase the limit and create a new version for a complete ending.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            RenderStatusView(song: song, backend: backend, player: player)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Full quality", systemImage: "checkmark.seal").font(.subheadline).fontWeight(.medium)
                    Text("32 steps · full composition · lossless stereo").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let song, song.status == .ready, let masterSong {
                    Button("Master this song", systemImage: "slider.horizontal.3") { player.pause(); masterSong(song) }
                        .disabled(backend.busy || backend.masteringActive).help("Optional: polish this recording with ReSoul. Your original is preserved.")
                }
                Button {
                    library.save()
                    let d = library.state.composer
                    backend.generate(title: d.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled song" : d.title, style: d.style, lyrics: d.lyrics, cot: "full", seed: d.seed, randomSeed: d.randomSeed, batch: 1, maxTokens: Int(d.maxSeconds * 25), engine: "mlx", abc: d.abc, quality: "full", instrumental: d.instrumental)
                } label: { Label(backend.busy ? "Add to queue" : (song == nil ? "Generate song" : "Create new version"), systemImage: backend.busy ? "plus" : "waveform") }
                .buttonStyle(StudioPrimaryButtonStyle()).disabled(!library.valid || !backend.connected || backend.masteringActive)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(24).background(StudioTheme.canvas)
    }
}

struct RenderStatusView: View {
    let song: Song?
    @ObservedObject var backend: Backend
    @Bindable var player: StudioPlayer
    var body: some View {
        if let song, song.inFlight {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text(stageName(song)).font(.headline); Spacer(); Button("Cancel this render") { backend.cancel(song) }.controlSize(.small) }
                ProgressView(value: song.trackProgress, total: 4).tint(StudioTheme.accent)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text("Elapsed \(clockText(context.date.timeIntervalSince(song.startedAt ?? context.date)))")
                        Spacer()
                        if song.status == .synth, let start = song.progressStartedAt, let first = song.progressStartedFraction, let fraction = song.fraction, fraction > first, fraction < 1 {
                            let remaining = context.date.timeIntervalSince(start) / (fraction - first) * (1 - fraction)
                            Text("About \(clockText(remaining)) left in synthesis")
                        }
                    }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(song.detail.isEmpty ? "Working on your song…" : song.detail.replacingOccurrences(of: "solver", with: "Synthesis"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(14).background(StudioTheme.accent.opacity(0.07), in: .rect(cornerRadius: 10))
        } else if let song, song.status == .stalled || song.status == .failed {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your song needs attention", systemImage: "exclamationmark.circle").font(.headline)
                Text(song.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                if FileManager.default.fileExists(atPath: song.directory.appendingPathComponent("semantic.npy").path) {
                    Button("Recover with full-quality GPU render", systemImage: "arrow.clockwise") { player.invalidate(song.id); backend.render(song, engine: "mlx", quality: "full") }.disabled(!backend.connected)
                }
            }.padding(14).background(StudioTheme.accent.opacity(0.08), in: .rect(cornerRadius: 10))
        } else if let song, song.quality == "draft" {
            HStack {
                Text("This is a draft preview.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Render full quality", systemImage: "waveform") { player.invalidate(song.id); backend.render(song, engine: "mlx", quality: "full") }.disabled(!backend.connected)
            }
        } else if backend.masteringActive {
            Label("Mastering is using the audio engine. Generation will be available when it finishes.", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
        } else if !backend.connected {
            HStack { Label("Music engine disconnected", systemImage: "exclamationmark.circle"); Spacer(); Button("Reconnect") { backend.start() } }.font(.callout)
        }
    }
}
