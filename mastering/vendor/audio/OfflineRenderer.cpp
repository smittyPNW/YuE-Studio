#include "OfflineRenderer.h"
#include "LossyEncoders.h"
#include "dsp/OfflineResampler.h"
#include "StreamingMeterProcessor.h"
#include "AndroidDeliveryDecoder.h"
#include <cmath>

namespace
{
constexpr int offlineBlockSize = 2048;

bool completeWaveContainer (const juce::File& file)
{
    // JUCE's WAV reader can zero-fill a short data chunk, so a successful read
    // alone does not prove that the encoder wrote the tail of the song.
    juce::FileInputStream input (file);
    const auto size = file.getSize();
    if (! input.openedOk() || size < 12) return false;
    const auto riff = input.readInt();
    input.readInt();
    if ((riff != 0x46464952 && riff != 0x34364652) || input.readInt() != 0x45564157)
        return false;
    uint64_t largeDataSize = 0;
    while (input.getPosition() <= size - 8)
    {
        const auto chunk = input.readInt();
        uint64_t bytes = (uint32_t) input.readInt();
        const auto start = input.getPosition();
        if (chunk == 0x61746164 && bytes == 0xffffffffu && riff == 0x34364652)
            bytes = largeDataSize;
        if (bytes > (uint64_t) (size - start)) return false;
        if (chunk == 0x61746164) return bytes > 0;
        if (chunk == 0x34367364 && bytes >= 28) // RF64 ds64
        {
            input.readInt64();
            largeDataSize = (uint64_t) input.readInt64();
        }
        if (! input.setPosition (start + (int64_t) bytes + (int64_t) (bytes & 1)))
            return false;
    }
    return false;
}

bool canceled (const OfflineRenderer::CancellationCheck& shouldCancel)
{
    return shouldCancel && shouldCancel();
}

LoudnessAnalyzer::Result resultFromSnapshot (const MeterSnapshot& snapshot)
{
    LoudnessAnalyzer::Result result;
    if (snapshot.integratedValid)
        result.integratedLufs = snapshot.integratedLufs;
    result.truePeakDb = juce::jmax (snapshot.truePeakDbL, snapshot.truePeakDbR);
    result.samplePeakDb = juce::jmax (snapshot.samplePeakDbL, snapshot.samplePeakDbR);
    return result;
}

/** Runs the mastering chain with constant auxiliary memory. The sink receives
    latency-aligned output blocks and may write, copy, or discard them. */
bool processMasterBlocks (const juce::AudioBuffer<float>& source,
                          double sampleRate,
                          const ParameterState& params,
                          OfflineRenderer::RenderStats& stats,
                          const std::function<bool(const juce::AudioBuffer<float>&,
                                                   int, int)>& sink,
                          OfflineRenderer::ProgressCallback progress,
                          const OfflineRenderer::CancellationCheck& shouldCancel)
{
    if (source.getNumSamples() <= 0 || source.getNumChannels() <= 0
        || sampleRate <= 0.0 || canceled (shouldCancel))
        return false;

    MasteringProcessor processor;
    processor.prepare (sampleRate, offlineBlockSize);
    processor.setParameters (params);

    StreamingMeterProcessor meter;
    meter.prepare (sampleRate);

    const int sourceSamples = source.getNumSamples();
    const int latency = processor.getLatencySamples();
    const int64_t processingSamples = (int64_t) sourceSamples + latency;
    juce::AudioBuffer<float> block (2, offlineBlockSize);
    int outputSamples = 0;

    for (int64_t position = 0; position < processingSamples; position += offlineBlockSize)
    {
        if (canceled (shouldCancel))
            return false;

        const int count = (int) juce::jmin<int64_t> (offlineBlockSize,
                                                     processingSamples - position);
        block.setSize (2, count, false, false, true);
        block.clear();

        if (position < sourceSamples)
        {
            const int sourceCount = (int) juce::jmin<int64_t> (count,
                                                               sourceSamples - position);
            for (int channel = 0; channel < 2; ++channel)
            {
                const int sourceChannel = juce::jmin (channel, source.getNumChannels() - 1);
                block.copyFrom (channel, 0, source, sourceChannel, (int) position, sourceCount);
            }
        }

        processor.process (block, position, sourceSamples);

        const int validStart = (int) juce::jmax<int64_t> (0, (int64_t) latency - position);
        const int outputStart = (int) (position + validStart - latency);
        const int validCount = juce::jmin (count - validStart,
                                           sourceSamples - outputStart);
        if (validCount > 0)
        {
            meter.process (block.getReadPointer (0, validStart),
                           block.getReadPointer (1, validStart), validCount, 1);
            if (sink && ! sink (block, validStart, validCount))
                return false;
            outputSamples += validCount;
        }

        if (progress)
            progress ((float) juce::jmin<int64_t> (position + count, processingSamples)
                      / (float) processingSamples);
    }

    if (outputSamples != sourceSamples)
        return false;

    stats.analysis = resultFromSnapshot (meter.snapshot (0.0f, false));
    stats.limiterGainReductionDb = processor.getMaxLimiterGainReductionDb();
    return true;
}

bool analyzeProcessed (const juce::AudioBuffer<float>& source,
                       double sampleRate,
                       const ParameterState& params,
                       OfflineRenderer::RenderStats& stats,
                       OfflineRenderer::ProgressCallback progress,
                       const OfflineRenderer::CancellationCheck& shouldCancel)
{
    return processMasterBlocks (source, sampleRate, params, stats, {},
                                std::move (progress), shouldCancel);
}

bool resolveLoudnessInternal (const juce::AudioBuffer<float>& source,
                              double sampleRate,
                              ParameterState& params,
                              juce::String& error,
                              const OfflineRenderer::CancellationCheck& shouldCancel,
                              OfflineRenderer::ProgressCallback progress)
{
    if (canceled (shouldCancel))
    {
        error = "Loudness matching canceled.";
        return false;
    }
    if (source.getNumSamples() <= 0 || sampleRate <= 0.0)
    {
        error = "No valid audio is available for loudness matching.";
        return false;
    }
    if (! params.normalizeActive)
    {
        if (progress) progress (1.0f);
        return true;
    }

    constexpr int maximumAnalysisPasses = 4;
    auto passProgress = [&] (int pass)
    {
        return [progress, pass] (float value)
        {
            if (progress)
                progress (((float) pass + value) / (float) maximumAnalysisPasses);
        };
    };

    ParameterState baseParameters = params;
    baseParameters.normalizeActive = false;
    baseParameters.normalizeGainDb = 0.0f;
    baseParameters.useTruePeak = false;

    OfflineRenderer::RenderStats baseStats;
    if (! analyzeProcessed (source, sampleRate, baseParameters, baseStats,
                             passProgress (0), shouldCancel))
    {
        error = canceled (shouldCancel) ? "Loudness matching canceled."
                                        : "Could not analyze the processed signal for loudness matching.";
        return false;
    }

    const float desiredGain = params.targetLufs - baseStats.analysis.integratedLufs;
    constexpr float maxLimiterReductionDb = 3.0f;
    const float maximumSafeGain = params.useTruePeak
        ? params.ceilingDb + maxLimiterReductionDb - baseStats.analysis.truePeakDb
        : 24.0f;
    params.normalizeGainDb = juce::jlimit (-24.0f, 24.0f,
                                           juce::jmin (desiredGain, maximumSafeGain));

    // Correct for nonlinear stages while preserving the 3 dB limiter budget.
    for (int iteration = 0; iteration < 3; ++iteration)
    {
        OfflineRenderer::RenderStats candidateStats;
        if (! analyzeProcessed (source, sampleRate, params, candidateStats,
                                 passProgress (iteration + 1), shouldCancel))
        {
            error = canceled (shouldCancel) ? "Loudness matching canceled."
                                            : "Could not verify the loudness-matched signal.";
            return false;
        }
        const float correction = params.targetLufs - candidateStats.analysis.integratedLufs;
        if (std::abs (correction) <= 0.10f)
            break;
        const float nextGain = params.normalizeGainDb + correction;
        if (nextGain > maximumSafeGain + 0.001f)
            break;
        params.normalizeGainDb = juce::jlimit (-24.0f, 24.0f, nextGain);
    }

    if (progress) progress (1.0f);
    return true;
}
}

