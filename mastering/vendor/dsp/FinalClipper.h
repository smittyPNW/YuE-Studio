#pragma once
#include <JuceHeader.h>
#include "audio/ParameterState.h"
#include "AntialiasedWaveshaper.h"
#include <array>
#include <atomic>

class FinalClipper
{
public:
    void prepare (double sampleRate);
    void reset();
    void setMode (FinalCharacter mode);
    void setDriveDb (float masterVolDb);
    void process (juce::AudioBuffer<float>& buffer);

private:
    static constexpr int modeCount = 5;
    std::atomic<int> targetMode { (int) FinalCharacter::AnalogConsole };
    bool hasProcessed = false;
    FinalCharacter activeTargetMode = FinalCharacter::AnalogConsole;
    float driveTarget = 1.0f;
    juce::SmoothedValue<float> driveLin;
    std::array<juce::SmoothedValue<float>, modeCount> modeWeights;
    juce::dsp::StateVariableTPTFilter<float> tapeLpL, tapeLpR, tapeBumpL, tapeBumpR;
    std::array<std::array<float, modeCount>, 2> dc {};
    std::array<std::array<float, modeCount>, 2> previousInput {};
    std::array<std::array<AntialiasedTanh, modeCount>, 2> shapers;

    float shapeForMode (FinalCharacter character, float x, float drive, int channel);
};
