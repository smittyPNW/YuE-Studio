#include "MasteringProcessor.h"

void MasteringProcessor::prepare (double sampleRate, int samplesPerBlock)
{
    sr = sampleRate;
    eq.prepare (sampleRate, samplesPerBlock);
    stereo.prepare (sampleRate);
    punch.prepare (sampleRate);
    if (! realtimePreviewMode)
        multiband.prepare (sampleRate, samplesPerBlock);
    deChirp.prepare (sampleRate);
    deEsser.prepare (sampleRate);
    warmth.prepare (sampleRate);
    analogLife.prepare (sampleRate);
    warmExc.prepare (sampleRate, Exciter::Band::Warm);
    airExc.prepare (sampleRate, Exciter::Band::Air);
    hiss.prepare (sampleRate);
    clipper.prepare (sampleRate);
    if (! realtimePreviewMode)
        truePeakLimiter.prepare (sampleRate, 2, samplesPerBlock);
    previewLimiterRelease = (float) std::exp (-1.0 / (0.075 * sampleRate));
    previewDriveGain.reset (sampleRate, 0.035);
    previewDriveGain.setCurrentAndTargetValue (1.0f);
    previewColourAmount.reset (sampleRate, 0.035);
    previewColourAmount.setCurrentAndTargetValue (0.0f);
    normalizeGain.reset (sampleRate, 0.050);
    normalizeGain.setCurrentAndTargetValue (1.0f);
    parametersInitialized = false;

    juce::dsp::ProcessSpec spec { sampleRate, (juce::uint32) samplesPerBlock, 2 };
    for (int bank = 0; bank < 2; ++bank)
        for (int stage = 0; stage < 4; ++stage)
            for (int channel = 0; channel < 2; ++channel)
                tone[bank][stage][channel].prepare (spec);
    toneTransitionLength = juce::jmax (1, (int) std::round (sampleRate * 0.015));
    toneInitialized = false;
    toneLastRequested = { -1.0f, -1.0f, -1.0f, -1.0f };
    tonePendingValid = false;

    previewTpPhases = Polyphase4x::designPhases();
    reset();
}

void MasteringProcessor::reset()
{
    eq.reset(); stereo.reset(); punch.reset(); deChirp.reset(); deEsser.reset();
    if (! realtimePreviewMode)
        multiband.reset();
    warmth.reset(); analogLife.reset(); warmExc.reset(); airExc.reset(); hiss.reset(); clipper.reset();
    if (! realtimePreviewMode)
        truePeakLimiter.reset();
    previewLimiterEnvelope = 1.0f;
    previewDc = {};
    previewPreviousOutput = {};
    previewCharacterFadeRemaining = 0;
    previewTpHistory = {};
    previewTpWriteIndex = 0;
    // Complete any in-flight tone crossfade so a transport restart begins on
    // the freshest coefficients with clean filter state; a queued retarget is
    // snapped in directly (no audio continuity to protect during reset).
    if (toneTransitionRemaining > 0)
    {
        toneCurrentBank = 1 - toneCurrentBank;
        toneTransitionRemaining = 0;
    }
    if (tonePendingValid)
    {
        tonePendingValid = false;
        if (toneInitialized)
            installToneBank (toneCurrentBank, tonePending);
    }
    for (int bank = 0; bank < 2; ++bank)
        for (int stage = 0; stage < 4; ++stage)
            for (int channel = 0; channel < 2; ++channel)
                tone[bank][stage][channel].reset();
    peakL = peakR = 0;
}

