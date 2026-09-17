# Musical direction, lyrics, breaks and solos

YuE2’s documented inputs separate `style` from `lyrics`. Put genre, instruments, language, tempo and vocal character in musical direction; put singable words and section tags in lyrics. Keep production requests out of sung lines.

For a complete writing workflow, use the optional [Songwriter companion](SONGWRITER.md). For key, meter, tempo, chord progressions and precisely placed instrumental passages, read its [composition-control reference](../skills/yue2-songwriter/references/composition-controls.md). Text communicates intent; a validated Custom score (ABC) specifies the symbolic composition.

## Practical starting point

**Musical direction**

```text
English-language soulful roots rock, expressive male baritone, 104 BPM,
steady swinging backbeat, earthy electric guitars, warm Hammond organ,
melodic bass and live drums. Conversational verses build into a strong,
hopeful chorus. After the second chorus, an expressive electric-guitar
solo takes the lead over the established groove: sustained bends,
melodic phrasing, then a clear return to the vocal bridge.
```

**Structure around a solo** — this is a template excerpt, not a complete lyric:

```text
[Chorus]
Your sung chorus goes here

[guitar solo]

[Bridge]
Your sung bridge goes here
```

A standalone section tag leaves space for instrumental intent. Do not write “play guitar here” as an ordinary sung lyric. Specifying “eight bars” in the direction can express intent, but does not enforce duration.

## What upstream actually documents

The official [editing workflow](https://github.com/multimodal-art-projection/YuE/blob/main/skills/yue2-music/references/editing-workflows.md) gives a saxophone-theme/solo example. It describes a `[saxophone solo]` lyric tag plus matching style direction, while explicitly distinguishing these hints from precise scheduling. Using `[guitar solo]` is a practical adaptation of that example, not a tested guarantee for this release.

For precise composition, the native ABC format has **Vocal** and **Ins** voices. Put the instrumental melody in `Ins`, rest `Vocal` during the passage, preserve harmony in its native harmony-bearing voice, and keep both voices aligned. A planned bar count is a symbolic constraint; listen to the generated audio to check actual adherence.

Changing an existing score is a new generation/version. It is not waveform inpainting and will not guarantee identical audio outside the edited section. Keep the original and work on a copy.

Intro, interlude and outro intentions can also be described in the musical direction and indicated as sections. These are creative cues rather than a complete officially enumerated control-tag vocabulary. Avoid piling conflicting tags and timing instructions into a prompt.

## Whole-song instrumentals

The Apple Silicon fork includes an **Instrumental (no vocals)** setting. Its implementation silences the planned vocal voice; the fork’s documentation explains that “instrumental, no vocals” in text alone may still produce humming. Use that setting for an entirely instrumental piece, not for one guitar break inside a vocal song.

## References

- [Official generation guide](https://github.com/multimodal-art-projection/YuE/blob/main/docs/generation.md)
- [Official editing and solo guidance](https://github.com/multimodal-art-projection/YuE/blob/main/skills/yue2-music/references/editing-workflows.md)
- [Native ABC notation](https://github.com/multimodal-art-projection/YuE/blob/main/skills/yue2-music/references/abc-editing.md)
- [Apple Silicon fork: instrumentals](https://github.com/tonywestonuk/YuE-Studio/blob/main/docs/apple-silicon.md)

Checked against the published upstream guidance on September 16, 2026. This document separates upstream-described behavior from suggested prompts; no solo test generation is claimed.
