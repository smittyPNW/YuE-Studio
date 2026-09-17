#pragma once

// JUCE's basic format registry has no Android AAC reader. Decode our M4A
// deliveries with the platform codec instead of silently skipping verification.
#if JUCE_ANDROID
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>

namespace AndroidDeliveryDecoder
{
template <typename Sink, typename Cancel>
bool visit (const juce::File& file, double expectedRate, Sink sink, Cancel cancel,
            juce::String& error)
{
    const auto fail = [&] (const char* message) { error = message; return false; };
    const int fd = ::open (file.getFullPathName().toRawUTF8(), O_RDONLY);
    if (fd < 0) return fail ("Could not reopen the AAC master for verification.");
    const auto closeFile = juce::ScopeGuard { [fd] { ::close (fd); } };
    auto* extractor = AMediaExtractor_new();
    if (extractor == nullptr) return fail ("Could not create the AAC verification reader.");
    const auto closeExtractor = juce::ScopeGuard { [extractor] { AMediaExtractor_delete (extractor); } };
    if (AMediaExtractor_setDataSourceFd (extractor, fd, 0, file.getSize()) != AMEDIA_OK)
        return fail ("The encoded AAC master is not a readable container.");

    AMediaFormat* format = nullptr;
    for (size_t track = 0; track < AMediaExtractor_getTrackCount (extractor); ++track)
    {
        auto* candidate = AMediaExtractor_getTrackFormat (extractor, track);
        const char* mime = nullptr;
        if (candidate != nullptr && AMediaFormat_getString (candidate, AMEDIAFORMAT_KEY_MIME, &mime)
            && std::strcmp (mime, "audio/mp4a-latm") == 0)
        {
            if (AMediaExtractor_selectTrack (extractor, track) == AMEDIA_OK)
                format = candidate;
            else
                AMediaFormat_delete (candidate);
            break;
        }
        if (candidate != nullptr) AMediaFormat_delete (candidate);
    }
    if (format == nullptr) return fail ("The master does not contain a readable AAC track.");
    const auto closeFormat = juce::ScopeGuard { [format] { AMediaFormat_delete (format); } };
    int32_t channels = 0, rate = 0;
    if (! AMediaFormat_getInt32 (format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channels)
        || ! AMediaFormat_getInt32 (format, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate)
        || channels != 2 || std::abs ((double) rate - expectedRate) > 0.5)
        return fail ("The AAC master has unexpected channels or sample rate.");

    // Prefer float, but Android AAC decoders may only expose signed PCM16.
    // In that case reject full-scale samples: they could hide a clipped codec
    // overshoot and must never produce a false ceiling PASS.
    AMediaFormat_setInt32 (format, "pcm-encoding", 4); // ENCODING_PCM_FLOAT
    AMediaFormat_setInt32 (format, "aac-drc-boost-level", 0);
    AMediaFormat_setInt32 (format, "aac-drc-cut-level", 0);
    AMediaFormat_setInt32 (format, "aac-drc-effect-type", -1);
    auto* codec = AMediaCodec_createDecoderByType ("audio/mp4a-latm");
    if (codec == nullptr) return fail ("This device could not start AAC verification.");
    bool started = false;
    const auto closeCodec = juce::ScopeGuard { [&]
    {
        if (started) AMediaCodec_stop (codec);
        AMediaCodec_delete (codec);
    } };
    if (AMediaCodec_configure (codec, format, nullptr, nullptr, 0) != AMEDIA_OK
        || AMediaCodec_start (codec) != AMEDIA_OK)
        return fail ("This device rejected the AAC verification format.");
    started = true;

    bool inputEnded = false, outputEnded = false, hasOutputFormat = false;
    int pcmEncoding = 2; // Android's default is ENCODING_PCM_16BIT
    int idlePolls = 0;
    juce::AudioBuffer<float> block (2, 2048);
    while (! outputEnded)
    {
        if (cancel()) return fail ("Export canceled. No partial files were kept.");
        bool advanced = false;
        if (! inputEnded)
        {
            const auto index = AMediaCodec_dequeueInputBuffer (codec, 1000);
            if (index >= 0)
            {
                size_t capacity = 0;
                auto* bytes = AMediaCodec_getInputBuffer (codec, (size_t) index, &capacity);
                if (bytes == nullptr || capacity == 0)
                    return fail ("The AAC verification input buffer is unavailable.");
                const auto count = AMediaExtractor_readSampleData (extractor, bytes, capacity);
                inputEnded = count < 0;
                const auto timestamp = inputEnded ? 0 : AMediaExtractor_getSampleTime (extractor);
                if (AMediaCodec_queueInputBuffer (codec, (size_t) index, 0,
                        inputEnded ? 0 : (size_t) count, (uint64_t) juce::jmax<int64_t> (0, timestamp),
                        inputEnded ? AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM : 0) != AMEDIA_OK)
                    return fail ("Could not decode all AAC packets.");
                if (! inputEnded) AMediaExtractor_advance (extractor);
                advanced = true;
            }
        }
        AMediaCodecBufferInfo info {};
        const auto index = AMediaCodec_dequeueOutputBuffer (codec, &info, 1000);
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
        {
            auto* outputFormat = AMediaCodec_getOutputFormat (codec);
            if (outputFormat == nullptr) return fail ("Missing AAC decoded format.");
            int32_t outputChannels = 0, outputRate = 0, encoding = 2;
            AMediaFormat_getInt32 (outputFormat, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &outputChannels);
            AMediaFormat_getInt32 (outputFormat, AMEDIAFORMAT_KEY_SAMPLE_RATE, &outputRate);
            AMediaFormat_getInt32 (outputFormat, "pcm-encoding", &encoding);
            AMediaFormat_delete (outputFormat);
            if (outputChannels != 2 || outputRate != rate || (encoding != 4 && encoding != 2))
                return fail ("This AAC decoder returned an unsupported audio format. Export WAV instead.");
            pcmEncoding = encoding;
            hasOutputFormat = true;
            advanced = true;
        }
        else if (index >= 0)
        {
            const auto release = juce::ScopeGuard { [&]
            { AMediaCodec_releaseOutputBuffer (codec, (size_t) index, false); } };
            size_t capacity = 0;
            const auto* bytes = AMediaCodec_getOutputBuffer (codec, (size_t) index, &capacity);
            if (info.size > 0)
            {
                const int sampleBytes = pcmEncoding == 4 ? 4 : 2;
                if (! hasOutputFormat || bytes == nullptr || info.offset < 0
                    || (size_t) info.offset > capacity || info.size < 0
                    || (size_t) info.size > capacity - (size_t) info.offset
                    || info.size % (2 * sampleBytes) != 0)
                    return fail ("The AAC decoder returned incomplete audio frames.");
                const int frames = info.size / (2 * sampleBytes);
                for (int start = 0; start < frames; start += 2048)
                {
                    const int count = juce::jmin (2048, frames - start);
                    for (int frame = 0; frame < count; ++frame)
                        for (int channel = 0; channel < 2; ++channel)
                        {
                            float value = 0.0f;
                            const auto* sample = bytes + info.offset
                                + ((start + frame) * 2 + channel) * sampleBytes;
                            if (pcmEncoding == 4)
                                std::memcpy (&value, sample, sizeof (float));
                            else
                            {
                                int16_t integer = 0;
                                std::memcpy (&integer, sample, sizeof (integer));
                                if (integer >= 32766 || integer <= -32767)
                                    return fail ("The decoded AAC reaches digital full scale. Lower the ceiling or export WAV.");
                                value = (float) integer / 32768.0f;
                            }
                            block.setSample (channel, frame, value);
                        }
                    if (! sink (block, count)) return false;
                }
            }
            outputEnded = (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0;
            advanced = true;
        }
        else if (index != AMEDIACODEC_INFO_TRY_AGAIN_LATER
                 && index != AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
            return fail ("The AAC decoder failed during export verification.");

        // No unbounded waits on a broken vendor codec; cancellation is checked
        // each pass and each dequeue waits at most one millisecond.
        idlePolls = advanced ? 0 : idlePolls + 1;
        if (idlePolls > 5000) return fail ("AAC verification timed out. Try WAV export.");
    }
    return true;
}
}
#endif
