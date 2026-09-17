#pragma once
#include <JuceHeader.h>

class StereoTools
{
public:
    void prepare (double sampleRate);
    void reset();
    void setMonoLow (float amount01, float crossoverHz = 120.0f);
    void setMonoHigh (float amount01, float crossoverHz = 10000.0f);
    void setWidth (float widthScale); // 0.75–1.35
    void process (juce::AudioBuffer<float>& buffer);

private:
    double sr = 44100.0;
    float monoLowTarget = 0, monoHighTarget = 0, widthTarget = 1.0f;
    juce::SmoothedValue<float> monoLowAmt, monoHighAmt, width;
    juce::dsp::StateVariableTPTFilter<float> lowSideLp, highSideHp;
};
