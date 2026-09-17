#pragma once
#include <JuceHeader.h>
#include "AudioFileManager.h"
#include "MasteringProcessor.h"
#include "ParameterState.h"
#include "TrackMetadata.h"
#include "ExportFormat.h"
#include "LoudnessAnalyzer.h"

class OfflineRenderer
{
public:
    using ProgressCallback = std::function<void(float)>;
    using CancellationCheck = std::function<bool()>;

    /** Keep each codec's verification with its own delivery. Song.wav and
        Song.mp3 must not overwrite a shared Song.txt report. */
    static juce::File reportFileFor (const juce::File& audioFile)
    {
        return audioFile.getSiblingFile (audioFile.getFileName() + ".txt");
    }

    struct RenderStats
    {
        LoudnessAnalyzer::Result analysis;
        float limiterGainReductionDb = 0.0f;
    };

    /** Reopens the completed delivery, checks stereo/rate/duration and scans
        every decoded frame for non-finite samples and actual post-codec peaks.
        Runs only on a worker thread, with bounded auxiliary memory. */
    static bool verifyDelivery (const juce::File& file, ExportFormat::Kind format,
                                double expectedRate, int64_t expectedFrames,
                                LoudnessAnalyzer::Result& analysis,
                                juce::String& error,
                                ProgressCallback progress = nullptr,
                                CancellationCheck shouldCancel = nullptr);

    struct Options
    {
        juce::File outputFile;
        bool writeReport = true;
        juce::String presetName;
        TrackMetadata metadata;
        /** Delivered sample rate; 0 keeps the source rate. When this differs
            from the source, the master is converted with OfflineResampler and
            then re-limited at the delivery rate - conversion moves intersample
            peaks, so the ceiling must be enforced on what actually ships. */
        double targetSampleRate = 0.0;
        /** Delivery format and its quality (bit depth for WAV, kbps for the
            lossy formats). The renderer clamps the delivery rate to whatever
            the format can carry and gives lossy formats extra headroom, so
            these two fields can change the sample rate and the ceiling. */
        ExportFormat::Kind format = ExportFormat::Kind::wav;
        int qualityIndex = 0;
    };

    static bool render (const AudioFileManager& files,
                        ParameterState params,
                        const Options& opt,
                        juce::String& error,
                        ProgressCallback progress = nullptr,
                        CancellationCheck shouldCancel = nullptr);

    /** Export from immutable decoded audio without reloading/copying the song. */
    static bool render (const juce::AudioBuffer<float>& source,
                        double sampleRate,
                        const juce::String& sourceFileName,
                        ParameterState params,
                        const Options& opt,
                        juce::String& error,
                        ProgressCallback progress = nullptr,
                        CancellationCheck shouldCancel = nullptr);

    static bool resolveLoudness (const AudioFileManager& files,
                                 ParameterState& params,
                                 juce::String& error,
                                 CancellationCheck shouldCancel = nullptr);

    static bool resolveLoudness (const juce::AudioBuffer<float>& source,
                                 double sampleRate,
                                 ParameterState& params,
                                 juce::String& error,
                                 CancellationCheck shouldCancel = nullptr);

    static bool renderToBuffer (const juce::AudioBuffer<float>& source,
                                double sampleRate,
                                const ParameterState& params,
                                juce::AudioBuffer<float>& output,
                                RenderStats& stats,
                                ProgressCallback progress = nullptr,
                                CancellationCheck shouldCancel = nullptr);
};
