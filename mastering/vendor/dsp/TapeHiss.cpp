#include "TapeHiss.h"

void TapeHiss::prepare (double sampleRate)
{
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    hp.prepare (spec); lp.prepare (spec);
    hp.setType (juce::dsp::StateVariableTPTFilterType::highpass);
    lp.setType (juce::dsp::StateVariableTPTFilterType::lowpass);
    hp.setCutoffFrequency (4000.0f);
    lp.setCutoffFrequency (14000.0f);
    atk = 1.0f - std::exp (-1.0f / (0.05f * (float) sampleRate));
    rel = 1.0f - std::exp (-1.0f / (0.20f * (float) sampleRate));
    reset();
}

void TapeHiss::reset()
{
    env = 0;
    hp.reset();
    lp.reset();
    b0 = b1 = b2 = 0;
    rng.setSeed (0x5245534f554cLL);
}
void TapeHiss::setAmount (float a) { amount = juce::jlimit (0.0f, 1.0f, a); }

void TapeHiss::process (juce::AudioBuffer<float>& buffer)
{
    if (amount < 1.0e-4f) return;
    const float hissGainDb = -72.0f + amount * 24.0f;
    const float baseGain = juce::Decibels::decibelsToGain (hissGainDb);
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    for (int i = 0; i < n; ++i)
    {
        float mono = 0;
        for (int c = 0; c < ch; ++c)
            mono += std::abs (buffer.getSample (c, i));
        mono /= (float) juce::jmax (1, ch);
        env += (mono > env ? atk : rel) * (mono - env);

        float white = rng.nextFloat() * 2.0f - 1.0f;
        // Paul Kellet pink-ish
        b0 = 0.99765f * b0 + white * 0.0990460f;
        b1 = 0.96300f * b1 + white * 0.2965164f;
        b2 = 0.57000f * b2 + white * 1.0526913f;
        float pink = b0 + b1 + b2 + white * 0.1848f;
        float nse = lp.processSample (0, hp.processSample (0, pink * 0.05f));
        float g = baseGain * (0.7f + 0.3f * juce::jlimit (0.0f, 1.0f, env * 4.0f));

        for (int c = 0; c < ch; ++c)
            buffer.addSample (c, i, nse * g * (c == 0 ? 1.0f : 0.97f));
    }
}
