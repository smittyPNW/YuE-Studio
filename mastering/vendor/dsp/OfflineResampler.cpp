#include "OfflineResampler.h"
#include <vector>

namespace
{
double sinc (double x) noexcept
{
    if (std::abs (x) < 1.0e-9)
        return 1.0;
    const double pix = juce::MathConstants<double>::pi * x;
    return std::sin (pix) / pix;
}

/** Blackman-Harris (4-term): ~-92 dB sidelobes, versus Blackman's ~-58 dB.
    The extra stopband depth is what makes a 48 -> 44.1 kHz delivery clean. */
double blackmanHarris (double position) noexcept
{
    constexpr double a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168;
    const double t = juce::MathConstants<double>::twoPi * position;
    return a0 - a1 * std::cos (t) + a2 * std::cos (2.0 * t) - a3 * std::cos (3.0 * t);
}

/** Phase-major coefficient table, each phase normalised to unity DC gain so a
    constant input converts to the same constant. */
const std::vector<float>& coefficientsFor (double cutoff)
{
    // Only two cutoffs occur in practice (unity for upsampling, the decimation
    // ratio for downsampling), and a converted export is a one-shot operation,
    // so a tiny cache keeps repeat exports instant without complicating the API.
    struct Entry { double cutoff; std::vector<float> table; };
    static std::vector<Entry> cache;
    static juce::CriticalSection lock;
    const juce::ScopedLock guard (lock);

    for (auto& entry : cache)
        if (std::abs (entry.cutoff - cutoff) < 1.0e-9)
            return entry.table;

    std::vector<float> table ((size_t) OfflineResampler::taps * OfflineResampler::phases);
    constexpr int centre = OfflineResampler::taps / 2 - 1;
    for (int phase = 0; phase < OfflineResampler::phases; ++phase)
    {
        const double fraction = (double) phase / (double) OfflineResampler::phases;
        double sum = 0.0;
        for (int tap = 0; tap < OfflineResampler::taps; ++tap)
        {
            const int offset = tap - centre;
            const double distance = fraction - (double) offset;
            const double window = blackmanHarris ((double) tap / (double) (OfflineResampler::taps - 1));
            const double coefficient = cutoff * sinc (cutoff * distance) * window;
            table[(size_t) phase * OfflineResampler::taps + (size_t) tap] = (float) coefficient;
            sum += coefficient;
        }
        if (std::abs (sum) > 1.0e-12)
            for (int tap = 0; tap < OfflineResampler::taps; ++tap)
                table[(size_t) phase * OfflineResampler::taps + (size_t) tap] /= (float) sum;
    }

    cache.push_back ({ cutoff, std::move (table) });
    return cache.back().table;
}
}

int OfflineResampler::outputLengthFor (int sourceSamples, double sourceRate, double destinationRate)
{
    if (sourceSamples <= 0 || sourceRate <= 0.0 || destinationRate <= 0.0)
        return 0;
    return (int) std::floor ((double) sourceSamples * destinationRate / sourceRate);
}

bool OfflineResampler::convert (const juce::AudioBuffer<float>& source,
                                double sourceRate,
                                double destinationRate,
                                juce::AudioBuffer<float>& destination)
{
    if (sourceRate <= 0.0 || destinationRate <= 0.0 || source.getNumChannels() <= 0)
        return false;

    if (std::abs (sourceRate - destinationRate) < 1.0e-6)
    {
        destination.makeCopyOf (source);   // exact: never touch a matching rate
        return true;
    }

    const int channels = source.getNumChannels();
    const int sourceSamples = source.getNumSamples();
    const int outputSamples = outputLengthFor (sourceSamples, sourceRate, destinationRate);
    if (outputSamples <= 0)
        return false;

    const double cutoff = sourceRate > destinationRate ? 0.94 * destinationRate / sourceRate : 1.0;
    const auto& table = coefficientsFor (cutoff);
    const double step = sourceRate / destinationRate;
    constexpr int centre = taps / 2 - 1;

    destination.setSize (channels, outputSamples, false, false, true);

    for (int channel = 0; channel < channels; ++channel)
    {
        const float* read = source.getReadPointer (channel);
        float* write = destination.getWritePointer (channel);

        for (int i = 0; i < outputSamples; ++i)
        {
            const double position = (double) i * step;
            const int base = (int) std::floor (position);
            const double fraction = position - (double) base;
            const int phase = juce::jlimit (0, phases - 1, (int) (fraction * (double) phases));
            const float* coefficients = table.data() + (size_t) phase * taps;

            double accumulator = 0.0;
            for (int tap = 0; tap < taps; ++tap)
            {
                // Edges clamp to the first/last sample rather than wrapping or
                // reading out of bounds; a master's head and tail are silent in
                // practice, so this is inaudible and always in-bounds.
                const int index = juce::jlimit (0, sourceSamples - 1, base - (tap - centre));
                accumulator += (double) coefficients[tap] * (double) read[index];
            }
            write[i] = (float) accumulator;
        }
    }
    return true;
}
