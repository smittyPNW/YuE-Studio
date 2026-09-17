#include "DeChirp.h"
#include <algorithm>
#include <cmath>

namespace
{
constexpr float silenceFloorDb = -76.0f;
constexpr float minimumSearchHz = 7500.0f;
constexpr float maximumSearchHz = 20000.0f;

float magnitudeToDb (float magnitude, float windowSum)
{
    return juce::Decibels::gainToDecibels (
        magnitude / juce::jmax (1.0f, windowSum * 0.5f), -160.0f);
}
}

void DeChirp::NotchSlot::clear()
{
    observedFrequencyHz = 0.0f;
    observedProminenceDb = 0.0f;
    targetFrequencyHz = currentFrequencyHz = 10000.0f;
    targetGainDb = currentGainDb = 0.0f;
    evidenceFrames = missedFrames = 0;
    b0 = 1.0f; b1 = b2 = a1 = a2 = 0.0f;
    z1.fill (0.0f);
    z2.fill (0.0f);
}

void DeChirp::NotchSlot::updateCoefficients (double sampleRate)
{
    if (std::abs (currentGainDb) < 0.005f)
    {
        b0 = 1.0f; b1 = b2 = a1 = a2 = 0.0f;
        return;
    }

    // RBJ peaking filter used as a finite-depth surgical notch. Q is high
    // enough to spare cymbal energy around the tone, but not so high that a
    // slowly drifting synthetic whistle slips between detector updates.
    constexpr float q = 34.0f;
    const float frequency = juce::jlimit (minimumSearchHz,
                                          (float) sampleRate * 0.45f,
                                          currentFrequencyHz);
    const float omega = juce::MathConstants<float>::twoPi
                      * frequency / (float) sampleRate;
    const float alpha = std::sin (omega) / (2.0f * q);
    const float cosine = std::cos (omega);
    const float A = std::pow (10.0f, currentGainDb / 40.0f);
    const float inverseA0 = 1.0f / (1.0f + alpha / A);

    b0 = (1.0f + alpha * A) * inverseA0;
    b1 = (-2.0f * cosine) * inverseA0;
    b2 = (1.0f - alpha * A) * inverseA0;
    a1 = (-2.0f * cosine) * inverseA0;
    a2 = (1.0f - alpha / A) * inverseA0;
}

float DeChirp::NotchSlot::processSample (int channel, float input)
{
    if (std::abs (currentGainDb) < 0.005f)
        return input;

    const auto index = (size_t) juce::jlimit (0, 1, channel);
    const float output = b0 * input + z1[index];
    z1[index] = b1 * input - a1 * output + z2[index];
    z2[index] = b2 * input - a2 * output;
    return output;
}

void DeChirp::prepare (double sampleRate)
{
    sr = juce::jmax (8000.0, sampleRate);
    reset();
}

void DeChirp::reset()
{
    for (auto& channel : analysisInput)
        channel.fill (0.0f);
    for (auto& channel : fftData)
        channel.fill (0.0f);
    analysisWritePosition = 0;
    samplesUntilCoefficientUpdate = 0;
    for (auto& notch : notches)
        notch.clear();
}

void DeChirp::setAmount (float value)
{
    amount = juce::jlimit (0.0f, 1.0f, value);
    if (amount < 1.0e-4f)
        reset();
}

