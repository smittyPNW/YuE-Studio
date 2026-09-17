#pragma once

#include <array>

/** Shared 4x polyphase reconstruction filter used by true-peak metering and limiting. */
struct Polyphase4x
{
    static constexpr int oversampling = 4;
    static constexpr int tapsPerPhase = 12;
    using Phase = std::array<double, tapsPerPhase>;
    using Phases = std::array<Phase, oversampling>;

    static Phases designPhases();

private:
    static double besselI0 (double x);
};
