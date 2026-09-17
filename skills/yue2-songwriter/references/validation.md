# Validation and improvement protocol

This is a repeatable evaluation plan, not a claim that all prompts or audio have been tested. Skill frontmatter validation only checks packaging. A text review checks written behavior. Only separately authorized renders and listening can establish audible improvement.

## Text behavior cases

Run cases without loading models or changing the app. Keep outputs in a temporary evaluation folder, outside the published skill. Use original or expressly supplied lyrics rather than copyrighted lyric examples.

| Request | Observable acceptance criteria |
|---|---|
| “Write an allegorical country-metal song from the hook ‘Leave a light for the stranger.’” | Complete lyric; exact hook; verse two develops the story; country and metal have concrete compatible roles; no artist-name control tokens. |
| “Keep every lyric exactly the same; change only the style to atmospheric metal.” Supply the fixture below. | Lyrics compare equal to the fixture; no reggae carryover; title plus two paste fields. |
| “Add an eight-bar guitar solo after chorus two.” Supply a complete vocal song. | Intent appears at the correct structural point; no sung stage-direction prose; no guarantee of eight audible bars; whole-song Instrumental remains off. |
| “A wordless nocturnal piano and string piece, about three minutes.” | No sung words; nonempty section map; Instrumental note; approximate duration acknowledged. |
| “Use ‘Fuck You’ as the exact final line of each chorus.” | Hook retained verbatim, placed as requested, with complete repeated choruses; not silently censored. |
| “Keep these 400 words verbatim, whisper them slowly, add two long solos, and finish in 90 seconds.” Supply the lyric. | Conflict explicitly identified; no silent cutting or fabricated timing guarantee. |
| “Keep the melody and replace only seconds 60–68 with guitar.” No score supplied. | Does not promise waveform inpainting or melody preservation from prose; asks for needed source and separates score/regeneration work. |
| “Rewrite the last song, keep the same words.” No earlier lyric available. | Asks for the missing lyric; does not invent a remembered song. |
| “Give me two different styles for this lyric.” | Each option contains a complete pair; tells user to import one pair at a time, or follows an explicit style-only format request. |
| “E minor, 7/8 grouped 2+2+3, 92 quarter-note BPM, guitar solo after chorus two.” | All constraints preserved in Style; distinguishes requested groove/timbre from score-conditioned notes; no invented parameter syntax or promise of exact audible realization. |

Style-only preservation fixture:

```text
[Verse]
I left the gate unlatched tonight
The rain came through in silver lines
You set a cup beside the door
And asked for nothing more

[Chorus]
Leave a light for the stranger
Leave a chair beside the flame
If the road has worn your name away
We'll learn it all again

[Verse]
At dawn the empty cup was gone
A folded coat lay on the lawn
The gate still moved against the rain
I left it wide again

[Chorus]
Leave a light for the stranger
Leave a chair beside the flame
If the road has worn your name away
We'll learn it all again

[Outro]
The gate still moved against the rain
I left it wide again
```

For importer compatibility, use the app's actual `importPrompt` parsing logic on sample outputs. Assert the imported Style and Lyrics equal the intended fields, including Unicode. A nonempty section map must import; three blocks should fail rather than replace the existing composition. This is a format check, not an independent evaluation of writing quality.

## Checks actually performed for the September 17, 2026 revision

- Skill frontmatter validated with Codex's `quick_validate.py`.
- The repository's `abc_tools.py` was compared byte-for-byte with the official pinned source identified in the prompting guide; they matched.
- That helper parsed E major / 4/4 / quarter=92 and E minor / 7/8 / quarter=82 examples. Interpreted G was checked as G-sharp under E major and G-natural under E minor.
- An eight-bar 4/4 example was checked to contain 32 quarter-note beats, zero sounding Vocal notes and 32 Ins notes. This checks the symbolic break, not an audible guitar performance.
- The official `SongRequest` class was loaded without models: its real fields were inspected; invented `key`, `bpm`, `time_signature`, `negative_prompt`, and `instruments` arguments were rejected. External ABC was accepted by the request class for full/melody and rejected for off. Request acceptance is not musical validation, and melody-only scores still need chord removal.
- The current app's actual `importPrompt` method was copied into an isolated Swift harness with in-memory state. All five cases passed: locked lyric, section-only instrumental, Unicode/explicit hook, rejection of a third block, and rejection of empty lyrics. Rejected imports preserved the prior fields. This was a parsing check, not a live GUI test.

No independent behavioral comparison of old and new assistant outputs, audio render, or audio-quality benchmark was performed. The cases above remain a plan for broader behavioral evaluation, not an implied pass count. Do not describe this revision as maximally optimized or acoustically proven.

## Optional audio comparison

Only run this when audio generation is requested. Preserve full quality. Choose three representative briefs (for example, metal, a sparse ballad and a requested hybrid) and at least two seeds per brief if the user's resource budget permits. Compare old and revised Style with the same locked lyrics; evaluate lyric rewrites separately so the cause of any difference is interpretable. Run jobs sequentially.

Record every attempted candidate, exact requests, seed, planning mode, model/runtime/decoder revisions, quality settings, duration cap and truncation flags. Keep original audio and failures. Matching seeds improves traceability but does not isolate every acoustic variable when the prompt or runtime changes.

Audition full songs and the transitions into and out of solos. Compare at matched playback loudness without altering source masters. Shuffle A/B order and hide labels where practical. Record genre adherence, hook/word completeness, natural stress and breathing, vocal quality, arrangement development, solo execution, artifacts and ending. Note timestamps for failures and the listener's preference; allow ties.

Report the number of comparisons and all failures. Do not present a small personal listening test as a benchmark or describe a skill as universally optimal. Retain improvements supported by repeated observations; revise failures narrowly instead of accumulating universal rules from a single song.
