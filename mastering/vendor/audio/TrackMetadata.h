#pragma once
#include <JuceHeader.h>

/** Song identity written to the mastered file. AI junk tags are stripped. */
struct TrackMetadata
{
    juce::String title;
    juce::String artist;
    juce::String album;
    juce::String genre;
    juce::String year;
    juce::String comment; // clean user note only — never AI prompt dumps

    bool hasCoreIdentity() const
    {
        return title.trim().isNotEmpty() && artist.trim().isNotEmpty();
    }

    juce::String displayLine() const
    {
        if (title.isNotEmpty() && artist.isNotEmpty())
            return artist + " — " + title;
        if (title.isNotEmpty()) return title;
        if (artist.isNotEmpty()) return artist;
        return {};
    }

    /** Suggested export filename base (Artist - Title). */
    juce::String suggestedFileBase() const
    {
        auto safe = [] (juce::String s)
        {
            s = s.trim();
            const juce::String bad ("/\\?%*:|\"<>");
            for (int i = 0; i < bad.length(); ++i)
                s = s.replaceCharacter (bad[i], '-');
            return s;
        };
        if (artist.isNotEmpty() && title.isNotEmpty())
            return safe (artist) + " - " + safe (title);
        if (title.isNotEmpty()) return safe (title);
        return "master";
    }

    juce::StringPairArray toWavMetadata() const
    {
        juce::StringPairArray m;
        // The WAV writer requires RIFF INFO chunk identifiers, not generic tag names.
        if (title.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoTitle, title);
        if (artist.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoArtist, artist);
        if (album.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoProductName, album);
        if (genre.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoGenre, genre);
        if (year.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoDateCreated, year);
        if (comment.isNotEmpty())
            m.set (juce::WavAudioFormat::riffInfoComment2, comment);
        m.set (juce::WavAudioFormat::riffInfoSoftware, "Studio Mastering");
        return m;
    }
};

/** Detect / clean AI-generated ID tags and invent safe defaults from a filename. */
namespace MetadataCleaner
{
    /** True if string looks like an AI ID, UUID, hash, or generator junk. */
    bool looksLikeAiJunk (const juce::String& s);

    /** Strip junk from a single field; empty if nothing authentic remains. */
    juce::String cleanField (const juce::String& s);

    /** Read raw reader metadata + filename → cleaned TrackMetadata (may still need user). */
    TrackMetadata fromFileHints (const juce::StringPairArray& rawMeta,
                                 const juce::File& sourceFile);

    /** Merge user answers over cleaned base. */
    TrackMetadata applyUserEdits (TrackMetadata base,
                                  const juce::String& title,
                                  const juce::String& artist,
                                  const juce::String& album,
                                  const juce::String& genre,
                                  const juce::String& year);

    /** True if we should prompt the user (missing title/artist or only junk found). */
    bool needsUserInput (const TrackMetadata& m);

    /** Guess title from "Artist - Title.wav" or similar. */
    void guessFromFilename (const juce::File& f, juce::String& outArtist, juce::String& outTitle);
}
