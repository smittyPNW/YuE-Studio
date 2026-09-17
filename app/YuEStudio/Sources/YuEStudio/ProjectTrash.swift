import Foundation
import Darwin

/// Only owned project directories can enter Trash. Never follow a symlink out
/// of a library, delete a library root, or touch an externally imported original.
enum ProjectTrash {
    static func validate(_ folder: URL, root: URL, depth: Int) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let lexical = folder.standardizedFileURL
        let actual = lexical.resolvingSymlinksInPath()
        guard lexical.path == actual.path,
              actual.pathComponents.count == base.pathComponents.count + depth,
              Array(actual.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              (try actual.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw StudioFailure("This project is outside the Studio library. No files were moved.")
        }
    }
    static func move(_ folder: URL, root: URL, depth: Int, lock: URL,
                     metadata: Data, metadataName: String,
                     mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try validate(folder, root: root, depth: depth)
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StudioFailure("Could not lock the project library. Try again.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw StudioFailure("An audio job is still running. Let it finish before moving a project to Trash.")
        }
        defer { flock(fd, LOCK_UN) }
        // Travel with the audio, so Put Back also recovers editable settings.
        try metadata.write(to: folder.appendingPathComponent(metadataName), options: .atomic)
        try mover(folder)
    }
}
