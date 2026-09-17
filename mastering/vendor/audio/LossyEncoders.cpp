/*  CoreAudio headers MUST come before any JUCE header.

    <JuceHeader.h> does `using namespace juce`, which puts juce::AudioBuffer
    and juce::Point into the global namespace. CoreAudioBaseTypes.h and
    MacTypes.h then declare their own AudioBuffer and Point, and the SDK
    headers fail to parse against their own types. Including them first, and
    qualifying CoreAudio's types with `::` below, keeps both worlds intact.
    (Same trap as the StoreKit/Security .mm files - see the note in
    Source/store.)
*/
#if defined (RESOUL_AAC_AVAILABLE) && RESOUL_AAC_AVAILABLE
 #include <AudioToolbox/AudioToolbox.h>
 #define RESOUL_HAS_COREAUDIO_AAC 1
#else
 #define RESOUL_HAS_COREAUDIO_AAC 0
#endif

#if defined (RESOUL_ANDROID_AAC_AVAILABLE) && RESOUL_ANDROID_AAC_AVAILABLE
 #include <media/NdkMediaCodec.h>
 #include <media/NdkMediaFormat.h>
 #include <media/NdkMediaMuxer.h>
 #include <fcntl.h>
 #include <unistd.h>
 #define RESOUL_HAS_ANDROID_AAC 1
#else
 #define RESOUL_HAS_ANDROID_AAC 0
#endif

#include "LossyEncoders.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

/*  Availability is decided by the BUILD, not by the platform macros: the
    vendored LAME slices are linked only where CMake wires them in, so keying
    off JUCE_IOS would break any target that compiles this file without the
    library (the test lanes do exactly that).
*/
#if defined (RESOUL_LAME_AVAILABLE) && RESOUL_LAME_AVAILABLE
 #include <lame.h>
 #define RESOUL_HAS_LAME 1
#else
 #define RESOUL_HAS_LAME 0
#endif

namespace LossyEncoders
{
namespace
{
#if RESOUL_HAS_LAME
/*  MP3 through LAME.

    LAME is fed de-interleaved float channels and returns encoded bytes we
    push straight to the stream. The ID3v2 tag is emitted by LAME itself with
    the first encode call, which is why the tag fields are set before
    lame_init_params.
*/
class Mp3Writer final : public juce::AudioFormatWriter
{
public:
    Mp3Writer (juce::FileOutputStream* streamToOwn, lame_global_flags* flagsToOwn,
               double rate, int kbps)
        : juce::AudioFormatWriter (streamToOwn, "MP3", rate, 2, 16),
          flags (flagsToOwn),
          bitrate (kbps)
    {
        // Take float samples straight from the render loop; letting JUCE
        // convert to fixed point first would quantise before the encoder.
        usesFloatingPointData = true;
    }

    ~Mp3Writer() override
    {
        if (flags == nullptr)
            return;
        // Whatever happens, LAME must be closed exactly once. The final frames
        // only exist after a flush, so a writer destroyed without flushing
        // would silently truncate the tail of the song.
        flushEncoder();
        lame_close (flags);
        flags = nullptr;
    }

    bool write (const int** samplesToWrite, int numSamples) override
    {
        if (flags == nullptr || output == nullptr)
            return false;
        if (numSamples <= 0)
            return true;
        if (samplesToWrite == nullptr || samplesToWrite[0] == nullptr)
            return false;

        // usesFloatingPointData means these int* are really float*.
        const auto* left  = reinterpret_cast<const float*> (samplesToWrite[0]);
        const auto* right = samplesToWrite[1] != nullptr
                              ? reinterpret_cast<const float*> (samplesToWrite[1])
                              : left;   // mono source feeds both sides

        // LAME's documented worst case for the output buffer.
        encoded.ensureSize ((size_t) (1.25 * numSamples) + 7200);
        const int produced = lame_encode_buffer_ieee_float (
            flags, left, right, numSamples,
            static_cast<unsigned char*> (encoded.getData()), (int) encoded.getSize());
        if (produced < 0)
            return false;
        return produced == 0 || output->write (encoded.getData(), (size_t) produced);
    }

    bool flush() override
    {
        if (output == nullptr)
            return false;
        output->flush();   // juce::OutputStream::flush() returns void
        return true;
    }

    int getBitrate() const noexcept { return bitrate; }

private:
    void flushEncoder()
    {
        if (output == nullptr)
            return;
        encoded.ensureSize (7200);
        const int produced = lame_encode_flush (
            flags, static_cast<unsigned char*> (encoded.getData()), (int) encoded.getSize());
        if (produced > 0)
            output->write (encoded.getData(), (size_t) produced);
        output->flush();
    }

