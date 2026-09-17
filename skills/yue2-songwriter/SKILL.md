---
name: yue2-songwriter
description: Turn a song idea, hook, lyric fragment, or supplied draft into complete singable lyrics and a matching YuE2 musical style prompt. Use for YuE Studio songwriting, style-only revisions, instrumental briefs, and prompt feedback; does not render audio.
license: Apache-2.0
---

# YuE2 Songwriter

Produce complete lyrics and a coherent musical direction for YuE Studio's separate **Style** and **Lyrics** inputs. This skill writes text; it does not launch the app, download models, change render settings, or generate audio. Requests for rendering or score editing require a separate workflow.

Read [the prompting guide](references/prompting-guide.md) for the model contract, arrangement hints, and version-specific app settings. For skill maintenance or an explicitly requested evaluation, read [validation](references/validation.md). Distinguish documented interfaces, editorial heuristics, and heard results.

When a request names key, time signature, BPM, chord progression, exact solo length, or instrumental scheduling, also read [composition controls](references/composition-controls.md). Preserve these musical constraints explicitly in Style. Clarify major/minor or beat units when ambiguous and consequential. Distinguish a prose request from a checked score condition; do not promise that text locks the result. Explain the Custom score route when precision matters without silently turning a two-field songwriting request into score generation.

## Establish the writing contract

Infer a strong creative direction from even one hook; avoid a questionnaire. Ask only when a missing source or contradictory requirement prevents a faithful result. Honor language, genre, vocal character, clean/explicit preference, perspective, duration intent, and supplied structure.

Select the appropriate task:

- **New song:** develop the idea into a complete lyric and style.
- **Rewrite:** preserve exact hooks and other locked material; revise only the permitted content.
- **Style-only revision:** copy the supplied lyrics unchanged, including section order, punctuation, capitalization, and repeated lines. Do not rewrite them to fit the new genre without permission. If the referenced lyric is unavailable, ask for it rather than inventing a replacement.
- **Instrumental:** provide style and a section-only Lyrics block, with a note to enable Studio's instrumental setting. Do not add sung words or enable that setting for a single solo in a vocal song.
- **Feedback on a render:** separate what the user heard from the original intention. Revise the relevant prompt priorities; do not call a new draft acoustically improved before it is rendered and heard.

For a new song, choose a title, narrator, situation, central image, and emotional turn. Keep planning private. Translate artist references into musical traits rather than using band names as control tokens. Do not invent an accent, dialect, singer identity, or genre convention merely from a mood word.

## Write words that can be sung

Give verse two a development and the bridge a change of perspective or stakes. In allegory, let recurring objects and actions carry the meaning; avoid explaining the moral in every verse. Make the chorus memorable through a stable hook while its context changes.

Check spoken stress, breath points, consonant density, and vowels on likely sustained words. Compare corresponding lines by rhythm and stress, not only syllable count. Shorten congested phrases when rewriting is allowed; do not force rhymes or fill every beat. A final hook needs room to land, especially when it is shouted or explicit. If supplied lyrics are locked, flag a pacing conflict outside the paste fields instead of silently cutting words.

Choose the structure the song needs. Verse / pre-chorus / chorus / verse / pre-chorus / chorus / bridge / final chorus / outro is one useful form, not a mandatory template. Roughly 180–300 English words is an editorial starting range for some full songs, not a YuE2 limit or duration predictor. Slow delivery and instrumental passages need room; rap may support greater density. Prefer a complete short form over an unfinished long one when the user requests brevity.

Use plain demonstrated labels such as `[Intro]`, `[Verse]`, `[Pre-Chorus]`, `[Chorus]`, `[Interlude]`, `[Bridge]`, and `[Outro]`. Separate sections with blank lines. Write every repeated chorus in full, including the last. Never substitute “repeat chorus,” “x2,” or missing-content ellipses. Use `[Chorus]` for the last chorus unless preserving supplied labels.

Lyrics contain section labels and words intended to be sung. Empty intro/interlude/outro sections can express instrumental intent. See the guide for cautious use of solo labels. Put production, instrument roles, delivery, and ending instructions in Style. Parentheses may be sung; reserve them for desired ad-libs. Avoid timestamps, stage-direction prose, chord charts, invented weight syntax, and phoneme markup in the paste fields.

## Make musical priorities clear

Write one compact paragraph, usually 40–90 words as an editorial starting point. Lead with language and the dominant genre, then describe vocal register/texture, mood, groove or tempo target, a few defining instruments and their roles, arrangement contrast, and production texture.

Choose a dominant musical identity before blending influences. Express a secondary influence through a concrete role: for example, atmospheric metal guitars and drums with a restrained synthesizer pulse. A hybrid may use several influences when requested, but explain what each contributes rather than piling up genre names. Keep vocal aggression, guitar distortion, rhythmic feel, and production language consistent with the intended sound. Repeating a genre word or writing it in capitals is not a documented weighting control.

Prioritize the two or three defining audible traits over decorative adjectives. Use positive descriptions; a brief exclusion such as “no guitar” is ordinary intent, not a separate negative-prompt channel or a guarantee. Avoid conflicting tempos, competing lead singers, and generic “masterpiece / studio quality” claims. Describe verse-to-chorus contrast and a purposeful exit from any solo without prescribing a scene change on every line.

Tempo, meter, bar counts, exact stops, instrument omission, and vocal identity described in text are requests, not guaranteed outcomes. Precise composition work belongs in a separately validated native ABC workflow. Do not change generation quality, guidance, seeds, or sampling to compensate for a writing problem.

## Return the paste-ready result

Return a title, then exactly two fenced `text` blocks in this order:

1. **Style — paste into Style**, containing only musical direction.
2. **Lyrics — paste into Lyrics**, containing the complete lyric or nonempty instrumental section map.

Labels stay outside the blocks. Do not add a third fenced block, JSON wrapper, internal instructions, or an abbreviated chorus. For requested alternatives, give one complete pair per option and tell the user to import one pair at a time. Studio's current importer reads Style and Lyrics; the title is entered separately. For revisions, return both blocks unless the user explicitly requests only one field.

Add a short settings note only when useful and consistent with the actual app edition. Do not repeat an obsolete default or imply a duration cap determines the song's duration. Settings notes never initiate generation.

## Review before delivery

Check the source against the final lyric: exact anchors, allowed changes, section order, all repeats, and an intentional ending. Check that the musical direction supports the lyric's density and emotional arc. For a style-only edit, compare the lyric text directly rather than relying on recollection. Ensure instrumental instructions have not leaked into sung lines and that the two paste fields contain no commentary.

Treat an effective written brief as the result of this skill. Only claim musical improvements supported by actual listening or user feedback; a valid format or successful render is not proof of genre adherence, lyric completeness, or better sound.
