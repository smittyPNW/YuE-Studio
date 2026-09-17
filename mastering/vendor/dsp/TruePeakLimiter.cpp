#include "TruePeakLimiter.h"
#include <algorithm>
#include <cmath>

void TruePeakLimiter::prepare (double sampleRate, int channelCount, int maximumBlockSize)
{
    channels = juce::jmax (1, channelCount);
    lookaheadSamples = juce::jmax (16, (int) std::round (lookaheadSeconds * sampleRate));
    releaseCoefficient = std::exp (-1.0 / (releaseSeconds * sampleRate));
    safetyCeilingLinear = std::pow (10.0, -detectionMarginDb / 20.0);
    phases = Polyphase4x::designPhases();
    delay.assign ((size_t) channels, std::vector<float> ((size_t) lookaheadSamples, 0.0f));
    history.assign ((size_t) channels, {});

    const size_t windowSize = (size_t) lookaheadSamples + 1;
    desiredRing.assign (windowSize, 1.0);
    dequeIndices.assign (windowSize + 1, 0);
    gainReductionTrace.assign ((size_t) juce::jmax (1, maximumBlockSize), 0.0f);
    reset();
}

void TruePeakLimiter::reset()
{
    for (auto& channel : delay)
        std::fill (channel.begin(), channel.end(), 0.0f);
    for (auto& channel : history)
        channel.fill (0.0);
    std::fill (desiredRing.begin(), desiredRing.end(), 1.0);
    delayIndex = 0;
    historyIndex = 0;
    sampleIndex = 0;
    dequeHead = 0;
    dequeTail = 0;
    envelope = 1.0;
    maxGainReductionDb = 0.0f;
    lastBlockMaxGainReductionDb = 0.0f;
    lastBlockMaxGainReductionSampleOffset = -1;
    gainReductionTraceSamples = 0;
    std::fill (gainReductionTrace.begin(), gainReductionTrace.end(), 0.0f);
}

void TruePeakLimiter::setCeilingDbTP (float ceilingDbTP)
{
    ceilingLinear = std::pow (10.0, ((double) ceilingDbTP - detectionMarginDb) / 20.0);
}

void TruePeakLimiter::setEnabled (bool shouldLimit)
{
    enabled = shouldLimit;
}

void TruePeakLimiter::process (juce::AudioBuffer<float>& buffer)
{
    lastBlockMaxGainReductionDb = 0.0f;
    lastBlockMaxGainReductionSampleOffset = -1;
    gainReductionTraceSamples = juce::jmin (buffer.getNumSamples(), (int) gainReductionTrace.size());
    std::fill_n (gainReductionTrace.begin(), gainReductionTraceSamples, 0.0f);
    if (lookaheadSamples <= 0 || delay.empty())
        return;

    const int channelCount = juce::jmin (channels, buffer.getNumChannels());
    const int taps = Polyphase4x::tapsPerPhase;
    const int64_t windowSize = (int64_t) lookaheadSamples + 1;

    for (int frame = 0; frame < buffer.getNumSamples(); ++frame)
    {
        double peak = 0.0;
        for (int channel = 0; channel < channelCount; ++channel)
        {
            const double x = buffer.getSample (channel, frame);
            history[(size_t) channel][(size_t) historyIndex] = x;
            peak = juce::jmax (peak, std::abs (x));

            for (const auto& phase : phases)
            {
                double value = 0.0;
                int read = historyIndex;
                for (const auto tap : phase)
                {
                    value += tap * history[(size_t) channel][(size_t) read];
                    read = read == 0 ? taps - 1 : read - 1;
                }
                peak = juce::jmax (peak, std::abs (value));
            }
        }
        historyIndex = (historyIndex + 1) % taps;

        // The user toggle disables the selected streaming ceiling, not digital
        // safety. An oversampled 0.0 dBTP emergency ceiling always remains so
        // no upstream drive or character can emit destructive over-range data.
        const double effectiveCeiling = enabled ? ceilingLinear : safetyCeilingLinear;
        const double desired = peak > effectiveCeiling ? effectiveCeiling / peak : 1.0;
        const size_t slot = (size_t) (sampleIndex % windowSize);
        desiredRing[slot] = desired;

        while (dequeTail > dequeHead)
        {
            const auto previous = dequeIndices[dequeTail - 1];
            if (desiredRing[(size_t) (previous % windowSize)] < desired)
                break;
            --dequeTail;
        }
        dequeIndices[dequeTail++] = sampleIndex;
        while (dequeTail > dequeHead && dequeIndices[dequeHead] <= sampleIndex - windowSize)
            ++dequeHead;

        if (dequeTail == dequeIndices.size())
        {
            const size_t count = dequeTail - dequeHead;
            for (size_t i = 0; i < count; ++i)
                dequeIndices[i] = dequeIndices[dequeHead + i];
            dequeHead = 0;
            dequeTail = count;
        }

        const double windowMinimum = desiredRing[(size_t) (dequeIndices[dequeHead] % windowSize)];
        const double recovering = releaseCoefficient * envelope
                                + (1.0 - releaseCoefficient) * windowMinimum;
        envelope = std::min (windowMinimum, recovering);
        if (envelope < 1.0)
        {
            const auto reduction = (float) (-20.0 * std::log10 (envelope));
            if (frame < gainReductionTraceSamples)
                gainReductionTrace[(size_t) frame] = reduction;
            maxGainReductionDb = juce::jmax (maxGainReductionDb, reduction);
            if (reduction > lastBlockMaxGainReductionDb)
            {
                lastBlockMaxGainReductionDb = reduction;
                lastBlockMaxGainReductionSampleOffset = frame;
            }
        }

        const float gain = (float) envelope;
        for (int channel = 0; channel < channelCount; ++channel)
        {
            const float delayed = delay[(size_t) channel][(size_t) delayIndex];
            delay[(size_t) channel][(size_t) delayIndex] = buffer.getSample (channel, frame);
            buffer.setSample (channel, frame, delayed * gain);
        }
        delayIndex = (delayIndex + 1) % lookaheadSamples;
        ++sampleIndex;
    }
}
