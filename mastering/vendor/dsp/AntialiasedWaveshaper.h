#pragma once

#include <cmath>

/**
    First-order antiderivative antialiasing (ADAA) for a biased tanh curve.

    The curve is normalized to unity small-signal gain and zero output at zero:
      f(x) = (tanh(drive*x + bias) - tanh(bias))
             / (drive * sech(bias)^2)

    processDelta() subtracts the equally delayed linear reference. That makes
    the returned value a harmonics-only correction which can be mixed with the
    current dry sample without the half-sample parallel-path combing produced
    by mixing a first-order ADAA output directly with an undelayed signal.
*/
class AntialiasedTanh
{
public:
    void reset()
    {
        previousInput = 0.0f;
        initialized = false;
    }

    float process (float input, float drive = 1.0f, float bias = 0.0f)
    {
        drive = std::max (0.05f, drive);
        if (! initialized)
        {
            initialized = true;
            previousInput = input;
            return transfer (input, drive, bias);
        }

        const double current = input;
        const double previous = previousInput;
        const double delta = current - previous;
        const double output = std::abs (delta) < 1.0e-5
            ? transfer ((float) ((current + previous) * 0.5), drive, bias)
            : (antiderivative (current, drive, bias)
               - antiderivative (previous, drive, bias)) / delta;
        previousInput = input;
        return (float) output;
    }

    float processDelta (float input, float drive, float bias = 0.0f)
    {
        const float linearReference = initialized ? 0.5f * (input + previousInput) : input;
        return process (input, drive, bias) - linearReference;
    }

private:
    float previousInput = 0.0f;
    bool initialized = false;

    static float transfer (float input, float drive, float bias)
    {
        const double tanhBias = std::tanh ((double) bias);
        const double sechSquared = std::max (1.0e-6, 1.0 - tanhBias * tanhBias);
        return (float) ((std::tanh ((double) drive * input + bias) - tanhBias)
                        / ((double) drive * sechSquared));
    }

    static double antiderivative (double input, double drive, double bias)
    {
        const double tanhBias = std::tanh (bias);
        const double sechSquared = std::max (1.0e-6, 1.0 - tanhBias * tanhBias);
        return (logCosh (drive * input + bias)
                - drive * input * tanhBias)
               / (drive * drive * sechSquared);
    }

    static double logCosh (double value)
    {
        const double magnitude = std::abs (value);
        return magnitude + std::log1p (std::exp (-2.0 * magnitude)) - std::log (2.0);
    }
};
