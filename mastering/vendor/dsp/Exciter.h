#pragma once
#include <JuceHeader.h>
#include "AntialiasedWaveshaper.h"

class Exciter
{
public:
    enum class Band { Warm, Air };
    void prepare (double sampleRate, Band band);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);

private:
    Band band = Band::Warm;
    float amountTarget = 0;
    juce::SmoothedValue<float> amount;
    juce::dsp::StateVariableTPTFilter<float> bpL, bpR;
    AntialiasedTanh oddL, oddR, evenL, evenR;
    float dcL = 0, dcR = 0;
    float previousCorrectionL = 0, previousCorrectionR = 0;
};