bool OfflineRenderer::verifyDelivery (const juce::File& file, ExportFormat::Kind format,
                                      double expectedRate, int64_t expectedFrames,
                                      LoudnessAnalyzer::Result& analysis,
                                      juce::String& error, ProgressCallback progress,
                                      CancellationCheck shouldCancel)
{
    error.clear();
    analysis = {};
    if (! std::isfinite (expectedRate) || expectedRate <= 0.0 || expectedFrames <= 0
        || ! file.existsAsFile())
    {
        error = "The completed master is missing or has an invalid audio format.";
        return false;
    }
    if (format == ExportFormat::Kind::wav && ! completeWaveContainer (file))
    {
        error = "The completed WAV is truncated or has an invalid data chunk.";
        return false;
    }
    const int64_t tolerance = ExportFormat::isLossless (format) ? 0 : 4096;
    StreamingMeterProcessor meter;
    meter.prepare (expectedRate);
    int64_t framesRead = 0;
    const auto accept = [&] (const juce::AudioBuffer<float>& block, int count)
    {
        if (canceled (shouldCancel))
        {
            error = "Export canceled. No partial files were kept.";
            return false;
        }
        for (int channel = 0; channel < 2; ++channel)
            for (int frame = 0; frame < count; ++frame)
                if (! std::isfinite (block.getSample (channel, frame)))
                {
                    error = "The completed master contains invalid audio samples.";
                    return false;
                }
        framesRead += count;
        if (framesRead > expectedFrames + tolerance)
        {
            error = "The completed master has an unexpected duration.";
            return false;
        }
        meter.process (block.getReadPointer (0), block.getReadPointer (1), count, 1);
        if (progress) progress ((float) juce::jmin (1.0, (double) framesRead / (double) expectedFrames));
        return true;
    };

   #if JUCE_ANDROID
    if (format == ExportFormat::Kind::m4a)
    {
        if (! AndroidDeliveryDecoder::visit (file, expectedRate, accept,
                                            [&] { return canceled (shouldCancel); }, error))
            return false;
    }
    else
   #endif
    {
        juce::AudioFormatManager formats;
        formats.registerBasicFormats();
        std::unique_ptr<juce::AudioFormatReader> reader (formats.createReaderFor (file));
        if (reader == nullptr)
        {
            error = "The completed master could not be decoded for verification.";
            return false;
        }
        if (reader->numChannels != 2 || ! std::isfinite (reader->sampleRate)
            || std::abs (reader->sampleRate - expectedRate) > 0.5
            || reader->lengthInSamples <= 0
            || std::abs (reader->lengthInSamples - expectedFrames) > tolerance)
        {
            error = "The completed master has unexpected channels, sample rate, or duration.";
            return false;
        }
        juce::AudioBuffer<float> block (2, offlineBlockSize);
        while (framesRead < reader->lengthInSamples)
        {
            const int count = (int) juce::jmin<int64_t> (offlineBlockSize,
                                                        reader->lengthInSamples - framesRead);
            if (! reader->read (&block, 0, count, framesRead, true, true))
            {
                error = "The completed master could not be decoded completely.";
                return false;
            }
            if (! accept (block, count)) return false;
        }
    }
    if (framesRead <= 0 || std::abs (framesRead - expectedFrames) > tolerance)
    {
        error = "The completed master has an unexpected duration.";
        return false;
    }
    // Flush the true-peak FIR tail as well as measuring the last input sample.
    std::array<float, 64> tail {};
    meter.process (tail.data(), tail.data(), (int) tail.size(), 1);
    analysis = resultFromSnapshot (meter.snapshot (0.0f, false));
    return true;
}

