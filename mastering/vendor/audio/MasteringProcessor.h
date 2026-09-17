#pragma once
#include <JuceHeader.h>
#include "ParameterState.h"
#include "dsp/EqProcessor.h"
#include "dsp/StereoTools.h"
#include "dsp/TransientShaper.h"
#include "dsp/PhaseCoherentMultiband.h"
#include "dsp/DeChirp.h"
#include "dsp/DeEsser.h"
#include "dsp/Saturation.h"
#include "dsp/Exciter.h"
#include "dsp/TapeHiss.h"
#include "dsp/FinalClipper.h"
#include "dsp/TruePeakLimiter.h"
#include "dsp/Polyphase4x.h"

/** Full mastering chain in spec order. */
class MasteringProcessor
{
public:
    /** Select the zero-latency, CPU-bounded audition path. Offline rendering
        deliberately leaves this disabled and retains the full FIR multiband
        and oversampled true-peak limiter. Set before prepare(). */
    void setRealtimePreviewMode (bool shouldUsePreview) { realtimePreviewMode = shouldUsePreview; }
    bool isRealtimePreviewMode() const { return realtimePreviewMode; }
    void prepare (double sampleRate, int samplesPerBlock);
    void reset();
    void setParameters (const ParameterState& state);
    void process (juce::AudioBuffer<float>& buffer, int64_t absoluteSamplePos, int64_t totalSamples);

    EqProcessor& getEq() { return eq; }
    float getPeakL() const { return peakL; }
    float getPeakR() const { return peakR; }
    const ParameterState& getParameters() const { return params; }
    int getLatencySamples() const
    {
        return realtimePreviewMode ? 0
                                   : multiband.getLatencySamples() + truePeakLimiter.getLatencySamples();
    }
    float getMaxLimiterGainReductionDb() const { return truePeakLimiter.getMaxGainReductionDb(); }
    float getCurrentLimiterGainReductionDb() const { return truePeakLimiter.getLastBlockMaxGainReductionDb(); }
    int getCurrentLimiterGainReductionSampleOffset() const
    {
        return truePeakLimiter.getLastBlockMaxGainReductionSampleOffset();
    }
    const float* getLimiterGainReductionTrace() const
    {
        return truePeakLimiter.getLastGainReductionTrace();
    }
    int getLimiterGainReductionTraceSamples() const
    {
        return truePeakLimiter.getLastGainReductionTraceSamples();
    }

private:
    ParameterState params;
    double sr = 44100.0;

    EqProcessor eq;
    StereoTools stereo;
    TransientShaper punch;
    PhaseCoherentMultiband multiband;
    DeChirp deChirp;
    DeEsser deEsser;
    WarmthSaturator warmth;
    AnalogLifeSaturator analogLife;
    Exciter warmExc, airExc;
    TapeHiss hiss;
    FinalClipper clipper;
    TruePeakLimiter truePeakLimiter;

    // Tone shelves — dual-bank with a 15 ms crossfade (same discipline as
    // EqProcessor) so live drags of Bass/Mid/Treble/Mud never hard-swap IIR
    // coefficients. These four stages run in BOTH preview and export, so a
    // coefficient swap here was audible as a click in live audition.
    // Layout: [bank][stage: bass, mud, mid, treble][channel]
    juce::dsp::IIR::Filter<float> tone[2][4][2];
    int toneCurrentBank = 0;
    int toneTransitionRemaining = 0;
    int toneTransitionLength = 662;          // 15 ms at the prepared rate
    bool toneNeutral[2] { true, true };
    bool toneInitialized = false;
    std::array<float, 4> toneLastRequested { -1.0f, -1.0f, -1.0f, -1.0f };
    // Drags retarget faster than a fade completes. A retarget that lands
    // mid-transition is queued (latest wins) and starts when the in-flight
    // fade finishes — restarting the fade would reset the incoming bank's
    // state while it already carries audible weight.
    bool tonePendingValid = false;
    std::array<float, 4> tonePending {};

    // Preview limiter detection at 4x reconstruction (shared Polyphase4x
    // kernel) so live audition catches the same intersample overs the export
    // limiter would — detection only, still zero latency.
    Polyphase4x::Phases previewTpPhases {};
    std::array<std::array<double, Polyphase4x::tapsPerPhase>, 2> previewTpHistory {};
    int previewTpWriteIndex = 0;

    float peakL = 0, peakR = 0;
    juce::SmoothedValue<float> normalizeGain;
    bool parametersInitialized = false;
    bool realtimePreviewMode = false;
    float previewLimiterEnvelope = 1.0f;
    float previewLimiterRelease = 0.999f;
    juce::SmoothedValue<float> previewDriveGain;
    // Glided (35 ms) like the drive: a hard-assigned colour blend stepped the
    // preview character audibly when dragging Warmth/Exciter/Hiss live.
    juce::SmoothedValue<float> previewColourAmount;
    FinalCharacter previewCharacter = FinalCharacter::CleanSafety;
    FinalCharacter previewPreviousCharacter = FinalCharacter::CleanSafety;
    int previewCharacterFadeRemaining = 0;
    std::array<float, 2> previewDc {};
    std::array<float, 2> previewPreviousOutput {};

    void applyFades (juce::AudioBuffer<float>& buffer, int64_t absPos, int64_t totalSamples);
    void applyTone (juce::AudioBuffer<float>& buffer);
    void applyPreviewCharacter (juce::AudioBuffer<float>& buffer);
    void applyPreviewLimiter (juce::AudioBuffer<float>& buffer);
    void updateToneCoeffs();
    void installToneBank (int bank, const std::array<float, 4>& toneParams);
    void beginToneTransition (const std::array<float, 4>& toneParams);
    float processToneBankSample (int bank, int channel, float input);
};
