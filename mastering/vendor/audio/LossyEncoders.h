#pragma once
#include <JuceHeader.h>
#include "ExportFormat.h"
#include "TrackMetadata.h"

/*  Writers for the formats JUCE cannot produce.

    JUCE ships no MP3 encoder at all (`MP3AudioFormat::createWriterFor` is a
    stub that asserts and returns nullptr) and its CoreAudioFormat is
    decode-only, so both lossy deliverables need their own writer:

      MP3 -> LAME (vendored, see external/lame/README.md)
      M4A -> AAC through CoreAudio's ExtAudioFile on Apple platforms, or
             MediaCodec/MediaMuxer on Android

    Both are juce::AudioFormatWriter subclasses so the render loop keeps
    calling writeFromAudioSampleBuffer and never learns which format it is
    feeding. Both take float samples directly - they set
    usesFloatingPointData, so JUCE hands the buffer through without an
    intermediate fixed-point conversion that would only cost quality.
*/
namespace LossyEncoders
{
/** Creates a writer for `kind` at `qualityIndex`, or nullptr with `error` set.

    `outputFile` is created/replaced. Unlike the WAV path this takes the File
    rather than an OutputStream, because ExtAudioFile insists on owning the
    file itself and cannot be pointed at someone else's stream. */
std::unique_ptr<juce::AudioFormatWriter> createWriter (const juce::File& outputFile,
                                                       ExportFormat::Kind kind,
                                                       int qualityIndex,
                                                       double sampleRate,
                                                       const TrackMetadata& metadata,
                                                       juce::String& error);

/** True when this build can actually produce `kind`. MP3 rides on the
    vendored LAME; M4A uses the platform AAC encoder. The UI asks before it
    offers a format, so a platform without an encoder never shows a choice it
    would then have to fail. */
bool isSupported (ExportFormat::Kind kind);
}
