#include "Saturation.h"

void WarmthSaturator::prepare (double sampleRate)
{
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    for (auto* f : { &preL, &preR, &postL, &postR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::lowpass);
        f->setCutoffFrequency (900.0f);
    }
    amount.reset (sampleRate, 0.040);
    amount.setCurrentAndTargetValue (amountTarget);
    reset();
}
void WarmthSaturator::reset()
{
    preL.reset(); preR.reset(); postL.reset(); postR.reset();
    shapeL.reset(); shapeR.reset();
}
void WarmthSaturator::setAmount (float a)
{
    amountTarget = juce::jlimit (0.0f, 1.0f, a);
    amount.setTargetValue (amountTarget);
}

void WarmthSaturator::process (juce::AudioBuffer<float>& buffer)
{
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    for (int i = 0; i < n; ++i)
    {
        const float currentAmount = amount.getNextValue();
        const float drive = 1.0f + currentAmount * 3.0f;
        const float wet = currentAmount * 0.40f;
        for (int c = 0; c < ch; ++c)
        {
            auto& pre = (c == 0 ? preL : preR);
            auto& shaper = (c == 0 ? shapeL : shapeR);
            auto* d = buffer.getWritePointer (c);
            const float x = d[i];
            const float preEmphasized = x + 0.35f * pre.processSample (0, x);
            const float harmonicCorrection = shaper.processDelta (preEmphasized, drive);
            d[i] = x + harmonicCorrection * wet;
        }
    }
}

void AnalogLifeSaturator::prepare (double sampleRate)
{
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    for (auto* f : { &preL, &preR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::highpass);
        f->setCutoffFrequency (1500.0f);
    }
    amount.reset (sampleRate, 0.040);
    amount.setCurrentAndTargetValue (amountTarget);
    reset();
}
void AnalogLifeSaturator::reset()
{
    preL.reset(); preR.reset();
    shapeL.reset(); shapeR.reset();
    dcL = dcR = 0.0f;
    previousCorrectionL = previousCorrectionR = 0.0f;
}
void AnalogLifeSaturator::setAmount (float a)
{
    amountTarget = juce::jlimit (0.0f, 1.0f, a);
    amount.setTargetValue (amountTarget);
}

void AnalogLifeSaturator::process (juce::AudioBuffer<float>& buffer)
{
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    for (int i = 0; i < n; ++i)
    {
        const float currentAmount = amount.getNextValue();
        const float drive = 1.0f + currentAmount * 2.5f;
        const float wet = currentAmount * 0.30f;
        for (int c = 0; c < ch; ++c)
        {
            auto& pre = (c == 0 ? preL : preR);
            auto& shaper = (c == 0 ? shapeL : shapeR);
            auto& dc = (c == 0 ? dcL : dcR);
            auto& previous = (c == 0 ? previousCorrectionL : previousCorrectionR);
            auto* d = buffer.getWritePointer (c);
            const float x = d[i];
            const float high = pre.processSample (0, x);
            const float correction = shaper.processDelta (high, drive, 0.16f);
            const float dcBlocked = correction - previous + 0.995f * dc;
            previous = correction;
            dc = dcBlocked;
            d[i] = x + dcBlocked * wet;
        }
    }
}