void MasteringProcessor::setParameters (const ParameterState& state)
{
    const bool wasInitialized = parametersInitialized;
    const auto previousCharacter = params.finalCharacter;
    params = state;
    eq.update (state, state.lowCut, state.hiCut);
    stereo.setMonoLow (state.monoLow, 120.0f);
    stereo.setMonoHigh (state.monoHigh, 10000.0f);
    stereo.setWidth (ParameterState::mapWidth (state.width));
    punch.setAmount (state.punch);
    // Drum Punch remains the musician-facing macro. Beneath it, restrained
    // phase-coherent multiband glue controls crest factor without an extra
    // wall of compressor parameters. Mud/de-esser contribute smaller safety
    // amounts for dense AI-generated mixes.
    multiband.setAmount (juce::jlimit (0.0f, 1.0f,
                                      state.punch * 0.80f
                                    + state.mud * 0.20f
                                    + state.deEsser * 0.12f));
    deChirp.setAmount (state.deChirp);
    deEsser.setAmount (state.deEsser);
    warmth.setAmount (state.warmth);
    analogLife.setAmount (state.analogLife);
    warmExc.setAmount (state.warmExciter);
    airExc.setAmount (state.airExciter);
    hiss.setAmount (state.tapeHiss);
    clipper.setMode (state.finalCharacter);
    clipper.setDriveDb (state.masterVolDb);
    truePeakLimiter.setCeilingDbTP (state.ceilingDb);
    truePeakLimiter.setEnabled (state.useTruePeak);
    if (realtimePreviewMode)
    {
        const float nextDrive = juce::Decibels::decibelsToGain (
            juce::jlimit (-12.0f, 18.0f, state.masterVolDb));
        if (! wasInitialized)
            previewDriveGain.setCurrentAndTargetValue (nextDrive);
        else
            previewDriveGain.setTargetValue (nextDrive);

        const float nextColour = juce::jlimit (
            0.0f, 0.48f,
            state.warmth * 0.34f + state.analogLife * 0.24f
                + state.warmExciter * 0.18f + state.airExciter * 0.16f
                + state.tapeHiss * 0.08f);
        if (! wasInitialized)
            previewColourAmount.setCurrentAndTargetValue (nextColour);
        else
            previewColourAmount.setTargetValue (nextColour);
        if (! wasInitialized)
        {
            previewCharacter = previewPreviousCharacter = state.finalCharacter;
            previewCharacterFadeRemaining = 0;
        }
        else if (state.finalCharacter != previousCharacter)
        {
            previewPreviousCharacter = previewCharacter;
            previewCharacter = state.finalCharacter;
            previewCharacterFadeRemaining = juce::jmax (1, (int) std::round (sr * 0.020));
        }
    }
    const float nextNormalizeGain = state.normalizeActive
        ? juce::Decibels::decibelsToGain (state.normalizeGainDb) : 1.0f;
    if (! parametersInitialized)
        normalizeGain.setCurrentAndTargetValue (nextNormalizeGain);
    else
        normalizeGain.setTargetValue (nextNormalizeGain);
    parametersInitialized = true;
    updateToneCoeffs();
}

void MasteringProcessor::installToneBank (int bank, const std::array<float, 4>& toneParams)
{
    using A = juce::dsp::IIR::ArrayCoefficients<float>;
    const float bass = toneParams[0], mid = toneParams[1];
    const float treble = toneParams[2], mud = toneParams[3];
    const float bassDb = ParameterState::mapToneShelfDb (bass);
    const float midDb = ParameterState::mapToneShelfDb (mid);
    const float trebleDb = ParameterState::mapToneShelfDb (treble);
    const float mudDb = -mud * 6.0f;

    const std::array<std::array<float, 6>, 4> stageCoeffs {
        A::makeLowShelf (sr, 100.0f, 0.7f, juce::Decibels::decibelsToGain (bassDb)),
        A::makePeakFilter (sr, 220.0f, 1.0f, juce::Decibels::decibelsToGain (mudDb)),
        A::makePeakFilter (sr, 1200.0f, 0.8f, juce::Decibels::decibelsToGain (midDb)),
        A::makeHighShelf (sr, 6000.0f, 0.7f, juce::Decibels::decibelsToGain (trebleDb)),
    };
    for (int stage = 0; stage < 4; ++stage)
        for (int channel = 0; channel < 2; ++channel)
        {
            *tone[bank][stage][channel].coefficients = stageCoeffs[(size_t) stage];
            tone[bank][stage][channel].reset();
        }
    toneNeutral[bank] = std::abs (bass - 0.5f) <= 1.0e-6f
                     && std::abs (mid - 0.5f) <= 1.0e-6f
                     && std::abs (treble - 0.5f) <= 1.0e-6f
                     && mud <= 1.0e-6f;
}

