import Foundation

struct StudioFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

struct MasterEQ: Codable, Equatable, Identifiable {
    var enabled: Bool; var frequencyHz: Double; var gainDb: Double; var q: Double; var type: Int
    var id: Double { frequencyHz }
}
struct MasterParameters: Codable, Equatable {
    var version = 2
    var masteredPath = true; var loopEnabled = false
    var fadeInSec = 0.0; var fadeOutSec = 0.0
    var monoLow = 0.0; var monoHigh = 0.0; var width = 0.5
    var punch = 0.0; var deChirp = 0.0; var deEsser = 0.0
    var bass = 0.5; var mud = 0.0; var mid = 0.5; var treble = 0.5
    var lowCut = false; var hiCut = false
    var warmth = 0.0; var analogLife = 0.0; var warmExciter = 0.0; var airExciter = 0.0; var tapeHiss = 0.0
    var masterVolDb = 0.0; var finalCharacter = 0
    var eq = [MasterEQ(enabled: true, frequencyHz: 40, gainDb: 0, q: 0.7, type: 1), MasterEQ(enabled: true, frequencyHz: 85, gainDb: 0, q: 1, type: 0), MasterEQ(enabled: true, frequencyHz: 220, gainDb: 0, q: 1, type: 0), MasterEQ(enabled: true, frequencyHz: 2500, gainDb: 0, q: 1, type: 0), MasterEQ(enabled: true, frequencyHz: 12000, gainDb: 0, q: 0.7, type: 2), MasterEQ(enabled: false, frequencyHz: 18000, gainDb: 0, q: 0.7, type: 4)]
    var loudnessPreset = 0; var targetLufs = -14.0; var ceilingDb = -1.0; var useTruePeak = true
    var normalizeGainDb = 0.0; var normalizeActive = false
    func hiFi() -> MasterParameters {
        var result = self
        result.bass = 0.625 // +1.5 dB low shelf
        result.mud = 0.12
        result.mid = 0.5
        result.treble = 0.55 // +0.6 dB high shelf
        result.punch = 0.08
        result.warmExciter = 0.04
        result.airExciter = 0.02
        result.targetLufs = -14; result.loudnessPreset = 0
        result.normalizeActive = true; result.normalizeGainDb = 0
        result.ceilingDb = min(ceilingDb, -1); result.useTruePeak = true
        return result
    }
    /// Whole-song measured loudness; the renderer retains its 3 dB peak-reduction
    /// budget, so very dynamic material may finish below the requested target.
    func maxVolume() -> MasterParameters {
        var result = self
        result.targetLufs = -9; result.loudnessPreset = 1
        result.normalizeActive = true; result.normalizeGainDb = 0
        result.useTruePeak = true; result.ceilingDb = min(ceilingDb, -1)
        result.masterVolDb = 0; result.finalCharacter = 0
        return result
    }
    var dictionary: [String:Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String:Any]) ?? [:] }
}
struct MasterMeasurement: Codable, Equatable {
    var lufs: Double; var truePeak: Double; var samplePeak: Double
}
struct MasterPreset: Decodable, Identifiable {
    var name: String; var description: String; var parameters: MasterParameters
    var id: String { name }
    var displayName: String { name.replacingOccurrences(of: "GENRE / ", with: "") }
}
struct MasterVersion: Codable, Identifiable {
    var id: UUID; var path: String; var created: Date; var parameters: MasterParameters
    var measurement: MasterMeasurement; var preset: String
}
struct MasterSession: Codable, Identifiable {
    var id = UUID(); var title: String; var source: String; var originalName: String
    var originalPath = ""; var artist = ""; var created = Date(); var duration = 0.0; var sampleRate = 0.0
    var parameters = MasterParameters(); var preset = "Neutral / Manual"
    var measurement: MasterMeasurement?; var versions: [MasterVersion] = []
    var folder: URL { URL(fileURLWithPath: source).deletingLastPathComponent() }
}
struct MasterLibrary: Codable { var sessions: [MasterSession] = []; var selected: UUID? }
struct MasterResponse: Decodable {
    var event: String; var message: String?; var analysis: MasterMeasurement?; var parameters: MasterParameters?
    var output: String?; var duration: Double?; var sampleRate: Double?
}

/// The last delivered audio has its own immutable settings. Editing controls never
/// mislabels that old render as an audition of the current settings.
func masterNeedsRender(parameters: MasterParameters, version: MasterVersion?) -> Bool {
    version == nil || version?.parameters != parameters
}

/// Sparse Studio Mastering quick repairs change only the fields touched by that repair,
/// including individual EQ values. Unrelated custom bands stay intact.
func applyingMasterPatch(_ patch: Any, to base: Any) -> Any {
    guard let changes = patch as? [String:Any] else { return patch }
    if var array = base as? [Any] {
        for (key, value) in changes { if let index = Int(key), array.indices.contains(index) { array[index] = applyingMasterPatch(value, to: array[index]) } }
        return array
    }
    var object = base as? [String:Any] ?? [:]
    for (key, value) in changes { object[key] = applyingMasterPatch(value, to: object[key] ?? NSNull()) }
    return object
}
