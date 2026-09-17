import Foundation

enum GenerationQuality: String, CaseIterable, Codable, Identifiable {
    case full, draft
    var id: String { rawValue }
    var title: String { self == .full ? "Full quality" : "Draft preview" }
    var steps: Int { self == .full ? 32 : 8 }
    var summary: String { "\(steps) steps · full composition · lossless stereo" }
    var explanation: String {
        self == .full
            ? "Original precision and all 32 synthesis steps. Best for your finished song."
            : "8 synthesis steps for a faster preview. Planning stays full; sound is less refined. Finish the saved composition at full quality later."
    }
}

enum PromptField { case style, lyrics }

/// A clear is recoverable until the user writes new text or changes compositions.
struct ClearedPrompt {
    let field: PromptField
    let text: String
    let songID: String?
}
