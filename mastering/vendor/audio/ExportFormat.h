#pragma once
#include <JuceHeader.h>

/*  Delivery formats offered at export.

    Deliberately small. Mastering engineers want a studio master and a
    reference copy they can send someone; a wall of codecs and bitrates is
    noise for everyone else. Three formats, each with two or three qualities,
    and the quality list changes with the format so the numbers on screen
    always mean something for the format actually selected.

    Everything here is pure and lives away from the UI so the rules can be
    contract-tested — in particular `clampQuality`, because a stale index
    carried across a format change is the obvious defect in a two-dropdown
    design (pick MP3 at 192 kbps, switch to WAV, and index 2 no longer exists).
*/
namespace ExportFormat
{
enum class Kind
{
    wav = 0,   ///< Uncompressed. The deliverable.
    mp3,       ///< Lossy, universally recognised. Encoded with LAME.
    m4a,       ///< Lossy AAC. Smaller than MP3 at equal quality.
    count
};

inline constexpr int kindCount = (int) Kind::count;

struct QualityOption
{
    const char* label;   ///< what the user reads
    int value;           ///< bit depth for WAV, kbps for MP3/M4A
};

/** A view over a format's fixed quality table. Non-owning and allocation-free
    so it is safe to call from anywhere, including a paint or resize path. */
struct QualityList
{
    const QualityOption* items = nullptr;
    int count = 0;

    int size() const noexcept { return count; }
    bool isEmpty() const noexcept { return count == 0; }
    const QualityOption& operator[] (int i) const noexcept { return items[i]; }
};

/** Quality choices for a format, best first. */
inline QualityList qualityOptions (Kind kind)
{
    static constexpr QualityOption wavOptions[] {
        { "24-bit (studio)", 24 }, { "16-bit (CD)", 16 } };
    static constexpr QualityOption mp3Options[] {
        { "320 kbps", 320 }, { "256 kbps", 256 }, { "192 kbps", 192 } };
    static constexpr QualityOption m4aOptions[] {
        { "256 kbps", 256 }, { "192 kbps", 192 }, { "128 kbps", 128 } };

    switch (kind)
    {
        case Kind::wav: return { wavOptions, (int) std::size (wavOptions) };
        case Kind::mp3: return { mp3Options, (int) std::size (mp3Options) };
        case Kind::m4a: return { m4aOptions, (int) std::size (m4aOptions) };
        case Kind::count:
        default: break;
    }
    return {};
}

inline juce::String formatName (Kind kind)
{
    switch (kind)
    {
        case Kind::wav: return "WAV";
        case Kind::mp3: return "MP3";
        case Kind::m4a: return "M4A";
        case Kind::count:
        default: break;
    }
    return "WAV";
}

inline juce::String fileExtension (Kind kind)
{
    switch (kind)
    {
        case Kind::wav: return ".wav";
        case Kind::mp3: return ".mp3";
        case Kind::m4a: return ".m4a";
        case Kind::count:
        default: break;
    }
    return ".wav";
}

/** One line of plain language under the picker, so the choice is informed
    without needing audio-engineering background. */
inline juce::String formatBlurb (Kind kind)
{
    switch (kind)
    {
        case Kind::wav: return "Uncompressed. Send this to distributors and pressing plants.";
        case Kind::mp3: return "Plays everywhere. Good for sharing a reference.";
        case Kind::m4a: return "Same quality as MP3 at a smaller size. Apple-friendly.";
        case Kind::count:
        default: break;
    }
    return {};
}

inline bool isLossless (Kind kind) { return kind == Kind::wav; }

/** Keeps a quality index meaningful when the format changes. Out-of-range
    indices collapse to the best quality rather than the nearest one: silently
    downgrading someone's master because they switched format would be worse
    than resetting to the top option. */
inline int clampQuality (Kind kind, int index)
{
    const int n = qualityOptions (kind).size();
    if (n <= 0)
        return 0;
    return (index >= 0 && index < n) ? index : 0;
}

inline QualityOption quality (Kind kind, int index)
{
    const auto options = qualityOptions (kind);
    jassert (! options.isEmpty());
    return options[clampQuality (kind, index)];
}

/** "MP3 - 320 kbps" — used on the export button and in the written report so
    the delivered file always says what it is. */
inline juce::String describe (Kind kind, int index)
{
    return formatName (kind) + " - " + juce::String (quality (kind, index).label);
}

inline Kind kindFromIndex (int index)
{
    return (index >= 0 && index < kindCount) ? (Kind) index : Kind::wav;
}

/** Lossy formats cannot carry an honest true-peak guarantee: the decoder
    reconstructs a waveform that can overshoot what we measured before
    encoding. Studio Mastering leaves extra headroom for them rather than claiming a
    ceiling it cannot hold. 1 dB is the usual mastering allowance for
    codec overshoot. */
inline float extraHeadroomDb (Kind kind) { return isLossless (kind) ? 0.0f : 1.0f; }

/** Highest rate the format can actually carry. MPEG-1 Layer III stops at
    48 kHz, so a 96 kHz master MUST be converted before it reaches LAME —
    handing it a rate it cannot encode is a silent failure otherwise. AAC is
    capped to the same rate deliberately: nothing that plays a lossy reference
    copy benefits from 96 kHz. WAV is unconstrained. */
inline double maxSampleRate (Kind kind) { return isLossless (kind) ? 0.0 : 48000.0; }

/** The rate this format will actually deliver, given what the user asked for
    and what the source is. 0 means "keep the source rate". */
inline double resolveDeliveryRate (Kind kind, double requestedRate, double sourceRate)
{
    const double intended = requestedRate > 0.0 ? requestedRate : sourceRate;
    const double ceiling = maxSampleRate (kind);
    if (ceiling <= 0.0 || intended <= ceiling)
        return intended;
    // Step down to the nearest standard rate at or below the ceiling, keeping
    // the 44.1 kHz family on 44.1 so a CD-rate master is not needlessly
    // resampled onto the 48 kHz grid.
    return std::fmod (intended, 44100.0) == 0.0 ? 44100.0 : 48000.0;
}
}
