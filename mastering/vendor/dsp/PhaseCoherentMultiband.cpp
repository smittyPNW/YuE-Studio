#include "PhaseCoherentMultiband.h"
#include <complex>

void PhaseCoherentMultiband::prepare (double sampleRate, int maximumBlockSize)
{
    sr = juce::jmax (8000.0, sampleRate);
    preparedBlockSize = juce::jmax (16, maximumBlockSize);
    const auto nyquist = sr * 0.5;
    buildLowPass (lowPassKernels[0], juce::jmin (300.0, nyquist * 0.12));
    buildLowPass (lowPassKernels[1], juce::jmin (1400.0, nyquist * 0.32));
    buildLowPass (lowPassKernels[2], juce::jmin (6500.0, nyquist * 0.72));

    const juce::dsp::ProcessSpec convolutionSpec {
        sr, (juce::uint32) preparedBlockSize, 2
    };
    for (int crossover = 0; crossover < 3; ++crossover)
    {
        juce::AudioBuffer<float> impulse (1, kernelTaps);
        impulse.copyFrom (0, 0, lowPassKernels[(size_t) crossover].data(), kernelTaps);
        convolvers[(size_t) crossover].loadImpulseResponse (
            std::move (impulse), sr, juce::dsp::Convolution::Stereo::no,
            juce::dsp::Convolution::Trim::no,
            juce::dsp::Convolution::Normalise::no);
        convolvers[(size_t) crossover].prepare (convolutionSpec);
        convolutionScratch[(size_t) crossover].setSize (2, preparedBlockSize,
                                                        false, true, false);
        convolutionScratch[(size_t) crossover].clear();
    }

    constexpr std::array<double, bandCount> attackMs { 38.0, 28.0, 16.0, 8.0 };
    constexpr std::array<double, bandCount> releaseMs { 240.0, 190.0, 135.0, 95.0 };
    for (int band = 0; band < bandCount; ++band)
    {
        attackCoefficient[(size_t) band] = (float) std::exp (
            -1.0 / (0.001 * attackMs[(size_t) band] * sr));
        releaseCoefficient[(size_t) band] = (float) std::exp (
            -1.0 / (0.001 * releaseMs[(size_t) band] * sr));
    }
    amountSmoothing = (float) std::exp (-1.0 / (0.040 * sr));
    reset();
}

void PhaseCoherentMultiband::reset()
{
    for (auto& channel : history)
        channel.fill (0.0f);
    envelopePower.fill (0.0f);
    for (auto& convolver : convolvers)
        convolver.reset();
    for (auto& scratch : convolutionScratch)
        scratch.clear();
    writePosition = 0;
    smoothedAmount = targetAmount;
}

void PhaseCoherentMultiband::setAmount (float normalizedAmount)
{
    targetAmount = juce::jlimit (0.0f, 1.0f, normalizedAmount);
}

