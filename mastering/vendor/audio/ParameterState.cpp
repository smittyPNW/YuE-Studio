#include "ParameterState.h"

void ParameterState::resetToDefaults()
{
    *this = ParameterState{};
}

void ParameterState::applyQuickFixHumanize()
{
    // Humanize changes texture, not loudness. In particular, do not make the
    // processed side win an A/B comparison with hidden output gain or hiss.
    monoLow = 0.30f;
    monoHigh = 0.16f;
    width = 0.51f;
    punch = 0.18f;
    deChirp = 0.28f;
    deEsser = 0.20f;
    warmth = 0.26f;
    analogLife = 0.14f;
    warmExciter = 0.07f;
    airExciter = 0.04f;
    tapeHiss = 0.0f;
    mud = 0.10f;
    bass = 0.52f;
    mid = 0.51f;
    treble = 0.49f;
    masterVolDb = 0.0f;
    finalCharacter = FinalCharacter::AnalogConsole;
}

void ParameterState::applyQuickFixStereo()
{
    monoLow = 0.55f;
    monoHigh = 0.30f;
    width = 0.58f;
}

void ParameterState::applyQuickFixBass()
{
    monoLow = 0.50f;
    bass = 0.62f;
    punch = 0.45f;
    warmth = 0.35f;
    mud = 0.25f;
    eq[0].gainDb = 1.5f;
    eq[1].gainDb = 1.0f;
}

void ParameterState::applyQuickFixMid()
{
    mud = 0.40f;
    mid = 0.58f;
    deEsser = 0.30f;
    eq[2].gainDb = -1.5f;
    eq[3].gainDb = 1.0f;
}

void ParameterState::applyQuickFixHigh()
{
    deChirp = 0.45f;
    deEsser = 0.40f;
    airExciter = 0.30f;
    monoHigh = 0.35f;
    treble = 0.52f;
    eq[5].frequencyHz = 16000.f;
}

void ParameterState::applyGenrePreset (GenrePreset preset)
{
    // Genre presets are intentionally conservative starting points. Loudness
    // targets describe delivery intent; they do not enable normalization or
    // force a quiet source through excessive limiter gain reduction.
    *this = ParameterState {};
    useTruePeak = true;
    ceilingDb = -1.0f;
    normalizeActive = false;
    normalizeGainDb = 0.0f;

    switch (preset)
    {
        case GenrePreset::HipHopSubBass:
            monoLow = 0.60f;
            monoHigh = 0.12f;
            width = 0.52f;
            punch = 0.34f;
            bass = 0.58f;
            mud = 0.12f;
            mid = 0.49f;
            treble = 0.50f;
            warmth = 0.18f;
            analogLife = 0.10f;
            warmExciter = 0.05f;
            masterVolDb = 1.0f;
            finalCharacter = FinalCharacter::AnalogConsole;
            loudnessPreset = LoudnessPreset::Custom;
            targetLufs = -12.0f;
            eq[1] = { true, 55.0f, 0.8f, 0.80f, 0 };
            eq[2] = { true, 250.0f, -0.8f, 1.00f, 0 };
            break;

        case GenrePreset::AcousticIntimate:
            width = 0.50f;
            punch = 0.08f;
            deEsser = 0.16f;
            bass = 0.48f;
            mud = 0.08f;
            mid = 0.54f;
            treble = 0.51f;
            lowCut = true;
            warmth = 0.18f;
            analogLife = 0.08f;
            airExciter = 0.06f;
            masterVolDb = 0.5f;
            finalCharacter = FinalCharacter::CleanSafety;
            loudnessPreset = LoudnessPreset::AppleMusic;
            targetLufs = -16.0f;
            eq[2] = { true, 280.0f, -0.5f, 0.85f, 0 };
            eq[3] = { true, 2800.0f, 0.5f, 0.90f, 0 };
            break;

        case GenrePreset::EDMLoud:
            monoLow = 0.50f;
            monoHigh = 0.10f;
            width = 0.56f;
            punch = 0.40f;
            deEsser = 0.10f;
            bass = 0.55f;
            mud = 0.16f;
            mid = 0.50f;
            treble = 0.51f;
            warmth = 0.08f;
            analogLife = 0.05f;
            airExciter = 0.10f;
            masterVolDb = 1.5f;
            finalCharacter = FinalCharacter::CleanSafety;
            loudnessPreset = LoudnessPreset::SpotifyLoud;
            targetLufs = -11.0f;
            eq[1] = { true, 70.0f, 0.6f, 0.80f, 0 };
            eq[2] = { true, 300.0f, -0.7f, 1.00f, 0 };
            eq[4] = { true, 9000.0f, 0.4f, 0.75f, 2 };
            break;

        case GenrePreset::ClassicalDynamic:
            width = 0.50f;
            punch = 0.04f;
            deChirp = 0.02f;
            deEsser = 0.03f;
            warmth = 0.04f;
            masterVolDb = 0.0f;
            finalCharacter = FinalCharacter::CleanSafety;
            loudnessPreset = LoudnessPreset::Custom;
            targetLufs = -18.0f;
            break;
    }
}

