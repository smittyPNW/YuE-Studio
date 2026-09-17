import Foundation

/// Prevent App Nap and automatic system sleep only while the user's render is active.
/// This does not prevent display sleep, explicit Sleep, or application termination.
final class RenderActivity {
    private var token: NSObjectProtocol?
    var isActive: Bool { token != nil }

    func setActive(_ active: Bool) {
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Rendering a YuE Studio song")
        } else if !active, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit { if let token { ProcessInfo.processInfo.endActivity(token) } }
}