void PhaseCoherentMultiband::buildLowPass (Kernel& destination, double cutoffHz)
{
    const int centre = getLatencySamples();
    auto buildCandidate = [this] (Kernel& candidate, double designCutoff)
    {
        const double normalizedCutoff = juce::jlimit (0.0001, 0.499, designCutoff / sr);
        double sum = 0.0;
        for (int tap = 0; tap < kernelTaps; ++tap)
        {
            const int offset = tap - centre;
            const double sinc = offset == 0
                ? 2.0 * normalizedCutoff
                : std::sin (juce::MathConstants<double>::twoPi * normalizedCutoff * offset)
                    / (juce::MathConstants<double>::pi * offset);
            const double phase = juce::MathConstants<double>::twoPi * tap / (kernelTaps - 1);
            const double blackman = 0.42 - 0.50 * std::cos (phase) + 0.08 * std::cos (2.0 * phase);
            candidate[(size_t) tap] = (float) (sinc * blackman);
            sum += candidate[(size_t) tap];
        }
        const float normalization = (float) (1.0 / sum);
        for (auto& coefficient : candidate)
            coefficient *= normalization;
    };

    auto magnitudeAt = [this] (const Kernel& kernel, double frequency)
    {
        double real = 0.0, imaginary = 0.0;
        for (int tap = 0; tap < kernelTaps; ++tap)
        {
            const double phase = -juce::MathConstants<double>::twoPi
                               * frequency * tap / sr;
            real += kernel[(size_t) tap] * std::cos (phase);
            imaginary += kernel[(size_t) tap] * std::sin (phase);
        }
        return std::hypot (real, imaginary);
    };

    // A short FIR's design cutoff and measured -3 dB point are not identical,
    // especially in the bass band. Calibrate the design frequency at prepare time so
    // the named crossover is the actual half-power point at every sample rate.
    double lower = juce::jmax (1.0, cutoffHz - 8.0 * sr / kernelTaps);
    double upper = juce::jmin (sr * 0.45, cutoffHz + 8.0 * sr / kernelTaps);
    Kernel candidate {};
    for (int iteration = 0; iteration < 18; ++iteration)
    {
        const double trial = 0.5 * (lower + upper);
        buildCandidate (candidate, trial);
        if (magnitudeAt (candidate, cutoffHz) < std::sqrt (0.5))
            lower = trial;
        else
            upper = trial;
    }
    buildCandidate (destination, 0.5 * (lower + upper));
}

float PhaseCoherentMultiband::getCrossoverMagnitudeDb (int crossover,
                                                        double frequencyHz) const
{
    if (! juce::isPositiveAndBelow (crossover, 3))
        return -160.0f;
    double real = 0.0, imaginary = 0.0;
    const auto& kernel = lowPassKernels[(size_t) crossover];
    for (int tap = 0; tap < kernelTaps; ++tap)
    {
        const double phase = -juce::MathConstants<double>::twoPi
                           * frequencyHz * tap / sr;
        real += kernel[(size_t) tap] * std::cos (phase);
        imaginary += kernel[(size_t) tap] * std::sin (phase);
    }
    return (float) juce::Decibels::gainToDecibels (std::hypot (real, imaginary), -160.0);
}

float PhaseCoherentMultiband::getBandReconstructionResidualDb (double frequencyHz) const
{
    using Complex = std::complex<double>;
    const auto response = [this, frequencyHz] (const Kernel& kernel)
    {
        Complex value {};
        for (int tap = 0; tap < kernelTaps; ++tap)
        {
            const double phase = -juce::MathConstants<double>::twoPi
                               * frequencyHz * tap / sr;
            value += (double) kernel[(size_t) tap]
                   * Complex (std::cos (phase), std::sin (phase));
        }
        return value;
    };

    const auto low = response (lowPassKernels[0]);
    const auto lowMid = response (lowPassKernels[1]) - low;
    const auto highMid = response (lowPassKernels[2])
                       - response (lowPassKernels[1]);
    const auto delay = std::exp (Complex (0.0,
        -juce::MathConstants<double>::twoPi * frequencyHz
        * getLatencySamples() / sr));
    const auto air = delay - response (lowPassKernels[2]);
    return (float) juce::Decibels::gainToDecibels (
        std::abs (low + lowMid + highMid + air - delay), -300.0);
}

float PhaseCoherentMultiband::compressionGainDb (float levelDb, float thresholdDb,
                                                  float ratio, float kneeDb)
{
    const float slope = 1.0f - 1.0f / juce::jmax (1.0f, ratio);
    const float over = levelDb - thresholdDb;
    const float halfKnee = kneeDb * 0.5f;
    if (over <= -halfKnee)
        return 0.0f;
    if (over >= halfKnee)
        return -slope * over;
    const float kneePosition = over + halfKnee;
    return -slope * kneePosition * kneePosition / (2.0f * kneeDb);
}

void PhaseCoherentMultiband::process (juce::AudioBuffer<float>& buffer)
{
    if (buffer.getNumChannels() == 0)
        return;

    for (int start = 0; start < buffer.getNumSamples(); start += preparedBlockSize)
        processChunk (buffer, start,
                      juce::jmin (preparedBlockSize, buffer.getNumSamples() - start));
}

