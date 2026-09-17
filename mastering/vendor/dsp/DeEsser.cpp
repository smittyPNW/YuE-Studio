#include "DeEsser.h"

void DeEsser::prepare (double sampleRate)
{
    sr = sampleRate;
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    for (auto* f : { &bpL, &bpR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::bandpass);
        f->setCutoffFrequency (7000.0f);
        f->setResonance (0.5f);
    }
    atk = 1.0f - std::exp (-1.0f / (0.003f * (float) sr));
    rel = 1.0f - std::exp (-1.0f / (0.050f * (float) sr));
    reset();
}

void DeEsser::reset()
{
    env = broadEnv = 0;
    detectorGain = 1.0f;
    detectorGainStep = 0.0f;
    detectorCountdown = 0;
    highPassState[0] = highPassState[1] = 0.0f;
    bpL.reset();
    bpR.reset();
}
void DeEsser::setAmount (float a) { amount = juce::jlimit (0.0f, 1.0f, a); }

void DeEsser::process (juce::AudioBuffer<float>& buffer)
{
    if (amount < 1.0e-4f) return;
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    for (int i = 0; i < n; ++i)
    {
        float sib = 0, broad = 0;
        for (int c = 0; c < ch; ++c)
        {
            float x = buffer.getSample (c, i);
            broad += std::abs (x);
            auto& bp = (c == 0 ? bpL : bpR);
            sib += std::abs (bp.processSample (0, x));
        }
        broad /= (float) ch;
        sib /= (float) ch;

        broadEnv += (broad > broadEnv ? atk : rel) * (broad - broadEnv);
        env += (sib > env ? atk : rel) * (sib - env);

        // The detector envelopes remain sample accurate, but logarithms and
        // exponentials do not need to run at audio rate. A 6 kHz control rate
        // at 48 kHz is far above any de-essing envelope bandwidth; interpolate
        // each update to preserve smooth gain while sharply reducing mobile
        // callback cost.
        constexpr int controlInterval = 8;
        if (detectorCountdown <= 0)
        {
            const float broadDb = juce::Decibels::gainToDecibels (broadEnv + 1.0e-7f);
            const float sibDb = juce::Decibels::gainToDecibels (env + 1.0e-7f);
            const float threshold = broadDb + 12.0f - amount * 10.0f;
            const float redDb = juce::jlimit (0.0f, 2.0f + amount * 8.0f,
                                               (sibDb - threshold) * 0.6f);
            const float targetGain = juce::Decibels::decibelsToGain (-redDb);
            detectorGainStep = (targetGain - detectorGain) / (float) controlInterval;
            detectorCountdown = controlInterval;
        }
        detectorGain += detectorGainStep;
        --detectorCountdown;

        // Apply as high-shelf-ish attenuation on full signal mixed with high band
        for (int c = 0; c < ch; ++c)
        {
            float x = buffer.getSample (c, i);
            // Apply the reduction only to a simple high-frequency residual.
            float hp = x - highPassState[c];
            highPassState[c] += 0.15f * hp; // crude high extract
            float low = x - hp;
            buffer.setSample (c, i, low + hp * detectorGain);
        }
    }
}
