#pragma once

#include "LoudnessAnalyzer.h"
#include "ParameterState.h"

/** Conservative one-click policy that refuses to re-master already-hot material. */
class MasteringAdvisor
{
public:
    enum class Decision { humanize, preserveMastered, insufficientEvidence };

    static juce::String explanation (Decision decision);

    static Decision decide (const LoudnessAnalyzer::Result& analysis);
    static Decision applyEasyFix (ParameterState& state,
                                  const LoudnessAnalyzer::Result& analysis);
};