void MasteringProcessor::beginToneTransition (const std::array<float, 4>& toneParams)
{
    // Install into the inactive bank and crossfade over — never touch the
    // coefficients a live sample path is currently flowing through.
    installToneBank (1 - toneCurrentBank, toneParams);
    toneTransitionRemaining = toneTransitionLength;
}

void MasteringProcessor::updateToneCoeffs()
{
    const std::array<float, 4> now { params.bass, params.mid, params.treble, params.mud };
    if (toneInitialized && now == toneLastRequested)
        return;
    toneLastRequested = now;

    if (! toneInitialized)
    {
        installToneBank (0, now);
        installToneBank (1, now);
        toneCurrentBank = 0;
        toneTransitionRemaining = 0;
        tonePendingValid = false;
        toneInitialized = true;
        return;
    }

    if (toneTransitionRemaining > 0)
    {
        // Mid-fade retarget: queue it (latest wins). Restarting the fade here
        // would reset the incoming bank's filter state while it already
        // carries audible weight — that was measurably a click.
        tonePending = now;
        tonePendingValid = true;
        return;
    }

    beginToneTransition (now);
}

float MasteringProcessor::processToneBankSample (int bank, int channel, float input)
{
    float value = input;
    for (int stage = 0; stage < 4; ++stage)
        value = tone[bank][stage][channel].processSample (value);
    return value;
}

void MasteringProcessor::applyFades (juce::AudioBuffer<float>& buffer, int64_t absPos, int64_t totalSamples)
{
    if (totalSamples <= 0) return;
    const int n = buffer.getNumSamples();
    const int ch = buffer.getNumChannels();
    const int64_t fadeInSamples = (int64_t) (params.fadeInSec * sr);
    const int64_t fadeOutSamples = (int64_t) (params.fadeOutSec * sr);

    for (int i = 0; i < n; ++i)
    {
        int64_t pos = absPos + i;
        float g = 1.0f;
        if (fadeInSamples > 0 && pos < fadeInSamples)
            g *= (float) pos / (float) fadeInSamples;
        if (fadeOutSamples > 0 && pos > totalSamples - fadeOutSamples)
        {
            int64_t into = totalSamples - pos;
            g *= juce::jlimit (0.0f, 1.0f, (float) into / (float) fadeOutSamples);
        }
        if (g < 1.0f)
            for (int c = 0; c < ch; ++c)
                buffer.getWritePointer (c)[i] *= g;
    }
}

void MasteringProcessor::applyTone (juce::AudioBuffer<float>& buffer)
{
    // Neutral settings with no crossfade in flight contribute exactly nothing.
    if (toneNeutral[toneCurrentBank] && toneTransitionRemaining == 0)
        return;
    const int n = buffer.getNumSamples();
    const int channels = juce::jmin (2, buffer.getNumChannels());
    if (channels < 1) return;

    const int nextBank = 1 - toneCurrentBank;
    for (int c = 0; c < channels; ++c)
    {
        auto* d = buffer.getWritePointer (c);
        for (int i = 0; i < n; ++i)
        {
            const float input = d[i];
            const float current = toneNeutral[toneCurrentBank]
                ? input : processToneBankSample (toneCurrentBank, c, input);
            if (toneTransitionRemaining > 0)
            {
                const float next = toneNeutral[nextBank]
                    ? input : processToneBankSample (nextBank, c, input);
                const float progress = juce::jlimit (
                    0.0f, 1.0f,
                    1.0f - (float) juce::jmax (0, toneTransitionRemaining - i)
                                 / (float) toneTransitionLength);
                d[i] = current + progress * (next - current);
            }
            else
                d[i] = current;
        }
    }

    if (toneTransitionRemaining > 0)
    {
        toneTransitionRemaining = juce::jmax (0, toneTransitionRemaining - n);
        if (toneTransitionRemaining == 0)
        {
            toneCurrentBank = nextBank;
            if (tonePendingValid)
            {
                tonePendingValid = false;
                beginToneTransition (tonePending);
            }
        }
    }
}

