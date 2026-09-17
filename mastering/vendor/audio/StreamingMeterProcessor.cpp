#include "StreamingMeterProcessor.h"
#include <algorithm>
#include <cmath>
#include <limits>

double StreamingMeterProcessor::Biquad::process (double x)
{
    const double y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    if (std::abs (z1) < 1.0e-15) z1 = 0.0;
    if (std::abs (z2) < 1.0e-15) z2 = 0.0;
    return y;
}

StreamingMeterProcessor::Biquad StreamingMeterProcessor::makeKWeightingShelf (double sampleRate)
{
    constexpr double frequency = 1681.9744509555319;
    constexpr double gainDb = 3.999843853973347;
    constexpr double q = 0.7071752369554196;
    constexpr double pi = 3.1415926535897932384626433832795;
    const double k = std::tan (pi * frequency / sampleRate);
    const double vh = std::pow (10.0, gainDb / 20.0);
    const double vb = std::pow (vh, 0.499666774155);
    const double a0 = 1.0 + k / q + k * k;
    return { (vh + vb * k / q + k * k) / a0,
             2.0 * (k * k - vh) / a0,
             (vh - vb * k / q + k * k) / a0,
             2.0 * (k * k - 1.0) / a0,
             (1.0 - k / q + k * k) / a0 };
}

StreamingMeterProcessor::Biquad StreamingMeterProcessor::makeKWeightingHighPass (double sampleRate)
{
    constexpr double frequency = 38.13547087602444;
    constexpr double q = 0.5003270373238773;
    constexpr double pi = 3.1415926535897932384626433832795;
    const double k = std::tan (pi * frequency / sampleRate);
    const double a0 = 1.0 + k / q + k * k;
    return { 1.0, -2.0, 1.0,
             2.0 * (k * k - 1.0) / a0,
             (1.0 - k / q + k * k) / a0 };
}

float StreamingMeterProcessor::powerToLufs (double power)
{
    return power > 0.0 ? (float) (-0.691 + 10.0 * std::log10 (power)) : -100.0f;
}

float StreamingMeterProcessor::amplitudeToDb (double amplitude)
{
    return amplitude > 0.0 ? (float) (20.0 * std::log10 (amplitude)) : -100.0f;
}

void StreamingMeterProcessor::prepare (double sampleRate)
{
    sr = std::max (8000.0, sampleRate);
    hopSamples = std::max (1, (int) std::round (0.1 * sr));
    rmsWindow = std::max (1, (int) std::round (0.3 * sr));
    momentaryWindow = std::max (1, (int) std::round (0.4 * sr));
    shortTermWindow = std::max (1, (int) std::round (3.0 * sr));
    for (auto& ring : rmsRing) ring.assign ((size_t) rmsWindow, 0.0);
    correlationRing.assign ((size_t) rmsWindow, 0.0);
    momentaryRing.assign ((size_t) momentaryWindow, 0.0);
    shortTermRing.assign ((size_t) shortTermWindow, 0.0);
    integratedHistogram.assign (histogramBinCount, {});
    shortTermHistogram.assign (histogramBinCount, {});
    phases = Polyphase4x::designPhases();
    prepared = true;
    reset();
}

void StreamingMeterProcessor::reset (uint64_t generation)
{
    activeGeneration = generation;
    discontinuity = samplesSeen > 0;
    samplesSeen = 0;
    samplesToHop = hopSamples;
    rmsSums = {};
    rmsIndex = rmsCount = 0;
    momentarySum = shortTermSum = 0.0;
    momentaryIndex = shortTermIndex = 0;
    momentaryCount = shortTermCount = 0;
    for (auto& ring : rmsRing) std::fill (ring.begin(), ring.end(), 0.0);
    std::fill (correlationRing.begin(), correlationRing.end(), 0.0);
    correlationSum = 0.0;
    std::fill (momentaryRing.begin(), momentaryRing.end(), 0.0);
    std::fill (shortTermRing.begin(), shortTermRing.end(), 0.0);
    std::fill (integratedHistogram.begin(), integratedHistogram.end(), PowerBin {});
    std::fill (shortTermHistogram.begin(), shortTermHistogram.end(), PowerBin {});
    lraHopCounter = 0;
    for (auto& channel : kWeight)
    {
        channel.shelf = makeKWeightingShelf (sr);
        channel.highPass = makeKWeightingHighPass (sr);
    }
    tpHistory = {};
    tpIndex = {};
    intervalSamplePeak = {};
    intervalTruePeak = {};
}

