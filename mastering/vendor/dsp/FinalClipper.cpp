#include "FinalClipper.h"

void FinalClipper::prepare (double sampleRate)
{
    juce::dsp::ProcessSpec spec { sampleRate, 512, 1 };
    for (auto* f : { &tapeLpL, &tapeLpR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::lowpass);
        f->setCutoffFrequency (14000.0f);
    }
    for (auto* f : { &tapeBumpL, &tapeBumpR })
    {
        f->prepare (spec);
        f->setType (juce::dsp::StateVariableTPTFilterType::bandpass);
        f->setCutoffFrequency (80.0f);
        f->setResonance (0.3f);
    }
    driveLin.reset (sampleRate, 0.035);
    driveLin.setCurrentAndTargetValue (driveTarget);
    activeTargetMode = (FinalCharacter) juce::jlimit (
        0, modeCount - 1, targetMode.load (std::memory_order_acquire));
    for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
    {
        modeWeights[(size_t) modeIndex].reset (sampleRate, 0.020);
        modeWeights[(size_t) modeIndex].setCurrentAndTargetValue (
            modeIndex == (int) activeTargetMode ? 1.0f : 0.0f);
    }
    hasProcessed = false;
    reset();
}

void FinalClipper::reset()
{
    tapeLpL.reset(); tapeLpR.reset(); tapeBumpL.reset(); tapeBumpR.reset();
    for (auto& channel : dc) channel.fill (0.0f);
    for (auto& channel : previousInput) channel.fill (0.0f);
    for (auto& channel : shapers)
        for (auto& shaper : channel)
            shaper.reset();
    for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
        modeWeights[(size_t) modeIndex].setCurrentAndTargetValue (
            modeIndex == (int) activeTargetMode ? 1.0f : 0.0f);
}

void FinalClipper::setMode (FinalCharacter m)
{
    targetMode.store (juce::jlimit (0, modeCount - 1, (int) m),
                      std::memory_order_release);
}
void FinalClipper::setDriveDb (float masterVolDb)
{
    driveTarget = juce::Decibels::decibelsToGain (juce::jlimit (-12.0f, 18.0f, masterVolDb));
    driveLin.setTargetValue (driveTarget);
}

float FinalClipper::shapeForMode (FinalCharacter character, float x, float drive,
                                  int channel)
{
    const float driven = x * drive;
    const int modeIndex = juce::jlimit (0, modeCount - 1, (int) character);
    auto& antialiased = shapers[(size_t) channel][(size_t) modeIndex];
    float curveDrive = 1.0f;
    float bias = 0.0f;
    switch (character)
    {
        case FinalCharacter::CleanSafety:
            // Clean is bit-transparent apart from requested drive. The shared
            // oversampled true-peak stage provides the always-on emergency
            // ceiling, so no base-rate post-ADAA waveshaper is required here.
            (void) antialiased.processDelta (driven, 1.0f);
            return driven;
        case FinalCharacter::VacuumTube:
            curveDrive = 1.55f;
            bias = 0.18f;
            break;
        case FinalCharacter::MagneticTape:
            curveDrive = 1.35f;
            break;
        case FinalCharacter::SoftKneeDiode:
            curveDrive = 1.85f;
            bias = -0.10f;
            break;
        case FinalCharacter::AnalogConsole:
        default:
            curveDrive = 1.25f;
            break;
    }

    // Add only the antialiased nonlinear residual to the current input. The
    // residual's linear reference has the same half-sample ADAA delay, so the
    // audible dry component stays phase coherent and no fractional latency is
    // hidden from the processor's integer latency declaration.
    return driven + antialiased.processDelta (driven, curveDrive, bias);
}

void FinalClipper::process (juce::AudioBuffer<float>& buffer)
{
    const int n = buffer.getNumSamples();
    const int ch = juce::jmin (2, buffer.getNumChannels());

    if (! hasProcessed)
    {
        activeTargetMode = (FinalCharacter) juce::jlimit (
            0, modeCount - 1, targetMode.load (std::memory_order_acquire));
        for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
            modeWeights[(size_t) modeIndex].setCurrentAndTargetValue (
                modeIndex == (int) activeTargetMode ? 1.0f : 0.0f);
        hasProcessed = true;
    }

    for (int i = 0; i < n; ++i)
    {
        const auto requestedMode = (FinalCharacter) juce::jlimit (
            0, modeCount - 1, targetMode.load (std::memory_order_acquire));
        if (requestedMode != activeTargetMode)
        {
            activeTargetMode = requestedMode;
            // Retarget the current five-way blend without resetting any
            // current value. Rapid selections therefore remain continuous.
            for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
                modeWeights[(size_t) modeIndex].setTargetValue (
                    modeIndex == (int) activeTargetMode ? 1.0f : 0.0f);
        }

        const float drive = driveLin.getNextValue();
        std::array<float, modeCount> weights {};
        float weightSum = 0.0f;
        for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
        {
            weights[(size_t) modeIndex] = modeWeights[(size_t) modeIndex].getNextValue();
            weightSum += weights[(size_t) modeIndex];
        }
        const float inverseWeightSum = 1.0f / juce::jmax (1.0e-6f, weightSum);
        for (int c = 0; c < ch; ++c)
        {
            auto* d = buffer.getWritePointer (c);
            auto& tapeLp = (c == 0 ? tapeLpL : tapeLpR);
            auto& tapeBump = (c == 0 ? tapeBumpL : tapeBumpR);
            const float x = d[i];

            // Tape and DC histories run continuously in every character. A
            // later mode selection therefore never revives stale filter state.
            const float bump = tapeBump.processSample (0, x) * 0.08f;
            const float tapeX = tapeLp.processSample (0, x + bump);
            std::array<float, modeCount> modeOutput {};
            for (int rawMode = 0; rawMode < modeCount; ++rawMode)
            {
                const auto character = (FinalCharacter) rawMode;
                const float modeInput = character == FinalCharacter::MagneticTape ? tapeX : x;
                const float shaped = shapeForMode (character, modeInput, drive, c);
                auto& dcState = dc[(size_t) c][(size_t) rawMode];
                auto& lastInput = previousInput[(size_t) c][(size_t) rawMode];
                const float dcBlocked = shaped - lastInput + 0.995f * dcState;
                lastInput = shaped;
                dcState = dcBlocked;
                modeOutput[(size_t) rawMode] = character == FinalCharacter::CleanSafety
                    ? shaped : dcBlocked;
            }

            float mixed = 0.0f;
            for (int modeIndex = 0; modeIndex < modeCount; ++modeIndex)
                mixed += modeOutput[(size_t) modeIndex] * weights[(size_t) modeIndex];
            d[i] = mixed * inverseWeightSum;
        }
    }
}