void MasteringProcessor::applyPreviewLimiter (juce::AudioBuffer<float>& buffer)
{
    if (! params.useTruePeak || buffer.getNumChannels() == 0)
        return;

    // The final export uses the full 4x oversampled lookahead limiter. Live
    // audition uses a stereo-linked, zero-latency clamp — but DETECTION runs
    // at 4x reconstruction through the same shared Polyphase4x kernel as the
    // export limiter and the meters, so audition catches the intersample
    // overs the export would catch instead of letting them pass silently.
    // 0.15 dB detection margin absorbs the reconstruction filter's passband
    // ripple and the release envelope's approach, so the AUDITIONED true peak
    // lands at or below the user's ceiling — not a tenth of a dB above it.
    const float ceiling = juce::Decibels::decibelsToGain (params.ceilingDb - 0.15f);
    const int channels = juce::jmin (2, buffer.getNumChannels());
    constexpr int taps = Polyphase4x::tapsPerPhase;
    for (int sample = 0; sample < buffer.getNumSamples(); ++sample)
    {
        float peak = 0.0f;
        for (int channel = 0; channel < channels; ++channel)
        {
            const float x = buffer.getSample (channel, sample);
            previewTpHistory[(size_t) channel][(size_t) previewTpWriteIndex] = x;
            peak = juce::jmax (peak, std::abs (x));

            for (const auto& phase : previewTpPhases)
            {
                double reconstructed = 0.0;
                int readIndex = previewTpWriteIndex;
                for (int tap = 0; tap < taps; ++tap)
                {
                    reconstructed += phase[(size_t) tap]
                                   * previewTpHistory[(size_t) channel][(size_t) readIndex];
                    readIndex = readIndex == 0 ? taps - 1 : readIndex - 1;
                }
                peak = juce::jmax (peak, (float) std::abs (reconstructed));
            }
        }
        previewTpWriteIndex = (previewTpWriteIndex + 1) % taps;

        const float desired = peak > ceiling && peak > 0.0f ? ceiling / peak : 1.0f;
        const float released = 1.0f
            + previewLimiterRelease * (previewLimiterEnvelope - 1.0f);
        // Never let release advance above the gain required by the current
        // sample; otherwise a rising waveform can overshoot by a few mdB.
        previewLimiterEnvelope = juce::jmin (desired, released);

        for (int channel = 0; channel < channels; ++channel)
            buffer.setSample (channel, sample,
                              buffer.getSample (channel, sample) * previewLimiterEnvelope);
    }
}

