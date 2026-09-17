import Foundation

struct EditClip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var asset: String
    var start: Int64
    var count: Int64
    var name: String
}

struct EditMarker: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var frame: Int64
    var name: String
}

struct EditDocument: Codable, Equatable, Sendable {
    var title: String
    var sampleRate: Double
    var channels: UInt32
    var clips: [EditClip]
    var markers: [EditMarker] = []
    var frames: Int64 { clips.reduce(0) { $0 + $1.count } }
    var duration: Double { Double(frames) / sampleRate }

    func validate() throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate), (1...2).contains(channels), clips.count <= 10000 else {
            throw StudioFailure("Use mono or stereo audio with a supported sample rate.")
        }
        let limit = min(Int64(UInt32.max), Int64(sampleRate * 60 * 60 * 4))
        var total: Int64 = 0
        for clip in clips {
            guard clip.count > 0, clip.count <= limit, clip.start >= 0, clip.start <= Int64.max - clip.count,
                  total <= limit - clip.count, clip.asset == URL(fileURLWithPath: clip.asset).lastPathComponent,
                  !clip.asset.hasPrefix(".") else { throw StudioFailure("Invalid clip data, or this project exceeds four hours / 4.29 billion samples.") }
            total += clip.count
        }
        guard markers.allSatisfy({ (0...total).contains($0.frame) }) else { throw StudioFailure("A marker is outside this recording.") }
    }

    func bounded(_ range: Range<Int64>) -> Range<Int64> {
        let low = min(frames, max(0, range.lowerBound))
        return low..<min(frames, max(low, range.upperBound))
    }

    func slice(_ requested: Range<Int64>) -> [EditClip] {
        let range = bounded(requested)
        var cursor: Int64 = 0
        return clips.compactMap { clip in
            defer { cursor += clip.count }
            let lower = max(cursor, range.lowerBound), upper = min(cursor + clip.count, range.upperBound)
            guard upper > lower else { return nil }
            return EditClip(asset: clip.asset, start: clip.start + lower - cursor, count: upper - lower, name: clip.name)
        }
    }

    mutating func replace(_ requested: Range<Int64>, with replacement: [EditClip]) {
        let range = bounded(requested)
        let inserted = replacement.reduce(Int64(0)) { $0 + $1.count }
        let delta = inserted - range.count64
        clips = slice(0..<range.lowerBound) + replacement + slice(range.upperBound..<frames)
        // Markers inside a replacement follow its beginning; later markers follow ripple edits.
        markers = markers.map { marker in
            var result = marker
            if marker.frame >= range.upperBound { result.frame += delta }
            else if marker.frame > range.lowerBound { result.frame = range.lowerBound + min(inserted, marker.frame - range.lowerBound) }
            result.frame = min(frames, max(0, result.frame)); return result
        }
    }

    mutating func split(at frame: Int64) {
        guard frame > 0, frame < frames else { return }
        clips = slice(0..<frame) + slice(frame..<frames)
    }

    mutating func trim(to requested: Range<Int64>) {
        let range = bounded(requested)
        clips = slice(range)
        markers = markers.filter { range.contains($0.frame) }.map {
            var value = $0; value.frame -= range.lowerBound; return value
        }
    }

    mutating func moveClip(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard clips.indices.contains(index), clips.indices.contains(destination) else { return }
        let old = clips
        let positions = old.indices.map { old.prefix($0).reduce(Int64(0)) { $0 + $1.count } }
        clips.swapAt(index, destination)
        // Keep each marker attached to the same content when sections are moved.
        markers = markers.map { marker in
            guard let owner = old.indices.first(where: { marker.frame >= positions[$0] && marker.frame < positions[$0] + old[$0].count }),
                  let newIndex = clips.firstIndex(where: { $0.id == old[owner].id }) else { return marker }
            var value = marker
            value.frame = clips.prefix(newIndex).reduce(Int64(0)) { $0 + $1.count } + marker.frame - positions[owner]
            return value
        }
    }
}

extension Range where Bound == Int64 { var count64: Int64 { upperBound - lowerBound } }

struct EditRevision: Codable, Sendable {
    var name: String
    var document: EditDocument
}

struct EditProject: Codable, Sendable {
    var version = 1
    var document: EditDocument
    var undo: [EditRevision] = []
    var redo: [EditRevision] = []
    mutating func record(_ next: EditDocument, name: String) {
        undo.append(EditRevision(name: name, document: document))
        if undo.count > 60 { undo.removeFirst(undo.count - 60) }
        redo = []; document = next
    }
    mutating func stepBack() {
        guard let previous = undo.popLast() else { return }
        redo.append(EditRevision(name: previous.name, document: document)); document = previous.document
    }
    mutating func stepForward() {
        guard let next = redo.popLast() else { return }
        undo.append(EditRevision(name: next.name, document: document)); document = next.document
    }
    static func read(_ folder: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("edit-project.json")))
        guard value.version == 1 else { throw StudioFailure("This project needs a newer version of Studio.") }
        try value.document.validate(); return value
    }
    func save(_ folder: URL) throws {
        try document.validate()
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("edit-project.json"), options: .atomic)
    }
}