void DeChirp::analyzeFrame()
{
    for (auto& channel : fftData)
        channel.fill (0.0f);
    float windowSum = 0.0f;
    for (int sample = 0; sample < fftSize; ++sample)
    {
        const float window = 0.5f - 0.5f * std::cos (
            juce::MathConstants<float>::twoPi * (float) sample / (float) (fftSize - 1));
        for (int channel = 0; channel < 2; ++channel)
            fftData[(size_t) channel][(size_t) sample]
                = analysisInput[(size_t) channel][(size_t) sample] * window;
        windowSum += window;
    }
    for (auto& channel : fftData)
        fft.performFrequencyOnlyForwardTransform (channel.data());

    // Collapse the two magnitude spectra only after the FFT. A mono-summed
    // detector can completely miss an opposite-phase or one-sided whistle;
    // max-linked channel energy finds it without changing the stereo audio.
    for (int bin = 0; bin <= fftSize / 2; ++bin)
        fftData[0][(size_t) bin] = juce::jmax (
            fftData[0][(size_t) bin], fftData[1][(size_t) bin]);
    auto& magnitudes = fftData[0];

    const int firstBin = juce::jlimit (2, fftSize / 2 - 2,
        (int) std::ceil (minimumSearchHz * (double) fftSize / sr));
    const int lastBin = juce::jlimit (firstBin, fftSize / 2 - 13,
        (int) std::floor (juce::jmin (maximumSearchHz, (float) sr * 0.45f)
                          * (double) fftSize / sr));

    std::array<Candidate, maximumCandidates> candidates {};
    int candidateCount = 0;
    const float requiredProminenceDb = 13.0f - amount * 2.5f;

    for (int bin = firstBin; bin <= lastBin; ++bin)
    {
        const float magnitude = magnitudes[(size_t) bin];
        if (magnitude <= magnitudes[(size_t) (bin - 1)]
            || magnitude < magnitudes[(size_t) (bin + 1)])
            continue;

        float neighborhoodPower = 0.0f;
        int neighborhoodBins = 0;
        for (int offset = 4; offset <= 12; ++offset)
        {
            const float below = magnitudes[(size_t) (bin - offset)];
            const float above = magnitudes[(size_t) (bin + offset)];
            neighborhoodPower += below * below + above * above;
            neighborhoodBins += 2;
        }
        const float localRms = std::sqrt (neighborhoodPower
                                          / (float) juce::jmax (1, neighborhoodBins));
        const float prominenceDb = juce::Decibels::gainToDecibels (
            magnitude / juce::jmax (1.0e-12f, localRms), 0.0f);
        const float levelDb = magnitudeToDb (magnitude, windowSum);
        if (prominenceDb < requiredProminenceDb || levelDb < silenceFloorDb)
            continue;

        Candidate candidate;
        // Parabolic peak interpolation reduces frequency quantisation without
        // increasing FFT size or control-path CPU.
        const float left = std::log (juce::jmax (magnitudes[(size_t) (bin - 1)], 1.0e-12f));
        const float centre = std::log (juce::jmax (magnitude, 1.0e-12f));
        const float right = std::log (juce::jmax (magnitudes[(size_t) (bin + 1)], 1.0e-12f));
        const float denominator = left - 2.0f * centre + right;
        const float offset = std::abs (denominator) > 1.0e-9f
            ? juce::jlimit (-0.5f, 0.5f, 0.5f * (left - right) / denominator)
            : 0.0f;
        candidate.frequencyHz = ((float) bin + offset) * (float) sr / (float) fftSize;
        candidate.prominenceDb = prominenceDb;
        candidate.levelDb = levelDb;

        const auto priority = [] (const Candidate& item)
        {
            // Prominence proves tonality; modest level weighting prevents a
            // barely audible laboratory line from consuming every notch while
            // an obvious whistle is sounding nearby.
            return item.prominenceDb + 0.30f * (item.levelDb - silenceFloorDb);
        };
        int insertAt = candidateCount;
        while (insertAt > 0
               && priority (candidates[(size_t) (insertAt - 1)]) < priority (candidate))
            --insertAt;
        if (insertAt < maximumCandidates)
        {
            const int last = juce::jmin (candidateCount, maximumCandidates - 1);
            for (int index = last; index > insertAt; --index)
                candidates[(size_t) index] = candidates[(size_t) (index - 1)];
            candidates[(size_t) insertAt] = candidate;
            candidateCount = juce::jmin (candidateCount + 1, maximumCandidates);
        }
    }

    updateTracking (candidates, candidateCount);
}