void PhaseCoherentMultiband::processChunk (juce::AudioBuffer<float>& buffer,
                                            int startSample, int sampleCount)
{
    jassert (preparedBlockSize > 0 && sampleCount <= preparedBlockSize);

    const int channels = juce::jmin (2, buffer.getNumChannels());
    for (int crossover = 0; crossover < 3; ++crossover)
    {
        auto& scratch = convolutionScratch[(size_t) crossover];
        for (int channel = 0; channel < channels; ++channel)
            scratch.copyFrom (channel, 0, buffer, channel, startSample, sampleCount);
        for (int channel = channels; channel < 2; ++channel)
            scratch.clear (channel, 0, sampleCount);

        juce::dsp::AudioBlock<float> block (scratch);
        auto active = block.getSubBlock (0, (size_t) sampleCount);
        juce::dsp::ProcessContextReplacing<float> context (active);
        convolvers[(size_t) crossover].process (context);
    }

    // All complementary bands share the same stereo-linked program detector
    // and threshold. Detecting each split in isolation under-reads a sine by
    // about 3 dB at a crossover, so the two adjacent bands relax together and
    // create an audible response halo. Shared level with band-specific timing
    // keeps steady-state tonality flat while preserving multiband transient
    // behaviour.
    constexpr float thresholdDb = -18.0f;
    for (int localSample = 0; localSample < sampleCount; ++localSample)
    {
        const int sample = startSample + localSample;
        smoothedAmount = targetAmount
                       + amountSmoothing * (smoothedAmount - targetAmount);

        float delayed[2] {};
        float lowPass[2][3] {};
        for (int channel = 0; channel < channels; ++channel)
        {
            history[(size_t) channel][(size_t) writePosition] = buffer.getSample (channel, sample);
            int delayPosition = writePosition - getLatencySamples();
            if (delayPosition < 0)
                delayPosition += kernelTaps;
            delayed[channel] = history[(size_t) channel][(size_t) delayPosition];
            for (int crossover = 0; crossover < 3; ++crossover)
                lowPass[channel][crossover] = convolutionScratch[(size_t) crossover]
                    .getSample (channel, localSample);
        }

        float bands[2][bandCount] {};
        for (int channel = 0; channel < channels; ++channel)
        {
            bands[channel][0] = lowPass[channel][0];
            bands[channel][1] = lowPass[channel][1] - lowPass[channel][0];
            bands[channel][2] = lowPass[channel][2] - lowPass[channel][1];
            bands[channel][3] = delayed[channel] - lowPass[channel][2];
        }

        float bandGain[bandCount] {};
        const float ratio = 1.0f + 1.25f * smoothedAmount;
        float linkedDetectorPower = delayed[0] * delayed[0];
        if (channels > 1)
            linkedDetectorPower = juce::jmax (linkedDetectorPower,
                                              delayed[1] * delayed[1]);
        for (int band = 0; band < bandCount; ++band)
        {
            auto& envelope = envelopePower[(size_t) band];
            const float coefficient = linkedDetectorPower > envelope
                ? attackCoefficient[(size_t) band]
                : releaseCoefficient[(size_t) band];
            envelope = linkedDetectorPower
                     + coefficient * (envelope - linkedDetectorPower);
            const float levelDb = 10.0f * std::log10 (juce::jmax (1.0e-12f, envelope));
            bandGain[band] = juce::Decibels::decibelsToGain (
                compressionGainDb (levelDb, thresholdDb, ratio, 8.0f));
        }

        for (int channel = 0; channel < channels; ++channel)
        {
            if (smoothedAmount <= 1.0e-7f)
            {
                buffer.setSample (channel, sample, delayed[channel]);
                continue;
            }
            float output = 0.0f;
            for (int band = 0; band < bandCount; ++band)
                output += bands[channel][band] * bandGain[band];
            buffer.setSample (channel, sample, output);
        }

        if (++writePosition == kernelTaps)
            writePosition = 0;
    }
}
