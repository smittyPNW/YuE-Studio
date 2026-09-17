#pragma once

#include "MeterSnapshot.h"
#include "dsp/Polyphase4x.h"
#include <array>
#include <vector>

/** Allocation-free-after-prepare streaming BS.1770/RMS/true-peak analysis.
    Intended for a worker thread fed by the audio callback, never for UI painting. */
class StreamingMeterProcessor
{
public:
    void prepare (double sampleRate);
    void reset (uint64_t generation = 0);
    void markDiscontinuity() { reset (activeGeneration); }
    void process (const float* left, const float* right, int samples,
                  uint64_t generation);
    MeterSnapshot snapshot (float limiterGainReductionDb = 0.0f,
                            bool resetIntervalPeaks = true);
    uint64_t getProcessedSamples() const { return (uint64_t) samplesSeen; }
    static constexpr size_t getHistoryBinCount() { return histogramBinCount; }
    static float calculateLoudnessRangeFromShortTermLufs (const float* values,
                                                           size_t count, bool& valid);

private:
    struct Biquad
    {
        double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
        double z1 = 0.0, z2 = 0.0;
        double process (double x);
        void clear() { z1 = z2 = 0.0; }
    };

    struct KChannel
    {
        Biquad shelf, highPass;
        double process (double x) { return highPass.process (shelf.process (x)); }
        void clear() { shelf.clear(); highPass.clear(); }
    };

    double sr = 48000.0;
    uint64_t activeGeneration = 0;
    bool prepared = false;
    bool discontinuity = false;
    int64_t samplesSeen = 0;
    int hopSamples = 4800;
    int samplesToHop = 4800;
    int rmsWindow = 14400;
    int momentaryWindow = 19200;
    int shortTermWindow = 144000;

    std::array<KChannel, 2> kWeight;
    std::array<std::vector<double>, 2> rmsRing;
    std::array<double, 2> rmsSums {};
    int rmsIndex = 0;
    int rmsCount = 0;
    std::vector<double> momentaryRing;
    std::vector<double> shortTermRing;
    double momentarySum = 0.0;
    double shortTermSum = 0.0;
    int momentaryIndex = 0, shortTermIndex = 0;
    int momentaryCount = 0, shortTermCount = 0;
    static constexpr float histogramMinimumLufs = -70.0f;
    static constexpr float histogramMaximumLufs = 20.0f;
    static constexpr float histogramStepLu = 0.001f;
    static constexpr size_t histogramBinCount = 90000;
    struct PowerBin { uint64_t count = 0; double powerSum = 0.0; };
    std::vector<PowerBin> integratedHistogram;
    std::vector<PowerBin> shortTermHistogram;
    int lraHopCounter = 0;

    std::vector<double> correlationRing;
    double correlationSum = 0.0;

    Polyphase4x::Phases phases;
    std::array<std::array<double, Polyphase4x::tapsPerPhase>, 2> tpHistory {};
    std::array<int, 2> tpIndex {};
    std::array<double, 2> intervalSamplePeak {};
    std::array<double, 2> intervalTruePeak {};

    static Biquad makeKWeightingShelf (double sampleRate);
    static Biquad makeKWeightingHighPass (double sampleRate);
    static float powerToLufs (double power);
    static float amplitudeToDb (double amplitude);
    void processTruePeak (int channel, double sample);
    float integratedLufs() const;
    float loudnessRangeLu (bool& valid) const;
    static float loudnessRangeFromHistogram (const std::vector<PowerBin>& histogram,
                                              bool& valid);
    static void addToHistogram (std::vector<PowerBin>& histogram,
                                double power);
    static bool gatedHistogramMean (const std::vector<PowerBin>& histogram,
                                    float relativeGateLu, double& meanPower,
                                    uint64_t& includedCount);
    static bool absoluteHistogramMean (const std::vector<PowerBin>& histogram,
                                       double& meanPower, uint64_t& includedCount);
};
