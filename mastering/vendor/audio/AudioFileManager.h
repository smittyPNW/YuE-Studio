#pragma once
#include <JuceHeader.h>
#include "TrackMetadata.h"

class AudioFileManager
{
public:
    ~AudioFileManager();
    bool load (const juce::File& file, juce::String& error);
    /** Opens a document-picker result without discarding its iOS security
        bookmark. The URL may be copied or moved, but must not be rebuilt from
        its path string. */
    bool load (const juce::URL& url, juce::String& error);
    void clear();

    /** Constant-time handoff for a fully decoded replacement. The caller must
        provide the short synchronization barrier that protects active readers. */
    void swapLoadedContent (AudioFileManager& other);

    bool hasAudio() const { return buffer != nullptr && buffer->getNumSamples() > 0; }
    const juce::AudioBuffer<float>& getBuffer() const { return *buffer; }
    /** Immutable ownership for background analysis/export. This avoids copying
        an entire decoded song merely to keep it alive while a worker runs. */
    std::shared_ptr<const juce::AudioBuffer<float>> getSharedBuffer() const { return buffer; }
    double getSampleRate() const { return sampleRate; }
    int getNumChannels() const { return buffer != nullptr ? buffer->getNumChannels() : 0; }
    int getNumSamples() const { return buffer != nullptr ? buffer->getNumSamples() : 0; }
    double getDurationSec() const { return sampleRate > 0 && buffer != nullptr
                                            ? buffer->getNumSamples() / sampleRate : 0; }
    juce::String getFileName() const { return fileName; }
    juce::String getSourceFormat() const { return sourceFormat; }
    int getSourceBitDepth() const { return sourceBitDepth; }
    juce::File getSourceFile() const { return sourceFile; }
    juce::URL getSourceURL() const { return sourceURL; }

    TrackMetadata& getMetadata() { return metadata; }
    const TrackMetadata& getMetadata() const { return metadata; }
    void setMetadata (const TrackMetadata& m) { metadata = m; }
    bool didClearAiTags() const { return clearedAiTags; }
    bool needsMetadataPrompt() const { return MetadataCleaner::needsUserInput (metadata) || clearedAiTags; }

    /** Downsampled peak overview for waveform UI: interleaved min/max pairs per channel. */
    const std::vector<float>& getOverview() const { return overview; }
    void buildOverview (int targetPoints = 2048);

private:
    std::shared_ptr<juce::AudioBuffer<float>> buffer =
        std::make_shared<juce::AudioBuffer<float>>();
    double sampleRate = 44100.0;
    juce::String fileName;
    juce::String sourceFormat;
    int sourceBitDepth = 0;
    juce::File sourceFile;
    juce::URL sourceURL;
    bool ownsSourceFile = false;
    TrackMetadata metadata;
    bool clearedAiTags = false;
    std::vector<float> overview;
    juce::AudioFormatManager formats;
    void ensureFormats();
    bool finishLoad (std::unique_ptr<juce::AudioFormatReader> reader,
                     const juce::String& selectedName,
                     const juce::File& metadataFile,
                     const juce::URL& selectedURL,
                     juce::String& error);
};
