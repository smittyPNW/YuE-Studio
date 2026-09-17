#pragma once
#include <JuceHeader.h>
#include "audio/ParameterState.h"

class EqProcessor
{
public:
    void prepare (double sampleRate, int samplesPerBlock);
    void reset();
    void update (const ParameterState& state, bool lowCut, bool hiCut);
    void process (juce::AudioBuffer<float>& buffer);

    /** Magnitude response at frequency (for UI curve), dB. */
    float magnitudeDbAt (float hz) const;

    /**
        Computes the exact response implied by a parameter snapshot without
        touching the live filter banks.  The UI uses this on the message
        thread so its curve shares the DSP coefficient model without racing
        the audio thread.
    */
    static float magnitudeDbForState (const ParameterState& state,
                                      double sampleRate,
                                      float hz,
                                      bool lowCut,
                                      bool hiCut);

private:
    double sr = 44100.0;
    using Filter = juce::dsp::IIR::Filter<float>;
    using Coeffs = juce::dsp::IIR::Coefficients<float>;
    using ArrayCoeffs = juce::dsp::IIR::ArrayCoefficients<float>;
    using FilterBank = std::array<std::array<Filter, 2>, 8>;
    using ActiveBank = std::array<bool, 8>;
    using CoefficientBank = std::array<std::array<float, 6>, 8>;

    std::array<FilterBank, 2> filters; // old/new banks crossfade on preset changes
    std::array<ActiveBank, 2> active {};
    CoefficientBank requestedCoefficients {};
    ActiveBank requestedActive {};
    int currentBank = 0;
    int transitionSamplesRemaining = 0;
    int transitionLengthSamples = 1;
    bool hasRequestedState = false;

    std::array<float, 6> coefficientsForBand (const EqBand& band, bool& isActive) const;
    void installBand (int bank, int index, const std::array<float, 6>& coefficients,
                      bool isActive, bool resetFilter);
    float processBankSample (int bank, int channel, float input);
};
