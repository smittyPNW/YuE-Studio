#pragma once
#include <JuceHeader.h>
#include "audio/ParameterState.h"

class PresetManager
{
public:
    PresetManager();
    juce::StringArray getPresetNames() const;
    bool loadPreset (const juce::String& name, ParameterState& out);
    bool saveUserPreset (const juce::String& name, const ParameterState& state);
    juce::File getPresetsDir() const;
    juce::String getPresetDescription (const juce::String& name) const;
    int getBuiltInCount() const noexcept { return (int) builtIns.size(); }

private:
    struct BuiltIn
    {
        juce::String name;
        juce::String description;
        ParameterState state;
    };
    std::vector<BuiltIn> builtIns;
    void initBuiltIns();
};