    lame_global_flags* flags = nullptr;
    int bitrate = 0;
    juce::MemoryBlock encoded;
};
#endif

#if RESOUL_HAS_COREAUDIO_AAC
/*  AAC through CoreAudio.

    ExtAudioFile owns the output file, so this writer passes no OutputStream
    to the base class (its destructor deletes a null pointer harmlessly).
*/
class AacWriter final : public juce::AudioFormatWriter
{
public:
    AacWriter (ExtAudioFileRef fileRef, double rate)
        : juce::AudioFormatWriter (nullptr, "M4A", rate, 2, 16),
          file (fileRef)
    {
        usesFloatingPointData = true;
    }

    ~AacWriter() override
    {
        if (file != nullptr)
        {
            ExtAudioFileDispose (file);
            file = nullptr;
        }
    }

    bool write (const int** samplesToWrite, int numSamples) override
    {
        if (file == nullptr)
            return false;
        if (numSamples <= 0)
            return true;
        if (samplesToWrite == nullptr || samplesToWrite[0] == nullptr)
            return false;

        const auto* left  = reinterpret_cast<const float*> (samplesToWrite[0]);
        const auto* right = samplesToWrite[1] != nullptr
                              ? reinterpret_cast<const float*> (samplesToWrite[1])
                              : left;

        // Non-interleaved float32, matching the client format set at creation.
        std::array<std::byte, sizeof (::AudioBufferList) + sizeof (::AudioBuffer)> storage {};
        auto* list = reinterpret_cast<::AudioBufferList*> (storage.data());
        list->mNumberBuffers = 2;
        list->mBuffers[0].mNumberChannels = 1;
        list->mBuffers[0].mDataByteSize = (UInt32) numSamples * sizeof (float);
        list->mBuffers[0].mData = const_cast<float*> (left);
        list->mBuffers[1].mNumberChannels = 1;
        list->mBuffers[1].mDataByteSize = (UInt32) numSamples * sizeof (float);
        list->mBuffers[1].mData = const_cast<float*> (right);

        return ExtAudioFileWrite (file, (UInt32) numSamples, list) == noErr;
    }

private:
    ExtAudioFileRef file = nullptr;
};

std::unique_ptr<juce::AudioFormatWriter> createAac (const juce::File& outputFile,
                                                    int kbps, double sampleRate,
                                                    juce::String& error)
{
    // Built straight from the UTF-8 path: going via CFStringCreate would leak
    // the intermediate string, and juce::CFUniquePtr is not public API.
    const auto path = outputFile.getFullPathName();
    const auto* utf8 = path.toRawUTF8();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation (
        kCFAllocatorDefault, reinterpret_cast<const UInt8*> (utf8),
        (CFIndex) std::strlen (utf8), false);
    if (url == nullptr)
    {
        error = "Could not address the output file for AAC encoding.";
        return {};
    }
    const juce::ScopeGuard releaseUrl { [url] { CFRelease (url); } };

    AudioStreamBasicDescription destination {};
    destination.mFormatID = kAudioFormatMPEG4AAC;
    destination.mSampleRate = sampleRate;
    destination.mChannelsPerFrame = 2;

    ExtAudioFileRef file = nullptr;
    if (ExtAudioFileCreateWithURL (url, kAudioFileM4AType, &destination, nullptr,
                                   kAudioFileFlags_EraseFile, &file) != noErr || file == nullptr)
    {
        error = "Could not start the AAC encoder.";
        return {};
    }

    AudioStreamBasicDescription client {};
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved;
    client.mSampleRate = sampleRate;
    client.mChannelsPerFrame = 2;
    client.mBitsPerChannel = 32;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = sizeof (float);
    client.mBytesPerPacket = sizeof (float);
    if (ExtAudioFileSetProperty (file, kExtAudioFileProperty_ClientDataFormat,
                                 sizeof (client), &client) != noErr)
    {
        ExtAudioFileDispose (file);
        outputFile.deleteFile();
        error = "The AAC encoder rejected the audio format.";
        return {};
    }

    // Bitrate lives on the underlying converter, not the file.
    AudioConverterRef converter = nullptr;
    UInt32 size = sizeof (converter);
    if (ExtAudioFileGetProperty (file, kExtAudioFileProperty_AudioConverter, &size,
                                 &converter) == noErr && converter != nullptr)
    {
        UInt32 bitsPerSecond = (UInt32) kbps * 1000;
        AudioConverterSetProperty (converter, kAudioConverterEncodeBitRate,
                                   sizeof (bitsPerSecond), &bitsPerSecond);
        // Re-setting ConverterConfig is what makes ExtAudioFile notice the
        // change. Without this the bitrate silently stays at the default and
        // every file comes out the same size regardless of the choice.
        CFArrayRef nullConfig = nullptr;
        ExtAudioFileSetProperty (file, kExtAudioFileProperty_ConverterConfig,
                                 sizeof (nullConfig), &nullConfig);
    }

    return std::make_unique<AacWriter> (file, sampleRate);
}
#endif

#if RESOUL_HAS_ANDROID_AAC
/*  AAC through Android's platform MediaCodec and MediaMuxer.

    The codec accepts interleaved signed 16-bit PCM and emits AAC-LC access
    units. MediaMuxer wraps those units in the same .m4a/MPEG-4 container the
    Apple implementation produces. Encoding stays entirely off the realtime
    playback thread because OfflineRenderer owns this writer on its render
    worker.
*/
class AndroidAacWriter final : public juce::AudioFormatWriter
{
public:
    AndroidAacWriter (AMediaCodec* codecToOwn, AMediaMuxer* muxerToOwn,
                      int descriptorToOwn, double rate)
        : juce::AudioFormatWriter (nullptr, "M4A", rate, 2, 16),
          codec (codecToOwn), muxer (muxerToOwn), descriptor (descriptorToOwn)
    {
        usesFloatingPointData = true;
    }

