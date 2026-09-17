import SwiftUI

@MainActor
struct PromptClearButton: View {
    @Bindable var library: StudioLibrary
    let field: PromptField
    private var name: String { field == .style ? "style" : "lyrics" }
    var body: some View {
        if library.canRestore(field) {
            Button("Undo clear", systemImage: "arrow.uturn.backward") { library.restorePrompt(field) }
                .buttonStyle(.borderless).font(.caption)
                .accessibilityLabel("Restore cleared \(name)")
        } else {
            Button("Clear", systemImage: "xmark.circle") { library.clearPrompt(field) }
                .buttonStyle(.borderless).font(.caption)
                .disabled(library.promptText(field).isEmpty)
                .accessibilityLabel("Clear \(name)")
                .help("Clear this field. Undo clear will restore its text.")
        }
    }
}
