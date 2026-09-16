import SwiftUI
import AppKit
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.usesFindBar = true; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        context.coordinator.rendered = 0
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let coordinator = context.coordinator
        if lines.count < coordinator.rendered || (lines.count == coordinator.rendered && lines.last?.id != coordinator.lastID) {                       // cleared
            storage.setAttributedString(NSAttributedString(string: "")); coordinator.rendered = 0
        }
        guard lines.count > coordinator.rendered else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: text.font!, .foregroundColor: NSColor.textColor]
        let chunk = lines[coordinator.rendered...].map { "\($0.time)  \($0.message)" }.joined(separator: "\n") + "\n"
        let atBottom = scroll.contentView.bounds.maxY >= (text.bounds.height - 40)
        storage.append(NSAttributedString(string: chunk, attributes: attrs))
        coordinator.rendered = lines.count; coordinator.lastID = lines.last?.id
        if atBottom || text.selectedRange().length == 0 { text.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var rendered = 0; var lastID: UUID? }
}
