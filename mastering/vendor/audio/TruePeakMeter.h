#pragma once

#include <JuceHeader.h>
#include "dsp/Polyphase4x.h"
#include <vector>

/** Streaming 4x polyphase true-peak meter. */
class TruePeakMeter
{
public:
    explicit TruePeakMeter (int channelCount);

    void reset();
    void process (const juce::AudioBuffer<float>& buffer);
    double getMaxTruePeakDb() const;

private:
    int channels = 0;
    Polyphase4x::Phases phases;
    std::vector<std::array<double, Polyphase4x::tapsPerPhase>> history;
    std::vector<int> writeIndex;
    double maxAbs = 0.0;
};
