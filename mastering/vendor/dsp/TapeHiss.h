#pragma once
#include <JuceHeader.h>

class TapeHiss
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);

private:
    float amount = 0;
    float env = 0, atk = 0, rel = 0;
    juce::Random rng;
    juce::dsp::StateVariableTPTFilter<float> hp, lp;
    float b0 = 0, b1 = 0, b2 = 0; // pink-ish
};