bool OfflineRenderer::renderToBuffer (const juce::AudioBuffer<float>& source,
                                      double sampleRate,
                                      const ParameterState& params,
                                      juce::AudioBuffer<float>& output,
                                      RenderStats& stats,
                                      ProgressCallback progress,
                                      CancellationCheck shouldCancel)
{
    output.setSize (2, source.getNumSamples(), false, false, true);
    output.clear();
    int writePosition = 0;
    const bool rendered = processMasterBlocks (
        source, sampleRate, params, stats,
        [&] (const juce::AudioBuffer<float>& block, int start, int count)
        {
            for (int channel = 0; channel < 2; ++channel)
                output.copyFrom (channel, writePosition, block, channel, start, count);
            writePosition += count;
            return true;
        }, std::move (progress), shouldCancel);

    if (! rendered || writePosition != source.getNumSamples())
    {
        output.setSize (0, 0);
        return false;
    }
    return true;
}

bool OfflineRenderer::resolveLoudness (const AudioFileManager& files,
                                       ParameterState& params,
                                       juce::String& error,
                                       CancellationCheck shouldCancel)
{
    if (! files.hasAudio())
    {
        error = "Add a music file first, then match its loudness.";
        return false;
    }
    return resolveLoudnessInternal (files.getBuffer(), files.getSampleRate(), params,
                                    error, shouldCancel, {});
}

