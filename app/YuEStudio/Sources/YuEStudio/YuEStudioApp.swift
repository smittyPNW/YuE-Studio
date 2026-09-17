import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var backend: Backend?
    var library: StudioLibrary?
    var mastering: MasteringController?
    var editor: EditController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if backend?.busy == true || mastering?.busy == true || editor?.busy == true {
            let alert = NSAlert()
            alert.messageText = "Audio work is still running"
            alert.informativeText = "Quitting cancels current work. Saved compositions and finished recordings remain in your library."
            alert.addButton(withTitle: "Keep rendering"); alert.addButton(withTitle: "Quit and cancel")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        library?.save(); mastering?.save(); mastering?.cancel(); editor?.cancel(); backend?.quit(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct YuEStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var backend = Backend()
    @State private var library = StudioLibrary()
    @State private var player = StudioPlayer()
    @State private var mastering = MasteringController()
    @State private var editor = EditController()
    @AppStorage("workspace") private var workspace = "create"
    private var activePlayer: StudioPlayer { workspace == "master" ? mastering.player : player }
    var body: some Scene {
        Window("YuE Studio", id: "studio") {
            StudioRoot(library: library, player: player, mastering: mastering, editor: editor).environmentObject(backend)
                .onAppear { delegate.backend = backend; delegate.library = library; delegate.mastering = mastering; delegate.editor = editor; editor.backend = backend; NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Song") { workspace = "create"; library.newSong() }.keyboardShortcut("n") }
            CommandMenu("Audio Editing") {
                Button("Open Recording…") { workspace = "edit"; editor.chooseFile() }.keyboardShortcut("o").disabled(editor.unavailable)
                Button("Undo Audio Edit") { editor.undo() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(workspace != "edit" || editor.unavailable || editor.project?.undo.isEmpty != false)
                Button("Redo Audio Edit") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .option, .shift]).disabled(workspace != "edit" || editor.unavailable || editor.project?.redo.isEmpty != false)
                Divider()
                Button("Split at Playhead") { editor.split() }.keyboardShortcut("t", modifiers: [.command]).disabled(workspace != "edit" || editor.unavailable || editor.frames == 0)
                Button("Select All Audio") { editor.selectAll() }.keyboardShortcut("a", modifiers: [.command, .option]).disabled(workspace != "edit" || editor.busy)
                Button("Copy Audio Selection") { editor.copy() }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(workspace != "edit" || editor.unavailable || editor.selection.isEmpty)
                Button("Cut Audio Selection") { editor.cut() }.keyboardShortcut("x", modifiers: [.command, .option]).disabled(workspace != "edit" || editor.unavailable || editor.selection.isEmpty)
                Button("Paste Audio at Playhead") { editor.paste() }.keyboardShortcut("v", modifiers: [.command, .option]).disabled(workspace != "edit" || editor.unavailable || !editor.canPaste)
            }
            CommandMenu("Studio") {
                Button("Play / Pause") { if workspace == "edit" { editor.transport.toggle(selection: editor.selection) } else { activePlayer.toggle() } }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(workspace == "edit" ? editor.busy || editor.frames == 0 : activePlayer.songID == nil)
                Button("Workspace Settings") { if workspace == "edit" { editor.showInspector.toggle() } else if workspace == "master" { mastering.showAdvanced.toggle() } else { library.showInspector.toggle() } }.keyboardShortcut(",")
                Button("Open Songs Folder") { NSWorkspace.shared.open(Paths.output) }
                Divider()
                Button("Stop Current Work") { if editor.busy { editor.cancel() } else if mastering.busy { mastering.cancel() } else { backend.stop() } }.disabled(!backend.busy && !mastering.busy && !editor.busy)
                Button("Free Model Memory") { backend.send(["cmd":"unload"]) }.disabled(backend.busy || !backend.connected)
            }
        }
    }
}
