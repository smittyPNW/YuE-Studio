# YuE2 prompting: evidence and practical use

Reviewed September 17, 2026. This guide improves written briefs; it is not a benchmark showing superior audio. No audio was generated for this revision.

## Source scope

Official YuE2 source was checked at commit `bd90e4ccae671d869b3ecaca6d7e893927d29442`; the Hugging Face model at revision `14fc6c6f146441b1dd6363fcb2e01e82a6914cb7`. App behavior was checked against this community repository's source at `2a3b87cb81a1703b02e80acc073e9c9de725c77f`. These are evidence snapshots, not instructions to replace a user's installed models.

| Evidence | Consequence for the writing skill |
|---|---|
| [Official generation guide](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/docs/generation.md) | Style carries genre, instruments, voice, language and tempo; Lyrics carries sung words and section labels. |
| [Official short request](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/examples/song.json) | A concise musical description is valid. This single example does not establish an optimal word count or genre order. |
| [Full-song request](https://huggingface.co/m-a-p/YuE2-3B/blob/14fc6c6f146441b1dd6363fcb2e01e82a6914cb7/examples/tonight-awake.json) | Demonstrates plain section labels, repeated choruses written out, and an empty Interlude. Do not copy its lyric into original work. |
| [Generation and covers](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/generation-and-covers.md) | No dedicated negative prompt, reference singer, phoneme alignment, BPM field, or local audio-inpainting argument. |
| [Editing workflows](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/editing-workflows.md) | A solo label and matching style description express intent, not exact scheduling. |
| [ABC reference](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/abc-editing.md) | Instrumental melody belongs in `Ins`, with rests in `Vocal`; harmony remains in its native harmony-bearing voice. |
| [Listening and evaluation](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/listening-and-evaluation.md) | Score checks, ASR, listening and benchmark metrics support different claims. A finished file alone does not establish musical quality. |

Search results can still surface YuE-v1 advice. Its reference-audio workflow, tag conventions, segment limits and warnings about intro labels are not automatically YuE2 requirements. Likewise, advice for a third-party LoRA is not verified for the base model.

## Arrangement: breaks, guitar solos and returns

For a vocal song with a guitar solo, a conservative text-only approach is an empty `[Interlude]` placed at the desired structural point, plus a Style sentence such as:

> After the second chorus, an expressive electric-guitar lead develops the chorus motif over the established groove, then resolves into the vocal bridge.

Describe the player-like gesture (sustained bends, rhythmic motif, call and response), backing texture and return. “Eight bars” can express the intended scale; it does not lock duration. Do not add filler words under the instrumental tag or enable the whole-song Instrumental switch.

Upstream explicitly illustrates `[saxophone solo]`; a `[guitar solo]` label is a reasonable analogy, not a tested command or an officially enumerated control token. Use one clear marker, not a stack of tags. Preserve a user's intentional supplied label, explaining uncertainty if exact execution matters.

For exact bar placement, use a separate score-editing task: inspect a saved native ABC, put the solo melody in `Ins`, rest `Vocal` for the same time, preserve harmony and aligned bar lengths, and regenerate a new version. A validated score still requires listening to confirm realization. This is not an edit that preserves the surrounding waveform identically.

## Genre adherence and lyric fit

The following are writing heuristics, not experimentally proven YuE2 laws:

- State one main identity and give each secondary influence a role. For metal, a brief may prioritize distorted riffing, drum attack and vocal delivery; a synth influence can be restricted to a repeating bass pulse. A mood alone does not specify a genre.
- Match line density to the proposed phrasing. For an optional planning estimate, constant-tempo 4/4 gives seconds ≈ bars × 4 × 60 / BPM. Include intros, breaks and held notes. YuE may choose a different form or pace, so never present this as predicted render duration.
- Remove contradictions before adding more adjectives. A simultaneous request for whispered intimacy, continuous shouting, sparse accompaniment and a dense wall of sound needs section-specific priorities.
- Separate creative saturation or rasp from digital clipping. Writing “louder” or “mastered” is not a substitute for musical direction or a mastering workflow.
- If a result sounds like a different genre, record that observation. First verify which saved request produced it; the intended prompt alone cannot establish the actual genre or the cause of drift. Avoid claiming that one listening report proves a general model weakness.

For a style-only revision, exact lyric preservation takes precedence over these heuristics. If a slower groove would overcrowd locked words, point out the tradeoff without silently rewriting them.

## App edition and controls

The community Studio's [SongDraft](https://github.com/smittyPNW/YuE-Studio/blob/2a3b87cb81a1703b02e80acc073e9c9de725c77f/app/YuEStudio/Sources/YuEStudio/StudioLibrary.swift) defaults to **300 seconds**. Its [inspector](https://github.com/smittyPNW/YuE-Studio/blob/2a3b87cb81a1703b02e80acc073e9c9de725c77f/app/YuEStudio/Sources/YuEStudio/StudioInspector.swift) exposes **30–360 seconds**; [generation](https://github.com/smittyPNW/YuE-Studio/blob/2a3b87cb81a1703b02e80acc073e9c9de725c77f/app/YuEStudio/Sources/YuEStudio/SongWorkspace.swift) uses full planning, full quality and MLX. Do not tell users of this edition to fix a presumed 120-second default or look for a planning selector they may not have. Other editions can differ.

The cap gives headroom; it does not command an exact song length. A long lyric with multiple solos may still exceed it. Flag the issue, preserve the lyric, and let the user choose a shorter arrangement or a different workflow. Never silently cut the lyric or lower audio quality.

The model modes are `full` (melody and harmony plan), `melody` (melody plan), and `off` (no symbolic plan). They are different conditioning paths, not a simple quality ladder. Exact timing, melody and harmony work requires score inspection rather than a more elaborate prose prompt. Guidance and sampling changes are outside this writing skill.

The Apple Silicon [instrumental notes](https://github.com/tonywestonuk/YuE-Studio/blob/main/docs/apple-silicon.md) and community `tools/yue2_worker.py` document/implement vocal-plan silencing. For a wholly instrumental piece, supply a nonempty section map and enable the app's Instrumental setting. With custom ABC supplied, the worker skips its automatic vocal-silencing step; the supplied score must already contain the intended vocal rests. Text such as “no vocals” alone may still yield humming; even the setting should be checked by listening.

The community importer accepts exactly two nonempty fenced blocks, Style then Lyrics, and does not import the title. Supply plain `text` fences. Import alternatives one at a time. A section-only instrumental block remains nonempty and compatible.
