#include "TruePeakMeter.h"
#include <cmath>

TruePeakMeter::TruePeakMeter (int channelCount)
    : channels (juce::jmax (1, channelCount)),
      phases (Polyphase4x::designPhases()),
      history ((size_t) juce::jmax (1, channelCount)),
      writeIndex ((size_t) juce::jmax (1, channelCount), 0)
{
    reset();
}

void TruePeakMeter::reset()
{
    for (auto& channel : history)
        channel.fill (0.0);
    std::fill (writeIndex.begin(), writeIndex.end(), 0);
    maxAbs = 0.0;
}

void TruePeakMeter::process (const juce::AudioBuffer<float>& buffer)
{
    const int channelCount = juce::jmin (channels, buffer.getNumChannels());
    for (int channel = 0; channel < channelCount; ++channel)
    {
        int index = writeIndex[(size_t) channel];
        const auto* samples = buffer.getReadPointer (channel);
        for (int frame = 0; frame < buffer.getNumSamples(); ++frame)
        {
            const double x = samples[frame];
            maxAbs = juce::jmax (maxAbs, std::abs (x));
            history[(size_t) channel][(size_t) index] = x;

            for (const auto& phase : phases)
            {
                double value = 0.0;
                int read = index;
                for (const auto tap : phase)
                {
                    value += tap * history[(size_t) channel][(size_t) read];
                    read = read == 0 ? Polyphase4x::tapsPerPhase - 1 : read - 1;
                }
                maxAbs = juce::jmax (maxAbs, std::abs (value));
            }
            index = (index + 1) % Polyphase4x::tapsPerPhase;
        }
        writeIndex[(size_t) channel] = index;
    }
}

double TruePeakMeter::getMaxTruePeakDb() const
{
    return maxAbs > 0.0 ? 20.0 * std::log10 (maxAbs) : -std::numeric_limits<double>::infinity();
}
