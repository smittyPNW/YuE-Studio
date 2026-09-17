#pragma once

#include <JuceHeader.h>

/**
    Transparent four-band mastering glue.

    Three equal-length linear-phase low-pass kernels form complementary bands:
    low = H1, low-mid = H2-H1, high-mid = H3-H2, air = delay-H3.
    Their sum is therefore the delayed input, avoiding the crossover magnitude
    and phase errors produced by independently cascaded IIR branches.
*/
class PhaseCoherentMultiband
{
public:
    void prepare (double sampleRate, int maximumBlockSize = 8192);
    void reset();
    void setAmount (float normalizedAmount);
    void process (juce::AudioBuffer<float>& buffer);
    float getCrossoverMagnitudeDb (int crossover, double frequencyHz) const;
    float getBandReconstructionResidualDb (double frequencyHz) const;

    static constexpr int getLatencySamples() { return kernelTaps / 2; }

private:
    // 513 taps keeps the 300 Hz bass crossover honest through 96 kHz. JUCE's
    // partitioned convolution engine executes these kernels blockwise; the
    // audio callback never performs the former 3 x 513 scalar tap walk.
    static constexpr int kernelTaps = 513;
    static constexpr int bandCount = 4;
    using Kernel = std::array<float, kernelTaps>;
    using History = std::array<float, kernelTaps>;

    double sr = 44100.0;
    float targetAmount = 0.0f;
    float smoothedAmount = 0.0f;
    float amountSmoothing = 0.0f;
    int writePosition = 0;
    int preparedBlockSize = 0;
    std::array<Kernel, 3> lowPassKernels {};
    std::array<History, 2> history {};
    std::array<juce::dsp::Convolution, 3> convolvers {
        juce::dsp::Convolution (juce::dsp::Convolution::NonUniform { 256 }),
        juce::dsp::Convolution (juce::dsp::Convolution::NonUniform { 256 }),
        juce::dsp::Convolution (juce::dsp::Convolution::NonUniform { 256 })
    };
    std::array<juce::AudioBuffer<float>, 3> convolutionScratch;
    std::array<float, bandCount> envelopePower {};
    std::array<float, bandCount> attackCoefficient {};
    std::array<float, bandCount> releaseCoefficient {};

    void buildLowPass (Kernel& destination, double cutoffHz);
    void processChunk (juce::AudioBuffer<float>& buffer, int startSample, int sampleCount);
    static float compressionGainDb (float levelDb, float thresholdDb,
                                    float ratio, float kneeDb);
};