float ParameterState::mapWidth (float knob01)
{
    // 0 → 0.75, 0.5 → 1.0, 1 → 1.35
    if (knob01 <= 0.5f)
        return juce::jmap (knob01, 0.0f, 0.5f, 0.75f, 1.0f);
    return juce::jmap (knob01, 0.5f, 1.0f, 1.0f, 1.35f);
}

float ParameterState::unmapWidth (float widthMultiplier)
{
    // Exact inverse of mapWidth's two musical ranges.
    const auto width = juce::jlimit (0.75f, 1.35f, widthMultiplier);
    if (width <= 1.0f)
        return juce::jmap (width, 0.75f, 1.0f, 0.0f, 0.5f);
    return juce::jmap (width, 1.0f, 1.35f, 0.5f, 1.0f);
}

float ParameterState::mapToneShelfDb (float knob01)
{
    return juce::jmap (knob01, 0.0f, 1.0f, -6.0f, 6.0f);
}

juce::var ParameterState::toVar() const
{
    auto* o = new juce::DynamicObject();
    o->setProperty ("version", 2);
    o->setProperty ("masteredPath", masteredPath);
    o->setProperty ("loopEnabled", loopEnabled);
    o->setProperty ("fadeInSec", fadeInSec);
    o->setProperty ("fadeOutSec", fadeOutSec);
    o->setProperty ("monoLow", monoLow);
    o->setProperty ("monoHigh", monoHigh);
    o->setProperty ("width", width);
    o->setProperty ("punch", punch);
    o->setProperty ("deChirp", deChirp);
    o->setProperty ("deEsser", deEsser);
    o->setProperty ("bass", bass);
    o->setProperty ("mud", mud);
    o->setProperty ("mid", mid);
    o->setProperty ("treble", treble);
    o->setProperty ("warmth", warmth);
    o->setProperty ("analogLife", analogLife);
    o->setProperty ("warmExciter", warmExciter);
    o->setProperty ("airExciter", airExciter);
    o->setProperty ("tapeHiss", tapeHiss);
    o->setProperty ("masterVolDb", masterVolDb);
    o->setProperty ("finalCharacter", (int) finalCharacter);
    o->setProperty ("lowCut", lowCut);
    o->setProperty ("hiCut", hiCut);
    juce::Array<juce::var> bands;
    for (const auto& band : eq)
    {
        auto* b = new juce::DynamicObject();
        b->setProperty ("enabled", band.enabled);
        b->setProperty ("type", band.type);
        b->setProperty ("frequencyHz", band.frequencyHz);
        b->setProperty ("gainDb", band.gainDb);
        b->setProperty ("q", band.q);
        bands.add (juce::var (b));
    }
    o->setProperty ("eq", juce::var (bands));
    o->setProperty ("loudnessPreset", (int) loudnessPreset);
    o->setProperty ("targetLufs", targetLufs);
    o->setProperty ("ceilingDb", ceilingDb);
    o->setProperty ("useTruePeak", useTruePeak);
    o->setProperty ("normalizeGainDb", normalizeGainDb);
    o->setProperty ("normalizeActive", normalizeActive);
    return juce::var (o);
}

