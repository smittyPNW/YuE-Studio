#pragma once
#include <JuceHeader.h>
#include <array>
#include <vector>

enum class FinalCharacter
{
    CleanSafety = 0,
    AnalogConsole,
    VacuumTube,
    MagneticTape,
    SoftKneeDiode
};

/** Human-readable name, matching the picker labels — user-facing text must
    never leak a raw enum ordinal (the export report used to print "1"). */
inline const char* toDisplayName (FinalCharacter character)
{
    switch (character)
    {
        case FinalCharacter::CleanSafety:   return "Clean & Safe";
        case FinalCharacter::AnalogConsole: return "Analog Console";
        case FinalCharacter::VacuumTube:    return "Warm Tube";
        case FinalCharacter::MagneticTape:  return "Magnetic Tape";
        case FinalCharacter::SoftKneeDiode: return "Soft Clip";
    }
    return "Clean & Safe";
}

enum class LoudnessPreset
{
    StreamingUniversal = 0, // -14 / -1.0
    SpotifyLoud,            // -11 / -1.0
    AppleMusic,             // -16 / -1.0
    Podcast,                // -16 / -1.5
    ClubDemo,               // -9 / -0.8
    Custom
};

enum class GenrePreset
{
    HipHopSubBass = 0,
    AcousticIntimate,
    EDMLoud,
    ClassicalDynamic
};

struct EqBand
{
    bool enabled = true;
    float frequencyHz = 1000.0f;
    float gainDb = 0.0f;
    float q = 1.0f;
    int type = 0; // 0 bell, 1 lowShelf, 2 highShelf, 3 highPass, 4 lowPass
};

/** Central parameter model for the mastering chain + UI. */
struct ParameterState
{
    // Transport / view
    bool masteredPath = false; // false = Raw A/B; start safely on the unprocessed source
    bool loopEnabled = false;
    float fadeInSec = 0.0f;
    float fadeOutSec = 0.0f;

    // Stereo
    float monoLow = 0.0f;
    float monoHigh = 0.0f;
    float width = 0.5f; // maps to 0.75–1.35

    // Dynamics / artifacts
    float punch = 0.0f;
    float deChirp = 0.0f;
    float deEsser = 0.0f;

    // Tone
    float bass = 0.5f;    // maps ±6 dB around 0
    float mud = 0.0f;     // cut amount
    float mid = 0.5f;
    float treble = 0.5f;
    bool lowCut = false;
    bool hiCut = false;

    // Harmonics
    float warmth = 0.0f;
    float analogLife = 0.0f;
    float warmExciter = 0.0f;
    float airExciter = 0.0f;
    float tapeHiss = 0.0f;

    // Output
    float masterVolDb = 0.0f; // -12..+18
    FinalCharacter finalCharacter = FinalCharacter::CleanSafety;

    // EQ nodes
    std::array<EqBand, 6> eq {{
        EqBand { true, 40.f,  0.f, 0.7f, 1 },
        EqBand { true, 85.f,  0.f, 1.0f, 0 },
        EqBand { true, 220.f, 0.f, 1.0f, 0 },
        EqBand { true, 2500.f,0.f, 1.0f, 0 },
        EqBand { true, 12000.f,0.f,0.7f, 2 },
        EqBand { false,18000.f,0.f,0.7f, 4 }
    }};

    // Normalize
    LoudnessPreset loudnessPreset = LoudnessPreset::StreamingUniversal;
    float targetLufs = -14.0f;
    float ceilingDb = -1.0f;
    bool useTruePeak = true;
    float normalizeGainDb = 0.0f; // applied post-chain when set
    bool normalizeActive = false;

    // Analysis cache
    float measuredIntegratedLufs = -70.0f;
    float measuredTruePeakDb = -70.0f;
    float shortTermLufs = -70.0f;
    float outputPeakL = 0.0f;
    float outputPeakR = 0.0f;

    void resetToDefaults();
    void applyQuickFixHumanize();
    void applyQuickFixStereo();
    void applyQuickFixBass();
    void applyQuickFixMid();
    void applyQuickFixHigh();
    void applyGenrePreset (GenrePreset preset);

    juce::var toVar() const;
    void fromVar (const juce::var& v);

    static float mapWidth (float knob01);
    static float unmapWidth (float widthMultiplier);
    static float mapToneShelfDb (float knob01); // 0..1 → -6..+6
};

/** Simple undo stack for parameter snapshots. */
class UndoStack
{
public:
    void push (const ParameterState& s);
    bool canUndo() const { return ! history.empty(); }
    bool canRedo() const { return ! redoHistory.empty(); }
    ParameterState undo (const ParameterState& current);
    ParameterState redo (const ParameterState& current);
    void clear();

private:
    std::vector<ParameterState> history;
    std::vector<ParameterState> redoHistory;
    static constexpr int maxDepth = 40;
};