    ~AndroidAacWriter() override
    {
        finish();

        if (codec != nullptr)
        {
            AMediaCodec_stop (codec);
            AMediaCodec_delete (codec);
            codec = nullptr;
        }
        if (muxer != nullptr)
        {
            if (muxerStarted)
                AMediaMuxer_stop (muxer);
            AMediaMuxer_delete (muxer);
            muxer = nullptr;
        }
        if (descriptor >= 0)
        {
            ::close (descriptor);
            descriptor = -1;
        }
    }

    bool write (const int** samplesToWrite, int numSamples) override
    {
        if (! healthy || codec == nullptr || samplesToWrite == nullptr
            || samplesToWrite[0] == nullptr)
            return false;
        if (numSamples <= 0)
            return true;

        const auto* left = reinterpret_cast<const float*> (samplesToWrite[0]);
        const auto* right = samplesToWrite[1] != nullptr
                              ? reinterpret_cast<const float*> (samplesToWrite[1])
                              : left;

        int consumed = 0;
        while (consumed < numSamples)
        {
            const auto inputIndex = AMediaCodec_dequeueInputBuffer (codec, 10000);
            if (inputIndex < 0)
            {
                if (! drain (false))
                    return healthy = false;
                continue;
            }

            size_t capacity = 0;
            auto* destination = AMediaCodec_getInputBuffer (codec, (size_t) inputIndex, &capacity);
            const int availableFrames = (int) (capacity / (2 * sizeof (std::int16_t)));
            if (destination == nullptr || availableFrames <= 0)
                return healthy = false;

            const int frames = juce::jmin (availableFrames, numSamples - consumed);
            auto* pcm = reinterpret_cast<std::int16_t*> (destination);
            for (int frame = 0; frame < frames; ++frame)
            {
                const auto toPcm16 = [] (float sample)
                {
                    const float clipped = juce::jlimit (-1.0f, 1.0f, sample);
                    return (std::int16_t) std::lrint (clipped * 32767.0f);
                };
                pcm[frame * 2] = toPcm16 (left[consumed + frame]);
                pcm[frame * 2 + 1] = toPcm16 (right[consumed + frame]);
            }

            const auto presentationUs = (std::uint64_t) std::llround (
                (double) framesSubmitted * 1000000.0 / sampleRate);
            const auto status = AMediaCodec_queueInputBuffer (
                codec, (size_t) inputIndex, 0,
                (size_t) frames * 2 * sizeof (std::int16_t), presentationUs, 0);
            if (status != AMEDIA_OK)
                return healthy = false;

            consumed += frames;
            framesSubmitted += frames;
            if (! drain (false))
                return healthy = false;
        }
        return true;
    }

