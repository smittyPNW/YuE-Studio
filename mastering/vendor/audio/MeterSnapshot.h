#pragma once

#include <cstdint>

enum class MeterResetReason : uint8_t
{
    none, stopped, paused, endOfFile, reprepare, discontinuity, overflow, oversizedBlock
};

/** Immutable message-thread view of the post-A/B output meters. */
struct MeterSnapshot
{
    uint64_t generation = 0;
    uint64_t processedSamples = 0;
    float samplePeakDbL = -100.0f;
    float samplePeakDbR = -100.0f;
    float rmsDbL = -100.0f;
    float rmsDbR = -100.0f;
    float truePeakDbL = -100.0f;
    float truePeakDbR = -100.0f;
    float momentaryLufs = -100.0f;
    float shortTermLufs = -100.0f;
    float integratedLufs = -100.0f;
    float loudnessRangeLu = 0.0f;
    float correlation = 0.0f;
    float limiterGainReductionDb = 0.0f;
    bool momentaryValid = false;
    bool shortTermValid = false;
    bool integratedValid = false;
    bool loudnessRangeValid = false;
    bool correlationValid = false;
    bool active = false;
    bool streamDiscontinuous = false;
    MeterResetReason resetReason = MeterResetReason::none;
};
