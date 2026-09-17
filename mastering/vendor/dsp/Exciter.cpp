#include "Exciter.h"

void Exciter::prepare (double sampleRate, Band b)
{
    band = b;
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    for (auto* f : { &bpL, &bpR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::bandpass);
        f->setCutoffFrequency (band == Band::Warm ? 3500.0f : 11000.0f);
        f->setResonance (0.4f);
    }
    amount.reset (sampleRate, 0.040);
    amount.setCurrentAndTargetValue (amountTarget);
    reset();
}

void Exciter::reset()
{
    bpL.reset(); bpR.reset();
    oddL.reset(); oddR.reset(); evenL.reset(); evenR.reset();
    dcL = dcR = 0.0f;
    previousCorrectionL = previousCorrectionR = 0.0f;
}
void Exciter::setAmount (float a)
{
    amountTarget = juce::jlimit (0.0f, 1.0f, a);
    amount.setTargetValue (amountTarget);
}

void Exciter::process (juce::AudioBuffer<float>& buffer)
{
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    for (int i = 0; i < n; ++i)
    {
        const float currentAmount = amount.getNextValue();
        const float drive = 1.5f + currentAmount * 3.0f;
        const float mix = currentAmount * (band == Band::Warm ? 0.22f : 0.14f);
        for (int c = 0; c < ch; ++c)
        {
            auto& bp = (c == 0 ? bpL : bpR);
            auto& odd = (c == 0 ? oddL : oddR);
            auto& even = (c == 0 ? evenL : evenR);
            auto& dc = (c == 0 ? dcL : dcR);
            auto& previous = (c == 0 ? previousCorrectionL : previousCorrectionR);
            auto* d = buffer.getWritePointer (c);
            const float x = d[i];
            const float bandSignal = bp.processSample (0, x);
            const float correction = odd.processDelta (bandSignal, drive)
                                   + 0.15f * even.processDelta (bandSignal, drive, 0.20f);
            const float dcBlocked = correction - previous + 0.995f * dc;
            previous = correction;
            dc = dcBlocked;
            d[i] = x + dcBlocked * mix;
        }
    }
}
