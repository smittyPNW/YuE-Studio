#pragma once

#include <JuceHeader.h>
#include "Polyphase4x.h"
#include <vector>

/** Stereo-linked 4x true-peak limiter with lookahead and latency reporting. */
class TruePeakLimiter
{
public:
    void prepare (double sampleRate, int channelCount = 2, int maximumBlockSize = 8192);
    void reset();
    void setCeilingDbTP (float ceilingDbTP);
    void setEnabled (bool shouldLimit);
    void process (juce::AudioBuffer<float>& buffer);

    int getLatencySamples() const { return lookaheadSamples; }
    float getMaxGainReductionDb() const { return maxGainReductionDb; }
    float getCurrentGainReductionDb() const
    {
        return envelope < 1.0 ? (float) (-20.0 * std::log10 (envelope)) : 0.0f;
    }
    float getLastBlockMaxGainReductionDb() const { return lastBlockMaxGainReductionDb; }
    int getLastBlockMaxGainReductionSampleOffset() const { return lastBlockMaxGainReductionSampleOffset; }
    const float* getLastGainReductionTrace() const { return gainReductionTrace.data(); }
    int getLastGainReductionTraceSamples() const { return gainReductionTraceSamples; }

private:
    static constexpr double detectionMarginDb = 0.12;
    static constexpr double lookaheadSeconds = 0.005;
    static constexpr double releaseSeconds = 0.100;

    int channels = 2;
    int lookaheadSamples = 0;
    int delayIndex = 0;
    int historyIndex = 0;
    int64_t sampleIndex = 0;
    double ceilingLinear = 1.0;
    double safetyCeilingLinear = 1.0;
    double releaseCoefficient = 0.0;
    double envelope = 1.0;
    bool enabled = true;
    float maxGainReductionDb = 0.0f;
    float lastBlockMaxGainReductionDb = 0.0f;
    int lastBlockMaxGainReductionSampleOffset = -1;
    std::vector<float> gainReductionTrace;
    int gainReductionTraceSamples = 0;

    Polyphase4x::Phases phases;
    std::vector<std::vector<float>> delay;
    std::vector<std::array<double, Polyphase4x::tapsPerPhase>> history;
    std::vector<double> desiredRing;
    std::vector<int64_t> dequeIndices;
    size_t dequeHead = 0;
    size_t dequeTail = 0;
};
