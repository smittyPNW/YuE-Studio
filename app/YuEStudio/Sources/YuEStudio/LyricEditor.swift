import SwiftUI
import AppKit

struct EditorJump: Equatable { let id = UUID(); let range: NSRange }
struct LyricSection: Identifiable { let id: Int; let title: String; let range: NSRange }
func lyricSections(_ text: String) -> [LyricSection] {
    var offset = 0
    var result: [LyricSection] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("["), line.hasSuffix("]") { result.append(LyricSection(id: offset, title: String(line.dropFirst().dropLast()), range: NSRange(location: offset, length: (line as NSString).length))) }
        offset += (line as NSString).length + 1
    }
    return result
}
struct LyricEditor: NSViewRepresentable {
    @Binding var text: String
    var jump: EditorJump?
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = NSTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.font = .systemFont(ofSize: 16); editor.textContainerInset = NSSize(width: 20, height: 18)
        editor.drawsBackground = false; editor.textColor = NSColor(StudioTheme.ink); editor.insertionPointColor = .controlAccentColor
        editor.delegate = context.coordinator; editor.setAccessibilityLabel("Song lyrics")
        editor.string = text; scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text { editor.string = text }
        editor.textColor = NSColor(StudioTheme.ink)
        if let jump, context.coordinator.lastJump != jump.id, NSMaxRange(jump.range) <= (editor.string as NSString).length {
            context.coordinator.lastJump = jump.id
            editor.setSelectedRange(jump.range); editor.scrollRangeToVisible(jump.range); editor.window?.makeFirstResponder(editor)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LyricEditor; var lastJump: UUID?
        init(_ parent: LyricEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}