bool OfflineRenderer::resolveLoudness (const juce::AudioBuffer<float>& source,
                                       double sampleRate,
                                       ParameterState& params,
                                       juce::String& error,
                                       CancellationCheck shouldCancel)
{
    return resolveLoudnessInternal (source, sampleRate, params, error,
                                    shouldCancel, {});
}

bool OfflineRenderer::render (const AudioFileManager& files,
                              ParameterState params,
                              const Options& options,
                              juce::String& error,
                              ProgressCallback progress,
                              CancellationCheck shouldCancel)
{
    if (! files.hasAudio())
    {
        error = "Add a music file first, then export your master.";
        return false;
    }
    return render (files.getBuffer(), files.getSampleRate(), files.getFileName(),
                   params, options, error, std::move (progress),
                   std::move (shouldCancel));
}

bool OfflineRenderer::render (const juce::AudioBuffer<float>& source,
                              double sampleRate,
                              const juce::String& sourceFileName,
                              ParameterState params,
                              const Options& options,
                              juce::String& error,
                              ProgressCallback progress,
                              CancellationCheck shouldCancel)
{
    if (source.getNumSamples() <= 0 || sampleRate <= 0.0)
    {
        error = "Add a music file first, then export your master.";
        return false;
    }

    const float requestedCeilingDb = params.ceilingDb;
    // Lossy delivery gets extra headroom BEFORE anything reads the ceiling -
    // normalisation gain, the delivery limiter and the verification threshold
    // all derive from it, so lowering it here keeps those three consistent.
    // A codec reconstructs a waveform that can sit above the peak we measured
    // pre-encode, so holding a -1.0 dBTP master at exactly -1.0 dBTP through
    // an MP3 encode is a promise Studio Mastering cannot keep.
    params.ceilingDb -= ExportFormat::extraHeadroomDb (options.format);

    // Never truncate an existing master until its replacement has been fully
    // encoded and checked. TemporaryFile keeps the staging file on the same
    // volume and cleans up canceled/failed renders, without touching the target.
    const juce::TemporaryFile stagedAudio (options.outputFile, juce::TemporaryFile::useHiddenFile);
    const juce::TemporaryFile stagedReport (reportFileFor (options.outputFile),
                                           juce::TemporaryFile::useHiddenFile);
    const auto& outputFile = stagedAudio.getFile();
    const auto& reportFile = stagedReport.getFile();
    const auto removePartialFiles = [&]
    {
        outputFile.deleteFile();
        reportFile.deleteFile();
    };
    const auto failIfCanceled = [&]
    {
        if (! canceled (shouldCancel))
            return false;
        removePartialFiles();
        error = "Export canceled. No partial files were kept.";
        return true;
    };

    if (failIfCanceled())
        return false;

    if (params.normalizeActive
        && ! resolveLoudnessInternal (
            source, sampleRate, params, error, shouldCancel,
            [progress] (float value) { if (progress) progress (value * 0.55f); }))
    {
        if (canceled (shouldCancel))
            failIfCanceled();
        return false;
    }
    if (! params.normalizeActive && progress)
        progress (0.10f);

    juce::StringPairArray metadata = options.metadata.toWavMetadata();
    juce::StringPairArray cleanMetadata;
    for (int i = 0; i < metadata.size(); ++i)
        if (! MetadataCleaner::looksLikeAiJunk (metadata.getAllValues()[i]))
            cleanMetadata.set (metadata.getAllKeys()[i], metadata.getAllValues()[i]);

    // Delivery rate: 0 (or a matching rate) keeps the source untouched. The
    // format gets the last word - MP3 cannot encode above 48 kHz, so a 96 kHz
    // master is stepped down here rather than handed to an encoder that would
    // fail or silently mangle it.
    const double requestedRate =
        ExportFormat::resolveDeliveryRate (options.format, options.targetSampleRate, sampleRate);
    const bool convertRate = std::abs (requestedRate - sampleRate) > 1.0e-6;
    const double deliveredRate = convertRate ? requestedRate : sampleRate;

    std::unique_ptr<juce::AudioFormatWriter> writer;
    if (options.format == ExportFormat::Kind::wav)
    {
        juce::WavAudioFormat wav;
        if (outputFile.existsAsFile() && ! outputFile.deleteFile())
        {
            error = "Could not replace the existing output file.";
            return false;
        }
        std::unique_ptr<juce::FileOutputStream> stream (outputFile.createOutputStream());
        if (stream == nullptr)
        {
            error = "Could not create the master file. Pick another folder or name.";
            return false;
        }
        const int bits = ExportFormat::quality (options.format, options.qualityIndex).value;
        writer.reset (wav.createWriterFor (stream.get(), deliveredRate, 2, bits,
                                           cleanMetadata, 0));
        if (writer == nullptr)
        {
            stream.reset();
            removePartialFiles();
            error = "Could not create the " + juce::String (bits) + "-bit WAV writer.";
            return false;
        }
        stream.release();
    }
    else
    {
        writer = LossyEncoders::createWriter (outputFile, options.format,
                                              options.qualityIndex, deliveredRate,
                                              options.metadata, error);
        if (writer == nullptr)
        {
            removePartialFiles();
            if (error.isEmpty())
                error = "Could not create the " + ExportFormat::formatName (options.format)
                      + " encoder.";
            return false;
        }
    }

    RenderStats stats;
    bool writeFailed = false;
    const float finalPassStart = params.normalizeActive ? 0.55f : 0.10f;
    // Leave room in the progress budget for conversion when one is scheduled.
    const float renderShare = convertRate ? 0.75f : 1.0f;

    // Unchanged rate: stream blocks straight to disk (unchanged behaviour).
    // Changed rate: collect the mastered audio, convert it, then re-limit at
    // the delivery rate before writing, because conversion relocates
    // intersample peaks and the ceiling must hold for the file that ships.
    juce::AudioBuffer<float> mastered;
    int masteredSamples = 0;
    if (convertRate)
        mastered.setSize (2, source.getNumSamples(), false, true, false);

    const bool rendered = processMasterBlocks (
        source, sampleRate, params, stats,
        [&] (const juce::AudioBuffer<float>& block, int start, int count)
        {
            if (! convertRate)
            {
                if (writer->writeFromAudioSampleBuffer (block, start, count))
                    return true;
                writeFailed = true;
                return false;
            }
            if (masteredSamples + count > mastered.getNumSamples())
                mastered.setSize (2, masteredSamples + count, true, true, false);
            for (int channel = 0; channel < 2; ++channel)
                mastered.copyFrom (channel, masteredSamples,
                                   block, juce::jmin (channel, block.getNumChannels() - 1),
                                   start, count);
            masteredSamples += count;
            return true;
        },
        [progress, finalPassStart, renderShare] (float value)
        {
            if (progress)
                progress (finalPassStart + value * (0.90f - finalPassStart) * renderShare);
        }, shouldCancel);

    if (rendered && convertRate)
    {
        mastered.setSize (2, masteredSamples, true, true, false);
        juce::AudioBuffer<float> converted;
        if (! OfflineResampler::convert (mastered, sampleRate, deliveredRate, converted))
        {
            writer.reset();
            removePartialFiles();
            error = "Could not convert the master to the selected sample rate.";
            return false;
        }
        if (progress)
            progress (0.88f);

        // Re-enforce the ceiling at the delivery rate.
        if (params.useTruePeak)
        {
            TruePeakLimiter deliveryLimiter;
            deliveryLimiter.prepare (deliveredRate, 2, juce::jmax (1, converted.getNumSamples()));
            deliveryLimiter.setCeilingDbTP (params.ceilingDb);
            deliveryLimiter.setEnabled (true);
            deliveryLimiter.process (converted);
            stats.limiterGainReductionDb = juce::jmax (stats.limiterGainReductionDb,
                                                       deliveryLimiter.getMaxGainReductionDb());
        }

        // Re-measure what actually ships so the report describes the file.
        stats.analysis = LoudnessAnalyzer::analyze (converted, deliveredRate);

        if (! writer->writeFromAudioSampleBuffer (converted, 0, converted.getNumSamples()))
            writeFailed = true;
    }
    writer.reset();

    if (! rendered || writeFailed)
    {
        removePartialFiles();
        error = canceled (shouldCancel) ? "Export canceled. No partial files were kept."
              : writeFailed ? "The master could not be written completely."
                            : "Could not render the master.";
        return false;
    }

    if (failIfCanceled())
        return false;

    const int64_t expectedFrames = convertRate
        ? OfflineResampler::outputLengthFor (source.getNumSamples(), sampleRate, deliveredRate)
        : source.getNumSamples();
    if (! verifyDelivery (outputFile, options.format, deliveredRate, expectedFrames,
                          stats.analysis, error,
                          [progress] (float value) { if (progress) progress (0.90f + 0.09f * value); },
                          shouldCancel))
    {
        removePartialFiles();
        return false;
    }
    if (params.useTruePeak && stats.analysis.truePeakDb > requestedCeilingDb + 0.05f)
    {
        removePartialFiles();
        error = "The encoded master exceeds your true-peak ceiling ("
              + juce::String (stats.analysis.truePeakDb, 2)
              + " dBTP). Lower the ceiling or choose WAV and export again.";
        return false;
    }

    if (options.writeReport)
    {
        const float targetDeviation = stats.analysis.integratedLufs - params.targetLufs;
        const bool targetPass = std::abs (targetDeviation) <= 0.2f;
        const bool truePeakPass = stats.analysis.truePeakDb <= requestedCeilingDb + 0.05f;
        const auto truePeakResult = ! params.useTruePeak
            ? juce::String ("TARGET NOT ENFORCED - 0.0 dBTP emergency safety active")
            : juce::String (truePeakPass ? "PASS" : "FAIL");
        juce::String report;
        report << "Studio Mastering Export Report\n"
               << "Title: " << options.metadata.title << "\n"
               << "Artist: " << options.metadata.artist << "\n"
               << "Album: " << options.metadata.album << "\n"
               << "Source file: " << sourceFileName << "\n"
               << "Output: " << options.outputFile.getFileName() << "\n"
               << "Verification: decoded completed file; stereo, sample rate, duration, finite samples checked\n"
               << "Delivered format: "
               << ExportFormat::describe (options.format, options.qualityIndex) << " @ "
               << juce::String (deliveredRate / 1000.0, 1) << " kHz"
               << (convertRate ? juce::String (" (converted from ")
                                 + juce::String (sampleRate / 1000.0, 1) + " kHz)"
                               : juce::String (" (source rate)")) << "\n"
               << "Preset: " << options.presetName << "\n"
               << "Target LUFS: " << juce::String (params.targetLufs, 1) << "\n"
               << "Integrated LUFS: " << juce::String (stats.analysis.integratedLufs, 1) << "\n"
               << "Loudness Match: " << (params.normalizeActive ? "Applied" : "Not applied") << "\n"
               << "Target Deviation: " << (targetDeviation >= 0.0f ? "+" : "")
               << juce::String (targetDeviation, 1) << " LU\n"
               << "Target Result: " << (targetPass ? "PASS" : "ATTENTION - use Match Level to hit the selected target") << "\n"
               << (ExportFormat::isLossless (options.format) ? juce::String()
                     : "Lossy headroom: ceiling lowered "
                       + juce::String (ExportFormat::extraHeadroomDb (options.format), 1)
                       + " dB before encoding; decoded peaks verified separately\n")
               << "Requested ceiling: " << juce::String (requestedCeilingDb, 2) << " dBTP\n"
               << "True Peak: " << juce::String (stats.analysis.truePeakDb, 1) << " dBTP\n"
               << "True-Peak Result: " << truePeakResult << "\n"
               << "Sample Peak: " << juce::String (stats.analysis.samplePeakDb, 1) << " dBFS\n"
               << "Limiter max gain reduction: " << juce::String (stats.limiterGainReductionDb, 1) << " dB\n"
               << "Final Character: " << toDisplayName (params.finalCharacter) << "\n"
               << "Date: " << juce::Time::getCurrentTime().toString (true, true) << "\n"
               << "Note: report measurements describe decoded delivery audio, not pre-encode PCM.\n";
        if (! reportFile.replaceWithText (report))
        {
            removePartialFiles();
            error = "The master and its verification report could not be saved completely. No partial files were kept.";
            return false;
        }
    }
    if (failIfCanceled())
        return false;
    if (! stagedAudio.overwriteTargetFileWithTemporary())
    {
        error = "The verified master could not replace the destination file. Choose another location.";
        return false;
    }
    if (options.writeReport && ! stagedReport.overwriteTargetFileWithTemporary())
    {
        // The audio is complete and verified: never delete it because a sidecar
        // failed. Report this distinctly so the musician knows what was saved.
        error = "The verified master was saved, but its text report could not be saved. Audio: "
              + options.outputFile.getFullPathName();
        return false;
    }
    if (progress) progress (1.0f);
    return true;
}
