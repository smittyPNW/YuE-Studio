#include "EqProcessor.h"

namespace
{
std::array<float, 6> coefficientsForBandAt (const EqBand& band,
                                             double sampleRate,
                                             bool& isActive)
{
    using ArrayCoeffs = juce::dsp::IIR::ArrayCoefficients<float>;
    std::array<float, 6> raw { 1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f };
    if (! band.enabled || (std::abs (band.gainDb) < 0.01f && band.type != 3 && band.type != 4))
    {
        isActive = false;
        return raw;
    }

    isActive = true;
    const float frequency = juce::jlimit (20.0f, 20000.0f, band.frequencyHz);
    const float q = juce::jlimit (0.1f, 10.0f, band.q);
    switch (band.type)
    {
        case 1: return ArrayCoeffs::makeLowShelf (sampleRate, frequency, q,
                                                   juce::Decibels::decibelsToGain (band.gainDb));
        case 2: return ArrayCoeffs::makeHighShelf (sampleRate, frequency, q,
                                                    juce::Decibels::decibelsToGain (band.gainDb));
        case 3: return ArrayCoeffs::makeHighPass (sampleRate, frequency, q);
        case 4: return ArrayCoeffs::makeLowPass (sampleRate, frequency, q);
        default: return ArrayCoeffs::makePeakFilter (sampleRate, frequency, q,
                                                      juce::Decibels::decibelsToGain (band.gainDb));
    }
}
}

void EqProcessor::prepare (double sampleRate, int)
{
    sr = sampleRate;
    juce::dsp::ProcessSpec spec { sampleRate, 512, 2 };
    for (auto& bank : filters)
        for (auto& pair : bank)
            for (auto& f : pair)
                f.prepare (spec);
    transitionLengthSamples = juce::jmax (1, (int) std::round (sampleRate * 0.015));
    currentBank = 0;
    transitionSamplesRemaining = 0;
    hasRequestedState = false;
    reset();
}

void EqProcessor::reset()
{
    for (auto& bank : filters)
        for (auto& pair : bank)
            for (auto& f : pair)
                f.reset();
}

std::array<float, 6> EqProcessor::coefficientsForBand (const EqBand& band,
                                                       bool& isActive) const
{
    return coefficientsForBandAt (band, sr, isActive);
}

void EqProcessor::installBand (int bank, int index,
                               const std::array<float, 6>& coefficients,
                               bool isActive, bool resetFilter)
{
    active[(size_t) bank][(size_t) index] = isActive;
    // ArrayCoefficients are stack values. Filter coefficient storage is allocated
    // during construction/prepare, so this assignment performs no heap allocation.
    for (auto& filter : filters[(size_t) bank][(size_t) index])
    {
        *filter.coefficients = coefficients;
        if (resetFilter)
            filter.reset();
    }
}

void EqProcessor::update (const ParameterState& state, bool lowCut, bool hiCut)
{
    CoefficientBank nextCoefficients {};
    ActiveBank nextActive {};
    for (int i = 0; i < 6; ++i)
        nextCoefficients[(size_t) i] = coefficientsForBand (state.eq[(size_t) i],
                                                            nextActive[(size_t) i]);

    EqBand lc { lowCut, 35.0f, 0.0f, 0.707f, 3 };
    nextCoefficients[6] = coefficientsForBand (lc, nextActive[6]);
    EqBand hc { hiCut, 16000.0f, 0.0f, 0.707f, 4 };
    nextCoefficients[7] = coefficientsForBand (hc, nextActive[7]);

    if (hasRequestedState && nextActive == requestedActive
        && nextCoefficients == requestedCoefficients)
        return;

    requestedActive = nextActive;
    requestedCoefficients = nextCoefficients;

    if (! hasRequestedState)
    {
        for (int band = 0; band < 8; ++band)
            installBand (currentBank, band, requestedCoefficients[(size_t) band],
                         requestedActive[(size_t) band], true);
        hasRequestedState = true;
        return;
    }

    const int nextBank = 1 - currentBank;
    for (int band = 0; band < 8; ++band)
        installBand (nextBank, band, requestedCoefficients[(size_t) band],
                     requestedActive[(size_t) band], true);
    transitionSamplesRemaining = transitionLengthSamples;
}

float EqProcessor::processBankSample (int bank, int channel, float input)
{
    float output = input;
    for (int band = 0; band < 8; ++band)
        if (active[(size_t) bank][(size_t) band])
            output = filters[(size_t) bank][(size_t) band][(size_t) channel].processSample (output);
    return output;
}

void EqProcessor::process (juce::AudioBuffer<float>& buffer)
{
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());
    for (int c = 0; c < ch; ++c)
    {
        auto* d = buffer.getWritePointer (c);
        for (int i = 0; i < n; ++i)
        {
            const float input = d[i];
            const float current = processBankSample (currentBank, c, input);
            if (transitionSamplesRemaining > 0)
            {
                const int nextBank = 1 - currentBank;
                const float next = processBankSample (nextBank, c, input);
                const float progress = juce::jlimit (
                    0.0f, 1.0f,
                    1.0f - (float) juce::jmax (0, transitionSamplesRemaining - i)
                                 / (float) transitionLengthSamples);
                d[i] = current + progress * (next - current);
            }
            else
                d[i] = current;
        }
    }

    if (transitionSamplesRemaining > 0)
    {
        transitionSamplesRemaining = juce::jmax (0, transitionSamplesRemaining - n);
        if (transitionSamplesRemaining == 0)
            currentBank = 1 - currentBank;
    }
}

float EqProcessor::magnitudeDbAt (float hz) const
{
    float mag = 1.0f;
    const int displayBank = transitionSamplesRemaining > 0 ? 1 - currentBank : currentBank;
    for (int b = 0; b < 8; ++b)
        if (active[(size_t) displayBank][(size_t) b]
            && filters[(size_t) displayBank][(size_t) b][0].coefficients != nullptr)
            mag *= (float) filters[(size_t) displayBank][(size_t) b][0].coefficients
                       ->getMagnitudeForFrequency ((double) hz, sr);
    return juce::Decibels::gainToDecibels (mag + 1.0e-9f);
}

float EqProcessor::magnitudeDbForState (const ParameterState& state,
                                        double sampleRate,
                                        float hz,
                                        bool lowCut,
                                        bool hiCut)
{
    const double safeSampleRate = juce::jmax (8000.0, sampleRate);
    double magnitude = 1.0;
    const auto accumulate = [&] (const EqBand& band)
    {
        bool active = false;
        const auto raw = coefficientsForBandAt (band, safeSampleRate, active);
        if (active)
        {
            const juce::dsp::IIR::Coefficients<float> coefficients (raw);
            magnitude *= coefficients.getMagnitudeForFrequency (
                juce::jlimit (1.0, safeSampleRate * 0.499, (double) hz), safeSampleRate);
        }
    };

    for (const auto& band : state.eq)
        accumulate (band);
    accumulate ({ lowCut, 35.0f, 0.0f, 0.707f, 3 });
    accumulate ({ hiCut, 16000.0f, 0.0f, 0.707f, 4 });
    return juce::Decibels::gainToDecibels ((float) magnitude + 1.0e-9f);
}
