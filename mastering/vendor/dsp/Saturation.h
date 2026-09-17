#pragma once
#include <JuceHeader.h>
#include "AntialiasedWaveshaper.h"

class WarmthSaturator
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);
private:
    float amountTarget = 0;
    juce::SmoothedValue<float> amount;
    juce::dsp::StateVariableTPTFilter<float> preL, preR, postL, postR;
    AntialiasedTanh shapeL, shapeR;
};

class AnalogLifeSaturator
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);
private:
    float amountTarget = 0;
    juce::SmoothedValue<float> amount;
    juce::dsp::StateVariableTPTFilter<float> preL, preR;
    AntialiasedTanh shapeL, shapeR;
    float dcL = 0, dcR = 0;
    float previousCorrectionL = 0, previousCorrectionR = 0;
};
