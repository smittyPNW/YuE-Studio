#pragma once
#include <JuceHeader.h>

class TransientShaper
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);

private:
    // Punch is a hero macro that runs in the live preview chain; the amount is
    // smoothed (40 ms, matching PhaseCoherentMultiband) so drags never step the
    // per-sample gain — an un-smoothed amount ticked at block boundaries.
    juce::SmoothedValue<float> amount;
    float amountTarget = 0;
    bool snapNextAmount = true;
    float fastEnv = 0, slowEnv = 0;
    float fa = 0, fr = 0, sa = 0, sr_ = 0;
};
