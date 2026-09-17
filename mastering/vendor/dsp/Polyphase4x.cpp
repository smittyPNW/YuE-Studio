#include "Polyphase4x.h"
#include <algorithm>
#include <cmath>

double Polyphase4x::besselI0 (double x)
{
    double sum = 1.0;
    double term = 1.0;
    for (int k = 1; k <= 30; ++k)
    {
        const double factor = x / (2.0 * (double) k);
        term *= factor * factor;
        sum += term;
        if (term < 1.0e-18 * sum)
            break;
    }
    return sum;
}

Polyphase4x::Phases Polyphase4x::designPhases()
{
    constexpr int tapCount = oversampling * tapsPerPhase;
    constexpr double pi = 3.1415926535897932384626433832795;
    const double centre = (double) (tapCount - 1) / 2.0;
    const double beta = 8.0;
    const double i0Beta = besselI0 (beta);

    std::array<double, tapCount> impulse {};
    for (int i = 0; i < tapCount; ++i)
    {
        const double t = ((double) i - centre) / (double) oversampling;
        const double sinc = std::abs (t) < 1.0e-15 ? 1.0 : std::sin (pi * t) / (pi * t);
        const double x = ((double) i - centre) / centre;
        const double window = besselI0 (beta * std::sqrt (std::max (0.0, 1.0 - x * x))) / i0Beta;
        impulse[(size_t) i] = sinc * window;
    }

    Phases phases {};
    for (int phase = 0; phase < oversampling; ++phase)
    {
        double sum = 0.0;
        for (int tap = 0; tap < tapsPerPhase; ++tap)
        {
            const auto value = impulse[(size_t) (tap * oversampling + phase)];
            phases[(size_t) phase][(size_t) tap] = value;
            sum += value;
        }
        if (std::abs (sum) > 1.0e-15)
            for (auto& value : phases[(size_t) phase])
                value /= sum;
    }
    return phases;
}
