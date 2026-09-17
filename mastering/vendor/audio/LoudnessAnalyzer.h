#pragma once
#include <JuceHeader.h>
#include <atomic>

/** ITU-R BS.1770-4 integrated loudness and 4x true-peak analysis. */
class LoudnessAnalyzer
{
public:
    struct Result
    {
        float integratedLufs = -70.0f;
        float truePeakDb = -70.0f;
        float samplePeakDb = -70.0f;
    };

    /** Full-song measurement in bounded memory. `cancelled`, when supplied, is
        checked between analysis chunks so a superseded or user-cancelled run
        stops promptly; a cancelled run returns the default (invalid) Result. */
    static Result analyze (const juce::AudioBuffer<float>& buffer, double sampleRate,
                           const std::atomic<bool>* cancelled = nullptr);
    static float computeNormalizeGainDb (float measuredLufs, float targetLufs,
                                         float measuredTruePeakDb, float ceilingDb);
};
