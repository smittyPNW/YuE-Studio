#include "LoudnessAnalyzer.h"
#include "StreamingMeterProcessor.h"
#include <algorithm>

LoudnessAnalyzer::Result LoudnessAnalyzer::analyze (const juce::AudioBuffer<float>& buffer,
                                                    double sampleRate,
                                                    const std::atomic<bool>* cancelled)
{
    Result result;
    if (buffer.getNumSamples() == 0 || buffer.getNumChannels() == 0 || sampleRate <= 0.0)
        return result;

    // The previous analyzer materialised two full-song arrays of doubles for
    // K-weighted audio. A three-minute stereo song therefore consumed roughly
    // 130 MB just for measurement, on top of the decoded song itself. Reuse the
    // production streaming meter so analysis remains bounded to a few seconds
    // of ring history regardless of song length.
    StreamingMeterProcessor meter;
    meter.prepare (sampleRate);
    constexpr int analysisChunk = 16384;
    const int samples = buffer.getNumSamples();
    const int rightChannel = juce::jmin (1, buffer.getNumChannels() - 1);
    for (int position = 0; position < samples; position += analysisChunk)
    {
        if (cancelled != nullptr && cancelled->load())
            return {};
        const int count = juce::jmin (analysisChunk, samples - position);
        meter.process (buffer.getReadPointer (0, position),
                       buffer.getReadPointer (rightChannel, position), count, 1);
    }

    const auto snapshot = meter.snapshot (0.0f, false);
    if (snapshot.integratedValid)
        result.integratedLufs = snapshot.integratedLufs;
    result.truePeakDb = std::max (snapshot.truePeakDbL, snapshot.truePeakDbR);
    result.samplePeakDb = std::max (snapshot.samplePeakDbL, snapshot.samplePeakDbR);

    return result;
}

float LoudnessAnalyzer::computeNormalizeGainDb (float measuredLufs, float targetLufs,
                                                float measuredTruePeakDb, float ceilingDb)
{
    float gain = targetLufs - measuredLufs;
    const float predictedTruePeak = measuredTruePeakDb + gain;
    if (predictedTruePeak > ceilingDb)
        gain -= predictedTruePeak - ceilingDb;
    return gain;
}
