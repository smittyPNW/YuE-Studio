#include "AudioFileManager.h"

namespace
{
juce::String leafName (juce::String name)
{
    return name.fromLastOccurrenceOf ("/", false, false)
               .fromLastOccurrenceOf ("\\", false, false);
}

juce::String extensionForDisplayName (const juce::String& displayName)
{
    const auto leaf = leafName (displayName);
    const auto dot = leaf.lastIndexOfChar ('.');
    return dot > 0 ? leaf.substring (dot) : juce::String {};
}

juce::String stemForDisplayName (const juce::String& displayName)
{
    const auto leaf = leafName (displayName);
    const auto extension = extensionForDisplayName (leaf);
    return extension.isEmpty() ? leaf : leaf.dropLastCharacters (extension.length());
}
}

AudioFileManager::~AudioFileManager()
{
    clear();
}

void AudioFileManager::ensureFormats()
{
    if (formats.getNumKnownFormats() == 0)
        formats.registerBasicFormats();
}

bool AudioFileManager::load (const juce::File& file, juce::String& error)
{
    ensureFormats();
    return finishLoad (std::unique_ptr<juce::AudioFormatReader> (formats.createReaderFor (file)),
                       file.getFileName(), file, juce::URL (file), error);
}

bool AudioFileManager::load (const juce::URL& url, juce::String& error)
{
    ensureFormats();

   #if JUCE_ANDROID
    // Android's Storage Access Framework commonly supplies a content:// stream
    // that is readable but not seekable. Compressed decoders such as MP3 need
    // random access, and silently fail when handed that stream directly. Stage
    // the user-selected document in Studio Mastering's private cache so every advertised
    // format decodes and can be reopened by the offline renderer.
    // FileChooser returns a Storage Access Framework content:// document on
    // modern Android. URL::createInputStream treats non-file URLs as network
    // resources, while AndroidDocument opens the URI through ContentResolver.
    // Keep the AndroidDocument alive until the copy completes so its native
    // stream and temporary picker grant remain valid.
    auto document = juce::AndroidDocument::fromDocument (url);
    auto input = document.hasValue() ? document.createInputStream() : nullptr;
    if (input == nullptr)
    {
        error = "Android could not open that selected music file.";
        return false;
    }

    const auto decodedName = juce::URL::removeEscapeChars (url.getFileName());
    const auto selectedName = decodedName.isNotEmpty()
                                  ? decodedName
                                  : juce::String ("Studio Mastering Import.audio");
    auto cacheDirectory = juce::File::getSpecialLocation (juce::File::tempDirectory)
                              .getChildFile ("Studio Mastering Imports");
    if (cacheDirectory.createDirectory().failed())
    {
        error = "Studio Mastering could not prepare private storage for this import.";
        return false;
    }

    auto stagedFile = cacheDirectory.getNonexistentChildFile (
        juce::File::createLegalFileName (stemForDisplayName (selectedName)),
        extensionForDisplayName (selectedName), false);
    {
        juce::FileOutputStream output (stagedFile);
        if (! output.openedOk())
        {
            error = "Studio Mastering could not stage this selected music file.";
            return false;
        }
        output.writeFromInputStream (*input, -1);
        output.flush();
    }

    auto reader = std::unique_ptr<juce::AudioFormatReader> (formats.createReaderFor (stagedFile));
    const bool loaded = finishLoad (std::move (reader), selectedName, stagedFile, {}, error);
    if (loaded)
        ownsSourceFile = true;
    else
        stagedFile.deleteFile();
    return loaded;
   #else
    auto stream = url.createInputStream (
        juce::URL::InputStreamOptions (juce::URL::ParameterHandling::inAddress));
    auto reader = std::unique_ptr<juce::AudioFormatReader> (
        formats.createReaderFor (std::move (stream)));
    // URL::getFileName() hands back the PERCENT-ENCODED path component, so a
    // song with spaces displayed as "My%20Mix.wav" everywhere the source name
    // appears (header, tags, export name). Decode it, and prefer the real file
    // name when the URL is local.
    const auto selectedName = url.isLocalFile()
                                  ? url.getLocalFile().getFileName()
                                  : juce::URL::removeEscapeChars (url.getFileName());
    const auto metadataFile = url.isLocalFile() ? url.getLocalFile()
                                                 : juce::File (selectedName);
    return finishLoad (std::move (reader), selectedName, metadataFile, url, error);
   #endif
}