void MasteringProcessor::applyPreviewCharacter (juce::AudioBuffer<float>& buffer)
{
    const int channels = juce::jmin (2, buffer.getNumChannels());
    if (channels <= 0)
        return;

    const auto fastTanh = [] (float value)
    {
        const float x = juce::jlimit (-3.0f, 3.0f, value);
        const float square = x * x;
        return x * (27.0f + square) / (27.0f + 9.0f * square);
    };
    float colourNow = previewColourAmount.getCurrentValue();
    const auto shape = [&] (FinalCharacter character, float input)
    {
        if (character == FinalCharacter::CleanSafety)
            return input;

        float curve = 1.20f;
        float bias = 0.0f;
        switch (character)
        {
            case FinalCharacter::VacuumTube:    curve = 1.45f; bias = 0.12f; break;
            case FinalCharacter::MagneticTape: curve = 1.28f; break;
            case FinalCharacter::SoftKneeDiode:curve = 1.62f; bias = -0.07f; break;
            case FinalCharacter::AnalogConsole:curve = 1.18f; break;
            case FinalCharacter::CleanSafety:  break;
        }
        const float saturated = (fastTanh (input * curve + bias) - fastTanh (bias)) / curve;
        return input + (saturated - input) * colourNow;
    };

    for (int sample = 0; sample < buffer.getNumSamples(); ++sample)
    {
        const float drive = previewDriveGain.getNextValue();
        colourNow = previewColourAmount.getNextValue();
        const float fade = previewCharacterFadeRemaining > 0
            ? 1.0f - (float) previewCharacterFadeRemaining
                         / (float) juce::jmax (1, (int) std::round (sr * 0.020))
            : 1.0f;
        for (int channel = 0; channel < channels; ++channel)
        {
            auto* data = buffer.getWritePointer (channel);
            const float driven = data[sample] * drive;
            const float current = shape (previewCharacter, driven);
            const float previous = previewCharacterFadeRemaining > 0
                ? shape (previewPreviousCharacter, driven) : current;
            const float mixed = previous + (current - previous) * fade;

            // A tiny DC blocker protects biased preview characters without a
            // costly always-live bank of five nonlinear processors.
            const float dcBlocked = mixed - previewPreviousOutput[(size_t) channel]
                                  + 0.995f * previewDc[(size_t) channel];
            previewPreviousOutput[(size_t) channel] = mixed;
            previewDc[(size_t) channel] = dcBlocked;
            data[sample] = previewCharacter == FinalCharacter::CleanSafety
                ? mixed : dcBlocked;
        }
        if (previewCharacterFadeRemaining > 0)
            --previewCharacterFadeRemaining;
    }
}

void MasteringProcessor::process (juce::AudioBuffer<float>& buffer, int64_t absoluteSamplePos, int64_t totalSamples)
{
    applyFades (buffer, absoluteSamplePos, totalSamples);
    eq.process (buffer);
    stereo.process (buffer);
    punch.process (buffer);
    deChirp.process (buffer);
    deEsser.process (buffer);
    applyTone (buffer);
    if (! realtimePreviewMode)
        multiband.process (buffer);
    if (realtimePreviewMode)
    {
        // Corrective stages remain exact for useful audition decisions. The
        // four antialiased harmonic generators, tape-noise model, and the
        // five-way character bank are collapsed into one bounded preview
        // character stage. Offline rendering below still runs every full
        // fidelity processor.
        applyPreviewCharacter (buffer);
    }
    else
    {
        warmth.process (buffer);
        analogLife.process (buffer);
        warmExc.process (buffer);
        airExc.process (buffer);
        // Width already applied in stereo tools; re-apply post-harmonics lightly via stereo if needed — skip
        hiss.process (buffer);
    }

    if (normalizeGain.isSmoothing())
    {
        for (int sample = 0; sample < buffer.getNumSamples(); ++sample)
        {
            const float gain = normalizeGain.getNextValue();
            for (int channel = 0; channel < buffer.getNumChannels(); ++channel)
                buffer.getWritePointer (channel)[sample] *= gain;
        }
    }
    else
    {
        const float gain = normalizeGain.getCurrentValue();
        if (std::abs (gain - 1.0f) > 1.0e-6f)
            buffer.applyGain (gain);
    }

    if (! realtimePreviewMode)
        clipper.process (buffer);
    if (realtimePreviewMode)
        applyPreviewLimiter (buffer);
    else
        truePeakLimiter.process (buffer);

    // peaks
    peakL *= 0.999f;
    peakR *= 0.999f;
    if (buffer.getNumChannels() > 0)
        peakL = juce::jmax (peakL, buffer.getMagnitude (0, 0, buffer.getNumSamples()));
    if (buffer.getNumChannels() > 1)
        peakR = juce::jmax (peakR, buffer.getMagnitude (1, 0, buffer.getNumSamples()));
}
