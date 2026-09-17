import SwiftUI

struct LibrarySidebar: View {
    @Bindable var library: StudioLibrary
    @EnvironmentObject var backend: Backend
    var player: StudioPlayer
    @State private var pendingDelete: Song?
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("YOUR LIBRARY").font(.caption).fontWeight(.semibold).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Button("New song", systemImage: "plus") { library.newSong() }.labelStyle(.iconOnly).buttonStyle(.plain).help("New song")
            }.padding(.top, 20)
            TextField("Search songs", text: $library.search).textFieldStyle(.roundedBorder).accessibilityLabel("Search songs")
            HStack {
                Button("All songs") { library.favoritesOnly = false }.buttonStyle(.plain).foregroundStyle(library.favoritesOnly ? Color.secondary : StudioTheme.highlight)
                Text("/").foregroundStyle(.tertiary)
                Button("Favorites") { library.favoritesOnly = true }.buttonStyle(.plain).foregroundStyle(library.favoritesOnly ? StudioTheme.highlight : Color.secondary)
            }.font(.subheadline)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.filtered(backend.songs)) { song in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                library.select(song)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: song.inFlight ? "waveform" : (song.status == .ready ? "music.note" : "exclamationmark.circle"))
                                        .font(.title3).foregroundStyle(song.inFlight ? StudioTheme.highlight : Color.secondary).frame(width: 24).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(library.title(song)).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(song.inFlight ? "Creating · \(stageName(song))" : (song.status == .ready ? "\(clockText(song.seconds)) · \(song.quality == "full" ? "Full quality" : "Draft")" : "Needs attention"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if song.inFlight { ProgressView(value: song.trackProgress, total: 4).tint(StudioTheme.accent).controlSize(.mini).accessibilityHidden(true) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 14).padding(.leading, 12).contentShape(.rect)
                            }.buttonStyle(.plain).accessibilityIdentifier("song-" + song.run + "-" + String(song.index)).accessibilityLabel("Open \(library.title(song))").accessibilityValue(song.inFlight ? stageName(song) : (song.status == .ready ? "\(clockText(song.seconds)), \(song.quality) quality" : "Needs attention"))
                            Button(library.state.notes[song.id]?.favorite == true ? "Remove from favorites" : "Add to favorites", systemImage: library.state.notes[song.id]?.favorite == true ? "star.fill" : "star") { library.favorite(song) }
                                .accessibilityIdentifier("favorite-" + song.run + "-" + String(song.index)).accessibilityLabel((library.state.notes[song.id]?.favorite == true ? "Unfavorite " : "Favorite ") + library.title(song))
                                .labelStyle(.iconOnly).buttonStyle(.plain).font(.caption).foregroundStyle(library.state.notes[song.id]?.favorite == true ? StudioTheme.highlight : Color.secondary).padding(.top, 17).padding(.trailing, 10)
                        }
                        .contextMenu {
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingDelete = song; confirmDelete = true }
                                .disabled(backend.busy || backend.masteringActive)
                            Button("Show project in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([song.directory]) }
                        }
                        .background(library.state.selected == song.id ? StudioTheme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                    }
                    if library.filtered(backend.songs).isEmpty {
                        Text(library.search.isEmpty ? "Your songs will appear here.\nStart with a lyric and a musical idea." : "No matching songs")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 32).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").foregroundStyle(StudioTheme.highlight)
                Text("Made on your Mac").font(.caption).foregroundStyle(.secondary)
            }
            if let song = backend.songs.first(where: { $0.id == library.state.selected }) {
                Button("Move song to Trash…", systemImage: "trash") { pendingDelete = song; confirmDelete = true }
                    .buttonStyle(.plain).font(.caption).disabled(backend.busy || backend.masteringActive)
                    .help("Move this song’s audio, lyrics and generation files to the Mac Trash.")
            }
            Button("Open songs folder", systemImage: "folder") { NSWorkspace.shared.open(Paths.output) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.bottom, 18)
        }.padding(.horizontal, 16).frame(width: 224).background(StudioTheme.sidebar)
        .alert("Move song to Trash?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let song = pendingDelete { library.moveToTrash(song, backend: backend, player: player) }
                pendingDelete = nil
            }
        } message: {
            Text("“\(pendingDelete.map { library.title($0) } ?? "This song")” and its project files will move to the Mac Trash. Exported copies and mastering sessions stay where they are. Use Put Back in Finder to restore it.")
        }
    }
}

func stageName(_ song: Song) -> String {
    switch song.status {
    case .queued: "Waiting"
    case .planning: "Composing"
    case .tokens: "Arranging"
    case .synth: "Rendering"
    case .decode: "Finishing audio"
    case .ready: "Ready to listen"
    case .stalled: "Ready to recover"
    case .failed: "Needs attention"
    }
}