void ParameterState::fromVar (const juce::var& v)
{
    if (auto* o = v.getDynamicObject())
    {
        // Always migrate onto known defaults. Version 1 presets did not carry
        // transport, EQ, preset identity, true-peak, or normalization state.
        // Leaving those fields at their defaults preserves their historical
        // load behaviour while making partial/corrupt presets deterministic.
        ParameterState migrated;
        auto setBool = [o] (const char* key, bool& destination)
        {
            if (o->hasProperty (key)) destination = (bool) o->getProperty (key);
        };
        auto setFloat = [o] (const char* key, float& destination)
        {
            if (o->hasProperty (key)) destination = (float) o->getProperty (key);
        };

        setBool ("masteredPath", migrated.masteredPath);
        setBool ("loopEnabled", migrated.loopEnabled);
        setFloat ("fadeInSec", migrated.fadeInSec);
        setFloat ("fadeOutSec", migrated.fadeOutSec);
        setFloat ("monoLow", migrated.monoLow);
        setFloat ("monoHigh", migrated.monoHigh);
        setFloat ("width", migrated.width);
        setFloat ("punch", migrated.punch);
        setFloat ("deChirp", migrated.deChirp);
        setFloat ("deEsser", migrated.deEsser);
        setFloat ("bass", migrated.bass);
        setFloat ("mud", migrated.mud);
        setFloat ("mid", migrated.mid);
        setFloat ("treble", migrated.treble);
        setBool ("lowCut", migrated.lowCut);
        setBool ("hiCut", migrated.hiCut);
        setFloat ("warmth", migrated.warmth);
        setFloat ("analogLife", migrated.analogLife);
        setFloat ("warmExciter", migrated.warmExciter);
        setFloat ("airExciter", migrated.airExciter);
        setFloat ("tapeHiss", migrated.tapeHiss);
        setFloat ("masterVolDb", migrated.masterVolDb);
        if (o->hasProperty ("finalCharacter"))
            migrated.finalCharacter = (FinalCharacter) (int) o->getProperty ("finalCharacter");

        if (auto* bands = o->getProperty ("eq").getArray())
        {
            const int count = juce::jmin ((int) migrated.eq.size(), bands->size());
            for (int index = 0; index < count; ++index)
                if (auto* b = bands->getReference (index).getDynamicObject())
                {
                    auto& band = migrated.eq[(size_t) index];
                    if (b->hasProperty ("enabled")) band.enabled = (bool) b->getProperty ("enabled");
                    if (b->hasProperty ("type")) band.type = (int) b->getProperty ("type");
                    if (b->hasProperty ("frequencyHz")) band.frequencyHz = (float) b->getProperty ("frequencyHz");
                    if (b->hasProperty ("gainDb")) band.gainDb = (float) b->getProperty ("gainDb");
                    if (b->hasProperty ("q")) band.q = (float) b->getProperty ("q");
                }
        }

        if (o->hasProperty ("loudnessPreset"))
            migrated.loudnessPreset = (LoudnessPreset) (int) o->getProperty ("loudnessPreset");
        setFloat ("targetLufs", migrated.targetLufs);
        setFloat ("ceilingDb", migrated.ceilingDb);
        setBool ("useTruePeak", migrated.useTruePeak);
        setFloat ("normalizeGainDb", migrated.normalizeGainDb);
        setBool ("normalizeActive", migrated.normalizeActive);
        *this = migrated;
    }
}

void UndoStack::push (const ParameterState& s)
{
    history.push_back (s);
    if ((int) history.size() > maxDepth)
        history.erase (history.begin());
    redoHistory.clear();
}

ParameterState UndoStack::undo (const ParameterState& current)
{
    if (! canUndo()) return current;
    redoHistory.push_back (current);
    auto previous = history.back();
    history.pop_back();
    return previous;
}

ParameterState UndoStack::redo (const ParameterState& current)
{
    if (! canRedo()) return current;
    history.push_back (current);
    auto next = redoHistory.back();
    redoHistory.pop_back();
    return next;
}

void UndoStack::clear()
{
    history.clear();
    redoHistory.clear();
}