bool AudioFileManager::finishLoad (std::unique_ptr<juce::AudioFormatReader> reader,
                                   const juce::String& selectedName,
                                   const juce::File& metadataFile,
                                   const juce::URL& selectedURL,
                                   juce::String& error)
{
    if (reader == nullptr)
    {
        const auto extension = extensionForDisplayName (selectedName).toLowerCase();
        const bool advertisedAudioType = extension == ".wav" || extension == ".aiff"
                                      || extension == ".aif" || extension == ".flac"
                                      || extension == ".mp3" || extension == ".m4a";
        error = advertisedAudioType
            ? "This music file is incomplete or damaged and could not be decoded safely."
            : "That file type isn't supported. Try WAV, AIFF, FLAC, MP3, or M4A.";
        return false;
    }

    const int numSamples = (int) reader->lengthInSamples;
    if (numSamples <= 0)
    {
        error = "This music file looks empty.";
        return false;
    }

    // Decode directly into the immutable stereo backing store. JUCE duplicates
    // mono sources into the second destination channel, so the old full-song
    // temporary buffer and copy are unnecessary. This halves peak import RAM.
    auto decoded = std::make_shared<juce::AudioBuffer<float>> (2, numSamples);
    decoded->clear();
    if (! reader->read (decoded.get(), 0, numSamples, 0, true, true))
    {
        error = "This music file is incomplete or damaged and could not be decoded safely.";
        return false;
    }

    buffer = std::move (decoded);

    sampleRate = reader->sampleRate;
    fileName = selectedName;
    sourceFormat = extensionForDisplayName (selectedName).trimCharactersAtStart (".").toUpperCase();
    sourceBitDepth = (int) reader->bitsPerSample;
    sourceFile = metadataFile;
    sourceURL = selectedURL;

    // Metadata: read -> strip AI junk -> filename hints
    juce::StringPairArray raw = reader->metadataValues;
    clearedAiTags = false;
    // Detect junk in any value
    for (int i = 0; i < raw.size(); ++i)
    {
        if (MetadataCleaner::looksLikeAiJunk (raw.getAllValues()[i]))
        {
            clearedAiTags = true;
            break;
        }
    }
    metadata = MetadataCleaner::fromFileHints (raw, metadataFile);
    // If we had raw title/artist that cleaned to empty, mark cleared
    for (int i = 0; i < raw.size(); ++i)
    {
        auto key = raw.getAllKeys()[i].toLowerCase();
        if ((key.contains ("title") || key.contains ("artist") || key.contains ("inam") || key.contains ("iart"))
            && MetadataCleaner::looksLikeAiJunk (raw.getAllValues()[i]))
            clearedAiTags = true;
    }

    buildOverview();
    return true;
}

void AudioFileManager::clear()
{
    if (ownsSourceFile && sourceFile.existsAsFile())
        sourceFile.deleteFile();
    buffer = std::make_shared<juce::AudioBuffer<float>>();
    overview.clear();
    fileName.clear();
    sourceFormat.clear();
    sourceBitDepth = 0;
    sourceFile = juce::File();
    sourceURL = {};
    ownsSourceFile = false;
    metadata = {};
    clearedAiTags = false;
}

void AudioFileManager::swapLoadedContent (AudioFileManager& other)
{
    std::swap (buffer, other.buffer);
    std::swap (sampleRate, other.sampleRate);
    std::swap (fileName, other.fileName);
    std::swap (sourceFormat, other.sourceFormat);
    std::swap (sourceBitDepth, other.sourceBitDepth);
    std::swap (sourceFile, other.sourceFile);
    std::swap (sourceURL, other.sourceURL);
    std::swap (ownsSourceFile, other.ownsSourceFile);
    std::swap (metadata, other.metadata);
    std::swap (clearedAiTags, other.clearedAiTags);
    overview.swap (other.overview);
}

void AudioFileManager::buildOverview (int targetPoints)
{
    overview.clear();
    if (buffer == nullptr || buffer->getNumSamples() == 0) return;
    const int n = buffer->getNumSamples();
    const int points = juce::jmax (2, targetPoints);
    const int ch = buffer->getNumChannels();
    overview.resize ((size_t) points * (size_t) ch * 2);

    for (int c = 0; c < ch; ++c)
    {
        const float* d = buffer->getReadPointer (c);
        for (int p = 0; p < points; ++p)
        {
            int start = (int) ((int64_t) p * n / points);
            int end = (int) ((int64_t) (p + 1) * n / points);
            float mn = 0, mx = 0;
            for (int i = start; i < end; ++i)
            {
                mn = juce::jmin (mn, d[i]);
                mx = juce::jmax (mx, d[i]);
            }
            size_t idx = (size_t) (p * ch + c) * 2;
            overview[idx] = mn;
            overview[idx + 1] = mx;
        }
    }
}
