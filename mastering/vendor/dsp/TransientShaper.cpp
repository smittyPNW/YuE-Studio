#include "TransientShaper.h"

void TransientShaper::prepare (double sampleRate)
{
    const float sr = (float) sampleRate;
    fa = 1.0f - std::exp (-1.0f / (0.003f * sr));
    fr = 1.0f - std::exp (-1.0f / (0.030f * sr));
    sa = 1.0f - std::exp (-1.0f / (0.020f * sr));
    sr_ = 1.0f - std::exp (-1.0f / (0.100f * sr));
    amount.reset (sampleRate, 0.040);
    amount.setCurrentAndTargetValue (amountTarget);
    snapNextAmount = true;
    reset();
}

void TransientShaper::reset() { fastEnv = slowEnv = 0; }

void TransientShaper::setAmount (float a)
{
    amountTarget = juce::jlimit (0.0f, 1.0f, a);
    if (snapNextAmount)
    {
        amount.setCurrentAndTargetValue (amountTarget);
        snapNextAmount = false;
    }
    else
        amount.setTargetValue (amountTarget);
}

void TransientShaper::process (juce::AudioBuffer<float>& buffer)
{
    if (amountTarget < 1.0e-4f && ! amount.isSmoothing()
        && amount.getCurrentValue() < 1.0e-4f)
        return;
    const int n = buffer.getNumSamples();
    const int ch = buffer.getNumChannels();

    for (int i = 0; i < n; ++i)
    {
        float mono = 0;
        for (int c = 0; c < ch; ++c)
            mono += buffer.getSample (c, i);
        mono = std::abs (mono / (float) juce::jmax (1, ch));

        fastEnv += (mono > fastEnv ? fa : fr) * (mono - fastEnv);
        slowEnv += (mono > slowEnv ? sa : sr_) * (mono - slowEnv);

        const float transient = juce::jmax (0.0f, fastEnv - slowEnv);
        const float a = amount.getNextValue();
        const float gain = juce::jlimit (0.5f, 2.0f, 1.0f + a * 2.0f * transient);

        for (int c = 0; c < ch; ++c)
            buffer.setSample (c, i, buffer.getSample (c, i) * gain);
    }
}
