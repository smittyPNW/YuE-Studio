#pragma once
#include <JuceHeader.h>

class DeEsser
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);

private:
    double sr = 44100.0;
    float amount = 0;
    float env = 0, broadEnv = 0;
    float atk = 0, rel = 0;
    float detectorGain = 1.0f, detectorGainStep = 0.0f;
    int detectorCountdown = 0;
    float highPassState[2] { 0.0f, 0.0f };
    juce::dsp::StateVariableTPTFilter<float> bpL, bpR;
    juce::dsp::StateVariableTPTFilter<float> hsL, hsR;
};