void DeChirp::updateTracking (
    const std::array<Candidate, maximumCandidates>& candidates, int candidateCount)
{
    std::array<bool, maximumCandidates> used {};
    constexpr float trackingRangeHz = 105.0f;

    // Existing tracks get first choice, preventing slots from hopping among a
    // harmonic cluster merely because one neighbouring partial became louder.
    for (auto& notch : notches)
    {
        int best = -1;
        float bestDistance = trackingRangeHz;
        if (notch.observedFrequencyHz > 0.0f)
            for (int index = 0; index < candidateCount; ++index)
            {
                if (used[(size_t) index])
                    continue;
                const float distance = std::abs (
                    candidates[(size_t) index].frequencyHz - notch.observedFrequencyHz);
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    best = index;
                }
            }

        if (best >= 0)
        {
            const auto& candidate = candidates[(size_t) best];
            used[(size_t) best] = true;
            notch.observedFrequencyHz = notch.evidenceFrames > 0
                ? 0.72f * notch.observedFrequencyHz + 0.28f * candidate.frequencyHz
                : candidate.frequencyHz;
            notch.observedProminenceDb = candidate.prominenceDb;
            notch.evidenceFrames = juce::jmin (8, notch.evidenceFrames + 1);
            // A very prominent, clearly audible whistle earns fast attack
            // after one complete frame. Lower-level lines still require
            // persistence, protecting broadband percussion and room air.
            if (candidate.prominenceDb >= 19.0f && candidate.levelDb >= -64.0f)
                notch.evidenceFrames = juce::jmax (2, notch.evidenceFrames);
            notch.missedFrames = 0;
        }
        else if (notch.observedFrequencyHz > 0.0f)
        {
            ++notch.missedFrames;
            notch.evidenceFrames = juce::jmax (0, notch.evidenceFrames - 1);
            if (notch.missedFrames >= 4)
            {
                notch.targetGainDb = 0.0f;
                if (notch.evidenceFrames == 0)
                    notch.observedFrequencyHz = 0.0f;
            }
        }
    }

    // Seed empty slots from the strongest remaining, well-separated peaks.
    for (int candidateIndex = 0; candidateIndex < candidateCount; ++candidateIndex)
    {
        if (used[(size_t) candidateIndex])
            continue;
        const auto& candidate = candidates[(size_t) candidateIndex];
        bool tooClose = false;
        for (const auto& notch : notches)
            tooClose = tooClose || (notch.observedFrequencyHz > 0.0f
                && std::abs (candidate.frequencyHz - notch.observedFrequencyHz) < 220.0f);
        if (tooClose)
            continue;

        auto empty = std::find_if (notches.begin(), notches.end(), [] (const NotchSlot& notch)
        {
            return notch.observedFrequencyHz <= 0.0f;
        });
        if (empty == notches.end())
            break;
        empty->observedFrequencyHz = candidate.frequencyHz;
        empty->observedProminenceDb = candidate.prominenceDb;
        empty->evidenceFrames = candidate.prominenceDb >= 19.0f
                                    && candidate.levelDb >= -64.0f ? 2 : 1;
        empty->missedFrames = 0;
        used[(size_t) candidateIndex] = true;
    }

    const float maximumCutDb = 4.0f + amount * 8.0f;
    for (auto& notch : notches)
    {
        if (notch.evidenceFrames >= 2 && notch.missedFrames < 4)
        {
            const float confidence = juce::jlimit (
                0.0f, 1.0f, (notch.observedProminenceDb - 11.0f) / 13.0f);
            notch.targetFrequencyHz = notch.observedFrequencyHz;
            notch.targetGainDb = -maximumCutDb * confidence;
        }
        else if (notch.missedFrames > 0)
            notch.targetGainDb = 0.0f;
    }
}

void DeChirp::updateNotchCoefficients()
{
    for (auto& notch : notches)
    {
        const bool attacking = notch.targetGainDb < notch.currentGainDb;
        const float gainSmoothing = attacking ? 0.22f : 0.08f;
        notch.currentGainDb += gainSmoothing * (notch.targetGainDb - notch.currentGainDb);
        notch.currentFrequencyHz += 0.18f
            * (notch.targetFrequencyHz - notch.currentFrequencyHz);
        if (! attacking && std::abs (notch.currentGainDb) < 0.005f)
        {
            notch.currentGainDb = 0.0f;
            notch.z1.fill (0.0f);
            notch.z2.fill (0.0f);
        }
        notch.updateCoefficients (sr);
    }
}

void DeChirp::process (juce::AudioBuffer<float>& buffer)
{
    if (amount < 1.0e-4f || buffer.getNumChannels() <= 0)
        return;

    const int channels = juce::jmin (2, buffer.getNumChannels());
    for (int sample = 0; sample < buffer.getNumSamples(); ++sample)
    {
        analysisInput[0][(size_t) analysisWritePosition] = buffer.getSample (0, sample);
        analysisInput[1][(size_t) analysisWritePosition] = channels > 1
            ? buffer.getSample (1, sample) : buffer.getSample (0, sample);
        if (++analysisWritePosition == fftSize)
        {
            analysisWritePosition = 0;
            analyzeFrame();
        }

        if (samplesUntilCoefficientUpdate <= 0)
        {
            updateNotchCoefficients();
            samplesUntilCoefficientUpdate = coefficientInterval;
        }
        --samplesUntilCoefficientUpdate;

        for (int channel = 0; channel < channels; ++channel)
        {
            float value = buffer.getSample (channel, sample);
            for (auto& notch : notches)
                value = notch.processSample (channel, value);
            buffer.setSample (channel, sample, value);
        }
    }
}
