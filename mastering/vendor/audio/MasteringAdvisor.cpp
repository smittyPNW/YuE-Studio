#include "MasteringAdvisor.h"
#include <cmath>

MasteringAdvisor::Decision MasteringAdvisor::decide (const LoudnessAnalyzer::Result& analysis)
{
    if (! std::isfinite (analysis.integratedLufs) || ! std::isfinite (analysis.truePeakDb)
        || ! std::isfinite (analysis.samplePeakDb) || analysis.integratedLufs <= -69.0f)
        return Decision::insufficientEvidence;

    // A near-full-scale transient does not prove that a song is mastered.
    // Require both high integrated loudness and a small peak-to-loudness ratio
    // before choosing conservative preservation. This is a density heuristic,
    // not a quality score or a claim to recognise professional mastering.
    const float peakToLoudness = analysis.truePeakDb - analysis.integratedLufs;
    return analysis.integratedLufs >= -12.5f && peakToLoudness <= 13.0f
        ? Decision::preserveMastered
        : Decision::humanize;
}

juce::String MasteringAdvisor::explanation (Decision decision)
{
    switch (decision)
    {
        case Decision::preserveMastered:
            return "This source is already loud and dense. Smart Master avoided adding more processing; fine-tune if needed.";
        case Decision::insufficientEvidence:
            return "Not enough measurable audio for Smart Master. Your settings are unchanged.";
        case Decision::humanize:
            return "Smart Master applied a gentle starting point. Compare Before/After; export uses measured loudness matching.";
    }
    return {};
}

MasteringAdvisor::Decision MasteringAdvisor::applyEasyFix (
    ParameterState& state, const LoudnessAnalyzer::Result& analysis)
{
    const auto decision = decide (analysis);
    if (decision == Decision::insufficientEvidence)
        return decision;
    if (decision == Decision::humanize)
    {
        state.applyQuickFixHumanize();

        // Smart Master is the one-click mastering path, not merely a character
        // preset. Give live audition a conservative loudness approximation and
        // mark the export for OfflineRenderer's measured two-pass match. The
        // renderer will replace this estimate with the exact post-chain gain,
        // while the true-peak limiter continues to enforce the chosen ceiling.
        const auto approximatePostChainLufs = analysis.integratedLufs + state.masterVolDb;
        const float previewGainBudget = state.ceilingDb + 3.0f
                                      - analysis.truePeakDb - state.masterVolDb;
        state.normalizeGainDb = juce::jlimit (-6.0f, 6.0f, juce::jmin (
            state.targetLufs - approximatePostChainLufs, previewGainBudget));
        state.normalizeActive = true;
        return decision;
    }

    const auto target = state.targetLufs;
    const auto ceiling = state.ceilingDb;
    const auto preset = state.loudnessPreset;
    const auto masteredPath = state.masteredPath;
    const auto loop = state.loopEnabled;
    state = ParameterState {};
    state.targetLufs = target;
    state.ceilingDb = ceiling;
    // Preservation means no DSP at export either; leave true-peak protection available
    // for the user to opt into deliberately, but do not silently turn down a finished master.
    state.useTruePeak = false;
    state.loudnessPreset = preset;
    state.masteredPath = masteredPath;
    state.loopEnabled = loop;
    return decision;
}
