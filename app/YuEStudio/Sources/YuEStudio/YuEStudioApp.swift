import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var backend: Backend?
    var library: StudioLibrary?
    var mastering: MasteringController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if backend?.busy == true || mastering?.busy == true {
            let alert = NSAlert()
            alert.messageText = "Audio work is still running"
            alert.informativeText = "Quitting cancels current work. Saved compositions and finished recordings remain in your library."
            alert.addButton(withTitle: "Keep rendering"); alert.addButton(withTitle: "Quit and cancel")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        library?.save(); mastering?.save(); mastering?.cancel(); backend?.quit(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct YuEStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var backend = Backend()
    @State private var library = StudioLibrary()
    @State private var player = StudioPlayer()
    @State private var mastering = MasteringController()
    @AppStorage("workspace") private var workspace = "create"
    private var activePlayer: StudioPlayer { workspace == "master" ? mastering.player : player }
    var body: some Scene {
        Window("YuE Studio", id: "studio") {
            StudioRoot(library: library, player: player, mastering: mastering).environmentObject(backend)
                .onAppear { delegate.backend = backend; delegate.library = library; delegate.mastering = mastering; NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Song") { workspace = "create"; library.newSong() }.keyboardShortcut("n") }
            CommandMenu("Studio") {
                Button(activePlayer.playing ? "Pause" : "Play") { activePlayer.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(activePlayer.songID == nil)
                Button("Workspace Settings") { if workspace == "master" { mastering.showAdvanced.toggle() } else { library.showInspector.toggle() } }.keyboardShortcut(",")
                Button("Open Songs Folder") { NSWorkspace.shared.open(Paths.output) }
                Divider()
                Button("Stop Current Work") { if mastering.busy { mastering.cancel() } else { backend.stop() } }.disabled(!backend.busy && !mastering.busy)
                Button("Free Model Memory") { backend.send(["cmd":"unload"]) }.disabled(backend.busy || !backend.connected)
            }
        }
    }
}
