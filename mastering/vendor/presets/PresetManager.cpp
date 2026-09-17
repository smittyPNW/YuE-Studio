#include "PresetManager.h"
#include "StudioPresetStorage.h"

PresetManager::PresetManager()
{
    initBuiltIns();
    getPresetsDir().createDirectory();
}

juce::File PresetManager::getPresetsDir() const
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
        .getChildFile ("Application Support")
        .getChildFile (Brand::supportDir)
        .getChildFile ("Presets");
}

void PresetManager::initBuiltIns()
{
    builtIns.push_back ({ "Neutral / Manual",
                          "No genre curve or character processing; build the master by hand.",
                          ParameterState {} });

    // A genre profile is a restrained musical starting point, never a promise
    // that every song in a category needs the same curve. The four audited
    // archetypes below provide safe foundations; each profile then changes only
    // a few deliberate tone, stereo, dynamics, and character decisions.
    auto addGenre = [this] (const juce::String& name,
                            const juce::String& direction,
                            GenrePreset foundation,
                            auto tune)
    {
        ParameterState state;
        state.applyGenrePreset (foundation);
        tune (state);

        state.useTruePeak = true;
        state.ceilingDb = -1.0f;
        state.normalizeActive = false;
        state.normalizeGainDb = 0.0f;
        state.masterVolDb = juce::jlimit (0.0f, 2.0f, state.masterVolDb);
        state.punch = juce::jlimit (0.0f, 0.55f, state.punch);
        state.width = juce::jlimit (0.42f, 0.62f, state.width);
        state.targetLufs = juce::jlimit (-18.0f, -9.0f, state.targetLufs);

        builtIns.push_back ({ name,
                              direction + " Loudness is delivery intent; use Match Level to measure this song before export.",
                              state });
    };

    addGenre ("GENRE / Hip-Hop + Sub-Bass", "Centered sub-bass, restrained low-mid cleanup and punch.",
              GenrePreset::HipHopSubBass, [] (ParameterState&) {});
    addGenre ("GENRE / Hip-Hop - Classic Warm", "Rounded drums, solid vocal center and understated analogue warmth.",
              GenrePreset::HipHopSubBass, [] (ParameterState& s)
              { s.punch = 0.28f; s.warmth = 0.32f; s.analogLife = 0.18f; s.treble = 0.47f; s.targetLufs = -13.0f; });
    addGenre ("GENRE / Hip-Hop - Trap 808", "Deep mono-compatible 808 weight, clipped-transient control and clear hats.",
              GenrePreset::HipHopSubBass, [] (ParameterState& s)
              { s.monoLow = 0.68f; s.punch = 0.42f; s.bass = 0.61f; s.deEsser = 0.14f; s.targetLufs = -11.0f; s.eq[2].gainDb = -1.0f; });
    addGenre ("GENRE / R&B - Silk", "Supple low end, forward vocal intimacy and polished air without brittle sibilance.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.width = 0.54f; s.punch = 0.18f; s.bass = 0.54f; s.deEsser = 0.25f; s.warmth = 0.28f; s.airExciter = 0.12f; s.targetLufs = -14.0f; });
    addGenre ("GENRE / Soul - Vintage Warm", "Full midrange, softened top and console colour that keeps vocals human.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.lowCut = false; s.punch = 0.14f; s.warmth = 0.46f; s.analogLife = 0.24f; s.treble = 0.46f; s.finalCharacter = FinalCharacter::AnalogConsole; s.targetLufs = -15.0f; });

    addGenre ("GENRE / Pop - Radio Bright", "Tight vocal-forward balance, polished highs and controlled modern punch.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.width = 0.54f; s.punch = 0.32f; s.deEsser = 0.22f; s.mid = 0.54f; s.treble = 0.53f; s.airExciter = 0.14f; s.targetLufs = -12.0f; });
    addGenre ("GENRE / Indie Pop - Open", "Breathing room around the vocal, organic transients and an uncluttered stereo field.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.width = 0.56f; s.punch = 0.20f; s.airExciter = 0.13f; s.analogLife = 0.12f; s.masterVolDb = 1.0f; s.targetLufs = -14.0f; });
    addGenre ("GENRE / Dance Pop - Gloss", "Firm dance-floor lows, glossy presence and energetic but guarded loudness.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.58f; s.width = 0.58f; s.punch = 0.42f; s.airExciter = 0.16f; s.masterVolDb = 1.7f; s.targetLufs = -10.5f; });
    addGenre ("GENRE / Hyperpop - Spark", "Dense transient energy, vivid upper detail and disciplined sub-bass anchoring.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.62f; s.punch = 0.48f; s.deChirp = 0.20f; s.deEsser = 0.24f; s.treble = 0.55f; s.airExciter = 0.18f; s.targetLufs = -10.0f; });

    addGenre ("GENRE / EDM + Loud", "Tight lows and controlled punch with guarded festival-scale energy.",
              GenrePreset::EDMLoud, [] (ParameterState&) {});
    addGenre ("GENRE / House - Club", "Centered kick and bass, open percussion and steady four-on-the-floor drive.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.64f; s.width = 0.58f; s.punch = 0.36f; s.bass = 0.57f; s.eq[1].frequencyHz = 85.0f; s.targetLufs = -10.5f; });
    addGenre ("GENRE / Techno - Tight", "Dry low-end authority, restrained width and uncompromising transient definition.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.70f; s.width = 0.52f; s.punch = 0.44f; s.warmth = 0.04f; s.airExciter = 0.06f; s.targetLufs = -10.0f; });
    addGenre ("GENRE / Drum & Bass - Fast", "Rapid kick-snare separation, stable sub weight and clear high-frequency motion.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.70f; s.monoHigh = 0.18f; s.width = 0.57f; s.punch = 0.50f; s.deEsser = 0.18f; s.mud = 0.22f; s.targetLufs = -10.0f; });
    addGenre ("GENRE / Dubstep - Heavy", "Massive controlled bass, aggressive impact and reduced low-mid masking.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.72f; s.width = 0.55f; s.punch = 0.52f; s.bass = 0.60f; s.mud = 0.26f; s.deChirp = 0.18f; s.targetLufs = -9.5f; });
    addGenre ("GENRE / Future Bass - Wide", "Expansive synth bloom above a locked center, with smooth vocal presence.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.64f; s.width = 0.62f; s.punch = 0.34f; s.deEsser = 0.22f; s.warmth = 0.14f; s.airExciter = 0.14f; s.targetLufs = -11.0f; });

    addGenre ("GENRE / Rock - Modern Punch", "Dense guitars, commanding drums and vocal presence without low-mid fog.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.46f; s.width = 0.54f; s.punch = 0.46f; s.mud = 0.25f; s.mid = 0.55f; s.warmth = 0.18f; s.targetLufs = -11.0f; });
    addGenre ("GENRE / Rock - Classic Wide", "Natural kit transients, broad guitars and warm analogue cohesion.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.lowCut = false; s.width = 0.57f; s.punch = 0.30f; s.warmth = 0.34f; s.analogLife = 0.20f; s.masterVolDb = 1.2f; s.targetLufs = -13.0f; });
    addGenre ("GENRE / Indie Rock - Organic", "Textured mids, lively drums and preserved imperfection rather than hyped gloss.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.lowCut = false; s.width = 0.55f; s.punch = 0.26f; s.mud = 0.16f; s.analogLife = 0.20f; s.targetLufs = -14.0f; });
    addGenre ("GENRE / Alt Rock - Dense", "Separates layered guitars while retaining weight and a firm vocal center.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.width = 0.53f; s.punch = 0.40f; s.mud = 0.30f; s.mid = 0.56f; s.deEsser = 0.18f; s.targetLufs = -11.5f; });
    addGenre ("GENRE / Punk - Raw", "Fast impact, urgent mids and minimal polish so the performance stays dangerous.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.width = 0.52f; s.punch = 0.50f; s.mud = 0.18f; s.mid = 0.58f; s.airExciter = 0.04f; s.warmth = 0.16f; s.targetLufs = -10.5f; });
    addGenre ("GENRE / Metal - Tight Aggressive", "Controlled double-kick lows, articulate guitars and protected cymbal detail.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.62f; s.width = 0.53f; s.punch = 0.52f; s.mud = 0.32f; s.deEsser = 0.26f; s.deChirp = 0.16f; s.targetLufs = -10.0f; });

    addGenre ("GENRE / Acoustic + Intimate", "Natural width, gentle vocal presence and preserved dynamics.",
              GenrePreset::AcousticIntimate, [] (ParameterState&) {});
    addGenre ("GENRE / Folk - Natural", "Honest transients, woody mids and air that never disconnects from the room.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.punch = 0.10f; s.warmth = 0.24f; s.analogLife = 0.12f; s.airExciter = 0.08f; s.targetLufs = -16.0f; });
    addGenre ("GENRE / Country - Vocal Clear", "Focused storytelling vocal, firm acoustic low end and clean string detail.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.width = 0.53f; s.punch = 0.20f; s.mid = 0.57f; s.deEsser = 0.22f; s.airExciter = 0.11f; s.masterVolDb = 1.0f; s.targetLufs = -14.0f; });
    addGenre ("GENRE / Jazz - Open", "Natural ensemble depth, unforced transients and intact microdynamics.",
              GenrePreset::ClassicalDynamic, [] (ParameterState& s)
              { s.width = 0.53f; s.punch = 0.06f; s.warmth = 0.14f; s.analogLife = 0.08f; s.masterVolDb = 0.3f; s.targetLufs = -17.0f; });
    addGenre ("GENRE / Classical + Dynamic", "Near-neutral tone and minimal dynamics for faithful concert-scale range.",
              GenrePreset::ClassicalDynamic, [] (ParameterState&) {});
    addGenre ("GENRE / Orchestral - Cinematic", "Deep stage, stable bass foundation and preserved large-scale crescendos.",
              GenrePreset::ClassicalDynamic, [] (ParameterState& s)
              { s.width = 0.56f; s.monoLow = 0.28f; s.punch = 0.08f; s.bass = 0.52f; s.airExciter = 0.05f; s.targetLufs = -17.0f; });

    addGenre ("GENRE / Ambient - Expansive", "Wide atmospheric depth, smooth high detail and nearly untouched dynamics.",
              GenrePreset::ClassicalDynamic, [] (ParameterState& s)
              { s.width = 0.62f; s.monoLow = 0.35f; s.punch = 0.02f; s.deChirp = 0.12f; s.airExciter = 0.08f; s.targetLufs = -17.0f; });
    addGenre ("GENRE / Lo-Fi - Soft Focus", "Rounded edges, intimate width and tape colour without burying the groove.",
              GenrePreset::AcousticIntimate, [] (ParameterState& s)
              { s.lowCut = false; s.width = 0.48f; s.punch = 0.12f; s.treble = 0.43f; s.warmth = 0.48f; s.analogLife = 0.30f; s.tapeHiss = 0.10f; s.finalCharacter = FinalCharacter::MagneticTape; s.targetLufs = -14.0f; });
    addGenre ("GENRE / Reggae - Deep Pocket", "Centered bass weight, relaxed transient shape and open offbeat detail.",
              GenrePreset::HipHopSubBass, [] (ParameterState& s)
              { s.monoLow = 0.70f; s.width = 0.54f; s.punch = 0.22f; s.bass = 0.60f; s.warmth = 0.28f; s.targetLufs = -13.0f; });
    addGenre ("GENRE / Reggaeton - Club", "Locked kick-and-bass center, bright percussion and durable rhythmic impact.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.66f; s.width = 0.56f; s.punch = 0.44f; s.bass = 0.58f; s.deEsser = 0.18f; s.targetLufs = -10.5f; });
    addGenre ("GENRE / Latin Pop - Vibrant", "Present vocals, lively percussion and polished width with a steady low end.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.56f; s.width = 0.57f; s.punch = 0.35f; s.mid = 0.55f; s.airExciter = 0.13f; s.targetLufs = -12.0f; });
    addGenre ("GENRE / K-Pop J-Pop - Gloss", "Precise low end, layered vocal clarity and vivid but controlled sparkle.",
              GenrePreset::EDMLoud, [] (ParameterState& s)
              { s.monoLow = 0.60f; s.width = 0.58f; s.punch = 0.40f; s.deEsser = 0.26f; s.mid = 0.55f; s.treble = 0.54f; s.airExciter = 0.16f; s.targetLufs = -11.0f; });
    {
        ParameterState s; s.applyQuickFixHumanize();
        builtIns.push_back ({ "Humanize / Natural", "Adds restrained analogue movement and body without hidden gain, noise, or crushed dynamics.", s });
    }
    {
        ParameterState s;
        s.deChirp = 0.34f; s.deEsser = 0.12f; s.monoHigh = 0.08f;
        builtIns.push_back ({ "AI Cleanup / Gentle", "Conservatively repairs stable high-frequency whistles while preserving cymbals and stereo detail.", s });
    }
    {
        ParameterState s;
        s.deChirp = 0.62f; s.deEsser = 0.20f; s.monoHigh = 0.14f; s.warmth = 0.06f;
        builtIns.push_back ({ "AI Cleanup / Balanced", "Targets persistent synthetic whistles and brittle edges with stereo-linked, level-neutral repair.", s });
    }
    {
        ParameterState s;
        s.deChirp = 0.88f; s.deEsser = 0.30f; s.monoHigh = 0.22f; s.treble = 0.48f;
        builtIns.push_back ({ "AI Cleanup / Strong", "Stronger repair for obvious tonal artifacts; compare Before and After to protect intentional bright detail.", s });
    }
    {
        ParameterState s;
        s.punch = 0.55f; s.bass = 0.60f; s.warmth = 0.40f;
        s.masterVolDb = 3.0f; s.finalCharacter = FinalCharacter::AnalogConsole;
        s.targetLufs = -14.0f;
        builtIns.push_back ({ "Punchy Streaming Master", "A broad modern starting point with punch and streaming-safe loudness intent.", s });
    }
    {
        ParameterState s;
        s.warmth = 0.55f; s.analogLife = 0.25f; s.airExciter = 0.18f;
        s.tapeHiss = 0.12f; s.finalCharacter = FinalCharacter::MagneticTape;
        builtIns.push_back ({ "Warm Tape Master", "Adds rounded tape character, warmth and restrained air.", s });
    }
    {
        ParameterState s;
        s.deEsser = 0.45f; s.airExciter = 0.35f; s.treble = 0.58f; s.deChirp = 0.25f;
        builtIns.push_back ({ "Bright But Smooth", "Adds openness while controlling sibilance and brittle highs.", s });
    }
    {
        ParameterState s; s.applyQuickFixStereo();
        builtIns.push_back ({ "Stereo Repair", "Centers low bass and reins in phasey high-frequency width.", s });
    }
    {
        ParameterState s;
        s.deEsser = 0.50f; s.mid = 0.58f; s.lowCut = true; s.mud = 0.30f;
        s.loudnessPreset = LoudnessPreset::AppleMusic;
        s.targetLufs = -16.0f;
        builtIns.push_back ({ "Podcast/Mix Cleanup", "Clears low-mid buildup and targets intelligible -16 LUFS delivery.", s });
    }
}

juce::StringArray PresetManager::getPresetNames() const
{
    juce::StringArray names;
    // The user reaches for repair/mastering utilities more often than a deep
    // genre browse. Keep Neutral first, then Mastering Tools, then the larger
    // Genre Profiles library. The recipe storage order remains irrelevant.
    if (! builtIns.empty())
        names.add (builtIns.front().name);
    for (size_t index = 1; index < builtIns.size(); ++index)
        if (! builtIns[index].name.startsWith ("GENRE /"))
            names.add (builtIns[index].name);
    for (size_t index = 1; index < builtIns.size(); ++index)
        if (builtIns[index].name.startsWith ("GENRE /"))
            names.add (builtIns[index].name);
    for (auto& f : getPresetsDir().findChildFiles (juce::File::findFiles, false, "*.json"))
        names.add (f.getFileNameWithoutExtension());
    return names;
}

bool PresetManager::loadPreset (const juce::String& name, ParameterState& out)
{
    const auto masteredPath = out.masteredPath;
    const auto loopEnabled = out.loopEnabled;
    const auto measuredIntegratedLufs = out.measuredIntegratedLufs;
    const auto measuredTruePeakDb = out.measuredTruePeakDb;
    const auto shortTermLufs = out.shortTermLufs;
    const auto outputPeakL = out.outputPeakL;
    const auto outputPeakR = out.outputPeakR;
    auto preserveRuntimeState = [&out, masteredPath, loopEnabled,
                                 measuredIntegratedLufs, measuredTruePeakDb,
                                 shortTermLufs, outputPeakL, outputPeakR]
    {
        out.masteredPath = masteredPath;
        out.loopEnabled = loopEnabled;
        out.measuredIntegratedLufs = measuredIntegratedLufs;
        out.measuredTruePeakDb = measuredTruePeakDb;
        out.shortTermLufs = shortTermLufs;
        out.outputPeakL = outputPeakL;
        out.outputPeakR = outputPeakR;
    };
    for (auto& b : builtIns)
        if (b.name == name) { out = b.state; preserveRuntimeState(); return true; }

    auto f = getPresetsDir().getChildFile (name + ".json");
    if (! f.existsAsFile()) return false;
    auto parsed = juce::JSON::parse (f);
    if (auto* o = parsed.getDynamicObject())
    {
        if (o->hasProperty ("parameters"))
            out.fromVar (o->getProperty ("parameters"));
        else
            out.fromVar (parsed);
        preserveRuntimeState();
        return true;
    }
    return false;
}

juce::String PresetManager::getPresetDescription (const juce::String& name) const
{
    for (const auto& builtIn : builtIns)
        if (builtIn.name == name)
            return builtIn.description;
    return "Your saved Studio Mastering settings. Fine-tune and level-match for this song before export.";
}

bool PresetManager::saveUserPreset (const juce::String& name, const ParameterState& state)
{
    auto* root = new juce::DynamicObject();
    root->setProperty ("version", 2);
    root->setProperty ("name", name);
    root->setProperty ("parameters", state.toVar());
    auto f = getPresetsDir().getChildFile (name + ".json");
    return f.replaceWithText (juce::JSON::toString (juce::var (root), true));
}
