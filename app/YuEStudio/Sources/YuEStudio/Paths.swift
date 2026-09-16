import Foundation

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/YuE Studio")
    static let custom = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/YuE Studio Custom")
    static let python = support.appendingPathComponent("env/bin/python")
    static let worker = Bundle.main.resourceURL!.appendingPathComponent("worker/yue2_worker.py")
    static let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/YuE Studio")
    static var workerEnvironment: [String:String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HOME"] = support.appendingPathComponent("models").path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["YUE2_OUTPUT_DIR"] = output.path
        env["YUE2_ANE_CACHE"] = support.appendingPathComponent("ane-cache").path
        env["YUE2_PIPELINE"] = "0"
        env["YUE2_IDLE_UNLOAD_S"] = "120"
        env["YUE_STUDIO_LOCK"] = custom.appendingPathComponent("worker.lock").path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}
