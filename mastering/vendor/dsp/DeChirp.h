#pragma once
#include <JuceHeader.h>
#include <array>

// Stereo-linked, content-aware repair for narrow high-frequency whistles.
//
// The detector measures both channels independently so anti-phase or one-sided
// tones cannot disappear in a mono sum. Each selected notch is then applied
// with identical coefficients to L/R, preserving the stereo image and avoiding
// the broad, modulated high-band smear used by the original implementation.
class DeChirp
{
public:
    void prepare (double sampleRate);
    void reset();
    void setAmount (float amount01);
    void process (juce::AudioBuffer<float>& buffer);

private:
    static constexpr int fftOrder = 11;
    static constexpr int fftSize = 1 << fftOrder;
    static constexpr int maximumCandidates = 12;
    static constexpr int notchCount = 4;
    static constexpr int coefficientInterval = 64;

    struct Candidate
    {
        float frequencyHz = 0.0f;
        float prominenceDb = 0.0f;
        float levelDb = -160.0f;
    };

    struct NotchSlot
    {
        float observedFrequencyHz = 0.0f;
        float observedProminenceDb = 0.0f;
        float targetFrequencyHz = 10000.0f;
        float currentFrequencyHz = 10000.0f;
        float targetGainDb = 0.0f;
        float currentGainDb = 0.0f;
        int evidenceFrames = 0;
        int missedFrames = 0;

        float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
        float a1 = 0.0f, a2 = 0.0f;
        std::array<float, 2> z1 {}, z2 {};

        void clear();
        void updateCoefficients (double sampleRate);
        float processSample (int channel, float input);
    };

    void analyzeFrame();
    void updateTracking (const std::array<Candidate, maximumCandidates>& candidates,
                         int candidateCount);
    void updateNotchCoefficients();

    double sr = 44100.0;
    float amount = 0.0f;
    int analysisWritePosition = 0;
    int samplesUntilCoefficientUpdate = 0;
    juce::dsp::FFT fft { fftOrder };
    std::array<std::array<float, fftSize>, 2> analysisInput {};
    std::array<std::array<float, fftSize * 2>, 2> fftData {};
    std::array<NotchSlot, notchCount> notches {};
};