    bool flush() override { return healthy; }

private:
    bool startMuxerFromCodecFormat()
    {
        if (muxerStarted)
            return true;

        auto* format = AMediaCodec_getOutputFormat (codec);
        if (format == nullptr)
            return false;
        const auto releaseFormat = juce::ScopeGuard { [format] { AMediaFormat_delete (format); } };

        const auto added = AMediaMuxer_addTrack (muxer, format);
        if (added < 0)
            return false;
        trackIndex = (size_t) added;
        if (AMediaMuxer_start (muxer) != AMEDIA_OK)
            return false;
        muxerStarted = true;
        return true;
    }

    bool drain (bool waitForEnd)
    {
        int emptyPolls = 0;
        while (true)
        {
            AMediaCodecBufferInfo info {};
            const auto outputIndex = AMediaCodec_dequeueOutputBuffer (
                codec, &info, waitForEnd ? 10000 : 0);

            if (outputIndex >= 0)
            {
                size_t capacity = 0;
                const auto* data = AMediaCodec_getOutputBuffer (
                    codec, (size_t) outputIndex, &capacity);
                const bool isConfig = (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) != 0;
                if (! isConfig && info.size > 0)
                {
                    if (! muxerStarted && ! startMuxerFromCodecFormat())
                    {
                        AMediaCodec_releaseOutputBuffer (codec, (size_t) outputIndex, false);
                        return false;
                    }
                    if (data == nullptr
                        || (size_t) info.offset + (size_t) info.size > capacity
                        || AMediaMuxer_writeSampleData (muxer, trackIndex, data, &info) != AMEDIA_OK)
                    {
                        AMediaCodec_releaseOutputBuffer (codec, (size_t) outputIndex, false);
                        return false;
                    }
                }

                const bool end = (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0;
                AMediaCodec_releaseOutputBuffer (codec, (size_t) outputIndex, false);
                if (end)
                {
                    endObserved = true;
                    return true;
                }
                emptyPolls = 0;
                continue;
            }

            if (outputIndex == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
            {
                if (! startMuxerFromCodecFormat())
                    return false;
                emptyPolls = 0;
                continue;
            }
            if (outputIndex == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
                continue;
            if (outputIndex == AMEDIACODEC_INFO_TRY_AGAIN_LATER)
            {
                if (! waitForEnd)
                    return true;
                if (++emptyPolls < 500)
                    continue;
                return false;
            }
            return false;
        }
    }

    void finish()
    {
        if (finishAttempted || codec == nullptr)
            return;
        finishAttempted = true;

        // The encoder may briefly hold all input buffers while it emits prior
        // access units, so drain and retry rather than truncating the tail.
        for (int attempt = 0; attempt < 500; ++attempt)
        {
            const auto inputIndex = AMediaCodec_dequeueInputBuffer (codec, 10000);
            if (inputIndex >= 0)
            {
                const auto presentationUs = (std::uint64_t) std::llround (
                    (double) framesSubmitted * 1000000.0 / sampleRate);
                if (AMediaCodec_queueInputBuffer (
                        codec, (size_t) inputIndex, 0, 0, presentationUs,
                        AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != AMEDIA_OK)
                    healthy = false;
                break;
            }
            if (! drain (false))
            {
                healthy = false;
                return;
            }
        }

        if (! drain (true) || ! endObserved)
            healthy = false;
    }

    AMediaCodec* codec = nullptr;
    AMediaMuxer* muxer = nullptr;
    int descriptor = -1;
    size_t trackIndex = 0;
    std::int64_t framesSubmitted = 0;
    bool muxerStarted = false;
    bool finishAttempted = false;
    bool endObserved = false;
    bool healthy = true;
};

std::unique_ptr<juce::AudioFormatWriter> createAndroidAac (
    const juce::File& outputFile, int kbps, double sampleRate, juce::String& error)
{
    const int descriptor = ::open (outputFile.getFullPathName().toRawUTF8(),
                                   O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0)
    {
        error = "Could not create the M4A master file.";
        return {};
    }

    auto* muxer = AMediaMuxer_new (descriptor, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4);
    auto* codec = AMediaCodec_createEncoderByType ("audio/mp4a-latm");
    auto* format = AMediaFormat_new();
    if (muxer == nullptr || codec == nullptr || format == nullptr)
    {
        if (format != nullptr) AMediaFormat_delete (format);
        if (codec != nullptr) AMediaCodec_delete (codec);
        if (muxer != nullptr) AMediaMuxer_delete (muxer);
        ::close (descriptor);
        outputFile.deleteFile();
        error = "This device could not start its AAC encoder.";
        return {};
    }

    AMediaFormat_setString (format, AMEDIAFORMAT_KEY_MIME, "audio/mp4a-latm");
    AMediaFormat_setInt32 (format, AMEDIAFORMAT_KEY_SAMPLE_RATE, (std::int32_t) sampleRate);
    AMediaFormat_setInt32 (format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, 2);
    AMediaFormat_setInt32 (format, AMEDIAFORMAT_KEY_BIT_RATE, kbps * 1000);
    AMediaFormat_setInt32 (format, AMEDIAFORMAT_KEY_AAC_PROFILE, 2); // AAC-LC
    AMediaFormat_setInt32 (format, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, 32768);

    const bool configured = AMediaCodec_configure (
        codec, format, nullptr, nullptr, AMEDIACODEC_CONFIGURE_FLAG_ENCODE) == AMEDIA_OK;
    AMediaFormat_delete (format);
    if (! configured || AMediaCodec_start (codec) != AMEDIA_OK)
    {
        AMediaCodec_delete (codec);
        AMediaMuxer_delete (muxer);
        ::close (descriptor);
        outputFile.deleteFile();
        error = "This device rejected the requested AAC settings.";
        return {};
    }

    return std::make_unique<AndroidAacWriter> (codec, muxer, descriptor, sampleRate);
}
#endif
}

bool isSupported (ExportFormat::Kind kind)
{
    switch (kind)
    {
        case ExportFormat::Kind::wav: return true;
        case ExportFormat::Kind::mp3: return RESOUL_HAS_LAME != 0;
        case ExportFormat::Kind::m4a:
            return RESOUL_HAS_COREAUDIO_AAC != 0 || RESOUL_HAS_ANDROID_AAC != 0;
        case ExportFormat::Kind::count:
        default: break;
    }
    return false;
}

std::unique_ptr<juce::AudioFormatWriter> createWriter (const juce::File& outputFile,
                                                       ExportFormat::Kind kind,
                                                       int qualityIndex,
                                                       double sampleRate,
                                                       const TrackMetadata& metadata,
                                                       juce::String& error)
{
    const int kbps = ExportFormat::quality (kind, qualityIndex).value;

    if (outputFile.existsAsFile() && ! outputFile.deleteFile())
    {
        error = "Could not replace the existing output file.";
        return {};
    }

    if (kind == ExportFormat::Kind::m4a)
    {
       #if RESOUL_HAS_COREAUDIO_AAC
        return createAac (outputFile, kbps, sampleRate, error);
       #elif RESOUL_HAS_ANDROID_AAC
        return createAndroidAac (outputFile, kbps, sampleRate, error);
       #else
        error = "AAC export is not available on this platform.";
        return {};
       #endif
    }

    if (kind == ExportFormat::Kind::mp3)
    {
       #if RESOUL_HAS_LAME
        auto* flags = lame_init();
        if (flags == nullptr)
        {
            error = "Could not start the MP3 encoder.";
            return {};
        }
        lame_set_in_samplerate (flags, (int) sampleRate);
        lame_set_out_samplerate (flags, (int) sampleRate);
        lame_set_num_channels (flags, 2);
        lame_set_mode (flags, JOINT_STEREO);
        lame_set_VBR (flags, vbr_off);        // constant bitrate: what the UI promises
        lame_set_brate (flags, kbps);
        lame_set_quality (flags, 2);          // 2 = high quality, sane speed

        // Tags must be configured before init_params so LAME can emit the
        // ID3v2 header ahead of the first frame.
        id3tag_init (flags);
        id3tag_add_v2 (flags);
        const auto title = metadata.title.trim();
        const auto artist = metadata.artist.trim();
        if (title.isNotEmpty())  id3tag_set_title (flags, title.toRawUTF8());
        if (artist.isNotEmpty()) id3tag_set_artist (flags, artist.toRawUTF8());

        if (lame_init_params (flags) < 0)
        {
            lame_close (flags);
            error = "The MP3 encoder rejected these settings.";
            return {};
        }

        std::unique_ptr<juce::FileOutputStream> stream (outputFile.createOutputStream());
        if (stream == nullptr)
        {
            lame_close (flags);
            error = "Could not create the master file. Pick another folder or name.";
            return {};
        }
        return std::make_unique<Mp3Writer> (stream.release(), flags, sampleRate, kbps);
       #else
        error = "MP3 export is not available on this platform.";
        return {};
       #endif
    }

    error = "Unsupported export format.";
    return {};
}
}