void StreamingMeterProcessor::processTruePeak (int channel, double sample)
{
    auto& history = tpHistory[(size_t) channel];
    auto& index = tpIndex[(size_t) channel];
    history[(size_t) index] = sample;
    intervalSamplePeak[(size_t) channel] = std::max (intervalSamplePeak[(size_t) channel], std::abs (sample));
    intervalTruePeak[(size_t) channel] = std::max (intervalTruePeak[(size_t) channel], std::abs (sample));
    for (const auto& phase : phases)
    {
        double value = 0.0;
        int read = index;
        for (const auto tap : phase)
        {
            value += tap * history[(size_t) read];
            read = read == 0 ? Polyphase4x::tapsPerPhase - 1 : read - 1;
        }
        intervalTruePeak[(size_t) channel] = std::max (intervalTruePeak[(size_t) channel], std::abs (value));
    }
    index = (index + 1) % Polyphase4x::tapsPerPhase;
}

void StreamingMeterProcessor::process (const float* left, const float* right, int samples,
                                       uint64_t generation)
{
    if (! prepared || left == nullptr || right == nullptr || samples <= 0) return;
    if (generation != activeGeneration) reset (generation);

    for (int frame = 0; frame < samples; ++frame)
    {
        const double raw[2] { left[frame], right[frame] };
        double weightedPower = 0.0;
        for (int channel = 0; channel < 2; ++channel)
        {
            processTruePeak (channel, raw[channel]);
            const double square = raw[channel] * raw[channel];
            auto& ring = rmsRing[(size_t) channel];
            rmsSums[(size_t) channel] += square - ring[(size_t) rmsIndex];
            ring[(size_t) rmsIndex] = square;
            const double weighted = kWeight[(size_t) channel].process (raw[channel]);
            weightedPower += weighted * weighted;
        }
        const double cross = raw[0] * raw[1];
        correlationSum += cross - correlationRing[(size_t) rmsIndex];
        correlationRing[(size_t) rmsIndex] = cross;
        rmsIndex = (rmsIndex + 1) % rmsWindow;
        rmsCount = std::min (rmsWindow, rmsCount + 1);

        momentarySum += weightedPower - momentaryRing[(size_t) momentaryIndex];
        momentaryRing[(size_t) momentaryIndex] = weightedPower;
        momentaryIndex = (momentaryIndex + 1) % momentaryWindow;
        momentaryCount = std::min (momentaryWindow, momentaryCount + 1);

        shortTermSum += weightedPower - shortTermRing[(size_t) shortTermIndex];
        shortTermRing[(size_t) shortTermIndex] = weightedPower;
        shortTermIndex = (shortTermIndex + 1) % shortTermWindow;
        shortTermCount = std::min (shortTermWindow, shortTermCount + 1);

        ++samplesSeen;
        if (--samplesToHop == 0)
        {
            if (momentaryCount == momentaryWindow)
                addToHistogram (integratedHistogram, momentarySum / (double) momentaryWindow);
            if (++lraHopCounter == 10)
            {
                if (shortTermCount == shortTermWindow)
                    addToHistogram (shortTermHistogram, shortTermSum / (double) shortTermWindow);
                lraHopCounter = 0;
            }
            samplesToHop = hopSamples;
        }
    }
}

void StreamingMeterProcessor::addToHistogram (
    std::vector<PowerBin>& histogram, double power)
{
    const float lufs = powerToLufs (power);
    if (lufs <= histogramMinimumLufs) return;
    const auto unclamped = (int) std::floor ((lufs - histogramMinimumLufs) / histogramStepLu);
    const size_t index = (size_t) std::clamp (unclamped, 0, (int) histogramBinCount - 1);
    ++histogram[index].count;
    histogram[index].powerSum += power;
}

bool StreamingMeterProcessor::gatedHistogramMean (
    const std::vector<PowerBin>& histogram,
    float relativeGateLu, double& meanPower, uint64_t& includedCount)
{
    double absoluteMean = 0.0;
    uint64_t absoluteCount = 0;
    if (! absoluteHistogramMean (histogram, absoluteMean, absoluteCount))
    {
        meanPower = 0.0;
        includedCount = 0;
        return false;
    }
    const float relativeGate = powerToLufs (absoluteMean) + relativeGateLu;
    double gatedPower = 0.0;
    uint64_t gatedCount = 0;
    for (size_t index = 0; index < histogram.size(); ++index)
    {
        const float binUpperLufs = histogramMinimumLufs + (float) (index + 1) * histogramStepLu;
        if (binUpperLufs > relativeGate)
        {
            gatedPower += histogram[index].powerSum;
            gatedCount += histogram[index].count;
        }
    }
    meanPower = gatedCount > 0 ? gatedPower / (double) gatedCount : 0.0;
    includedCount = gatedCount;
    return gatedCount > 0;
}

bool StreamingMeterProcessor::absoluteHistogramMean (
    const std::vector<PowerBin>& histogram, double& meanPower, uint64_t& includedCount)
{
    double power = 0.0;
    uint64_t count = 0;
    for (const auto& bin : histogram)
    {
        power += bin.powerSum;
        count += bin.count;
    }
    meanPower = count > 0 ? power / (double) count : 0.0;
    includedCount = count;
    return count > 0;
}

