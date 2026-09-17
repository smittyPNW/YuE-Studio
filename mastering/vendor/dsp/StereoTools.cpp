#include "StereoTools.h"

void StereoTools::prepare (double sampleRate)
{
    sr = sampleRate;
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    lowSideLp.prepare (spec);
    highSideHp.prepare (spec);
    lowSideLp.setType (juce::dsp::StateVariableTPTFilterType::lowpass);
    highSideHp.setType (juce::dsp::StateVariableTPTFilterType::highpass);
    lowSideLp.setCutoffFrequency (120.0f);
    highSideHp.setCutoffFrequency (10000.0f);
    for (auto* value : { &monoLowAmt, &monoHighAmt, &width })
        value->reset (sampleRate, 0.040);
    monoLowAmt.setCurrentAndTargetValue (monoLowTarget);
    monoHighAmt.setCurrentAndTargetValue (monoHighTarget);
    width.setCurrentAndTargetValue (widthTarget);
    reset();
}

void StereoTools::reset()
{
    lowSideLp.reset();
    highSideHp.reset();
}

void StereoTools::setMonoLow (float amount01, float crossoverHz)
{
    monoLowTarget = juce::jlimit (0.0f, 1.0f, amount01);
    monoLowAmt.setTargetValue (monoLowTarget);
    lowSideLp.setCutoffFrequency (juce::jlimit (40.0f, 250.0f, crossoverHz));
}

void StereoTools::setMonoHigh (float amount01, float crossoverHz)
{
    monoHighTarget = juce::jlimit (0.0f, 1.0f, amount01);
    monoHighAmt.setTargetValue (monoHighTarget);
    highSideHp.setCutoffFrequency (juce::jlimit (6000.0f, 16000.0f, crossoverHz));
}

void StereoTools::setWidth (float widthScale)
{
    widthTarget = juce::jlimit (0.5f, 1.5f, widthScale);
    width.setTargetValue (widthTarget);
}

void StereoTools::process (juce::AudioBuffer<float>& buffer)
{
    if (buffer.getNumChannels() < 2) return;
    if (! monoLowAmt.isSmoothing() && ! monoHighAmt.isSmoothing() && ! width.isSmoothing()
        && monoLowAmt.getCurrentValue() <= 1.0e-4f
        && monoHighAmt.getCurrentValue() <= 1.0e-4f
        && std::abs (width.getCurrentValue() - 1.0f) <= 1.0e-6f)
        return;
    auto* L = buffer.getWritePointer (0);
    auto* R = buffer.getWritePointer (1);
    const int n = buffer.getNumSamples();

    for (int i = 0; i < n; ++i)
    {
        const float lowAmount = monoLowAmt.getNextValue();
        const float highAmount = monoHighAmt.getNextValue();
        const float widthScale = width.getNextValue();
        float mid = 0.5f * (L[i] + R[i]);
        float side = 0.5f * (L[i] - R[i]);

        if (lowAmount > 1.0e-4f)
        {
            float sideLow = lowSideLp.processSample (0, side);
            float sideHigh = side - sideLow;
            side = sideHigh + sideLow * (1.0f - lowAmount);
        }

        if (highAmount > 1.0e-4f)
        {
            float sideHigh = highSideHp.processSample (0, side);
            float sideLow = side - sideHigh;
            side = sideLow + sideHigh * (1.0f - highAmount);
        }

        side *= widthScale;

        L[i] = mid + side;
        R[i] = mid - side;
    }
}