float StreamingMeterProcessor::integratedLufs() const
{
    double meanPower = 0.0;
    uint64_t count = 0;
    return gatedHistogramMean (integratedHistogram, -10.0f, meanPower, count)
        ? powerToLufs (meanPower) : -100.0f;
}

float StreamingMeterProcessor::loudnessRangeLu (bool& valid) const
{
    return loudnessRangeFromHistogram (shortTermHistogram, valid);
}

float StreamingMeterProcessor::calculateLoudnessRangeFromShortTermLufs (
    const float* values, size_t count, bool& valid)
{
    std::vector<PowerBin> histogram (histogramBinCount);
    if (values != nullptr)
        for (size_t index = 0; index < count; ++index)
        {
            const double power = std::pow (10.0, ((double) values[index] + 0.691) / 10.0);
            addToHistogram (histogram, power);
        }
    return loudnessRangeFromHistogram (histogram, valid);
}

float StreamingMeterProcessor::loudnessRangeFromHistogram (
    const std::vector<PowerBin>& histogram, bool& valid)
{
    valid = false;
    double absoluteMean = 0.0;
    uint64_t absoluteCount = 0;
    if (! absoluteHistogramMean (histogram, absoluteMean, absoluteCount)
        || absoluteCount < 2)
        return 0.0f;
    // EBU Tech 3342: one relative threshold, 20 LU below the mean of
    // absolute-gated short-term loudness. Do not recompute a second mean/gate.
    const float gate = powerToLufs (absoluteMean) - 20.0f;
    uint64_t gatedCount = 0;
    for (size_t index = 0; index < histogram.size(); ++index)
        if (histogramMinimumLufs + (float) (index + 1) * histogramStepLu > gate)
            gatedCount += histogram[index].count;
    if (gatedCount < 2) return 0.0f;
    const uint64_t p10Target = (uint64_t) std::floor (0.10 * (double) (gatedCount - 1));
    const uint64_t p95Target = (uint64_t) std::floor (0.95 * (double) (gatedCount - 1));
    uint64_t cumulative = 0;
    float p10 = gate, p95 = gate;
    bool found10 = false;
    for (size_t index = 0; index < histogram.size(); ++index)
    {
        const float binLufs = histogramMinimumLufs + ((float) index + 0.5f) * histogramStepLu;
        if (binLufs + 0.5f * histogramStepLu <= gate) continue;
        cumulative += histogram[index].count;
        if (! found10 && cumulative > p10Target) { p10 = binLufs; found10 = true; }
        if (cumulative > p95Target) { p95 = binLufs; break; }
    }
    valid = found10;
    return valid ? std::max (0.0f, p95 - p10) : 0.0f;
}

MeterSnapshot StreamingMeterProcessor::snapshot (float limiterGainReductionDb,
                                                  bool resetIntervalPeaks)
{
    MeterSnapshot result;
    result.generation = activeGeneration;
    result.processedSamples = (uint64_t) samplesSeen;
    result.active = samplesSeen > 0;
    result.samplePeakDbL = amplitudeToDb (intervalSamplePeak[0]);
    result.samplePeakDbR = amplitudeToDb (intervalSamplePeak[1]);
    result.truePeakDbL = amplitudeToDb (intervalTruePeak[0]);
    result.truePeakDbR = amplitudeToDb (intervalTruePeak[1]);
    if (rmsCount > 0)
    {
        result.rmsDbL = amplitudeToDb (std::sqrt (std::max (0.0, rmsSums[0] / (double) rmsCount)));
        result.rmsDbR = amplitudeToDb (std::sqrt (std::max (0.0, rmsSums[1] / (double) rmsCount)));
    }
    result.momentaryValid = momentaryCount == momentaryWindow;
    result.shortTermValid = shortTermCount == shortTermWindow;
    double integratedMean = 0.0;
    uint64_t integratedCount = 0;
    result.integratedValid = gatedHistogramMean (integratedHistogram, -10.0f,
                                                  integratedMean, integratedCount);
    if (result.momentaryValid) result.momentaryLufs = powerToLufs (momentarySum / (double) momentaryWindow);
    if (result.shortTermValid) result.shortTermLufs = powerToLufs (shortTermSum / (double) shortTermWindow);
    if (result.integratedValid) result.integratedLufs = powerToLufs (integratedMean);
    result.loudnessRangeLu = loudnessRangeLu (result.loudnessRangeValid);
    const double denominator = std::sqrt (std::max (0.0, rmsSums[0] * rmsSums[1]));
    result.correlationValid = rmsCount == rmsWindow && denominator > 1.0e-14;
    if (result.correlationValid)
        result.correlation = std::clamp ((float) (correlationSum / denominator), -1.0f, 1.0f);
    result.limiterGainReductionDb = std::max (0.0f, limiterGainReductionDb);
    result.streamDiscontinuous = discontinuity;
    discontinuity = false;
    if (resetIntervalPeaks)
    {
        intervalSamplePeak = {};
        intervalTruePeak = {};
    }
    return result;
}
