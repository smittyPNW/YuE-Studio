# Composition controls: what YuE2 actually accepts

Checked September 17, 2026 against official YuE2 code, native score documentation, and this app's source. “Understands” here means the interface represents a musical property; it is not proof of perfect acoustic compliance.

## Prose intent versus symbolic composition

| Control | Style/Lyrics request | Native ABC condition | Remaining limitation |
|---|---|---|---|
| Key | Write “E major” or “E minor” explicitly in Style. | `K:E` or `K:Em`, with notes and chords appropriate to that key. | Prose may be ignored. A key header alone does not transpose an existing melody or establish a tonal center. |
| Time signature | “4/4”, “3/4 waltz”, or “7/8 grouped 2+2+3” in Style. | `M:4/4`, `M:3/4`, `M:7/8`, with both voices filling the correct bars. | Meter is explicit; accent grouping, swing and feel still need musical realization. |
| BPM | “92 BPM, quarter-note pulse” in Style. | Native helper accepts integer `Q:1/4=92`. | A text target is not a lock. The checked score tempo is not an audio tempo measurement. |
| Chord progression | Describe a harmonic direction, or name a requested progression in Style. | Supported quoted chord symbols at actual note/rest onsets, e.g. `"Em"`, `"C"`, `"G"`, `"D"`. | Use the native vocabulary. The acoustic voicing and bass performance are generated. |
| Instrument identity | Specify instrument, register, role, technique and prominence in Style. | `Ins` holds one instrumental melody line; `Vocal` holds one vocal melody line. | These are not separate guitar, bass, drum and synth stems. Renaming a voice to Guitar is not a documented timbre control. |
| Solo | Empty `[Interlude]` or a cautious descriptive solo tag, plus Style location and character. | Write the solo notes in `Ins`, rest `Vocal`, retain harmony and align bars. | This conditions melody/rhythm, not guaranteed guitar timbre, exact waveform timing or identical surrounding audio. |
| Instrumental break | Empty section marker; say which instruments carry the passage and how vocals return. | Rest `Vocal` over the passage and put the intended instrumental line/rests in `Ins`. | Resting both melody voices does not necessarily mute all accompaniment. A full-band silent stop is not guaranteed. |
| Whole instrumental | Section-only Lyrics plus Studio's Instrumental option. | The fork silences the planned `Vocal` voice when no custom ABC is supplied. | With custom ABC, the worker skips automatic vocal silencing: ensure the supplied score already has the desired vocal rests. |

Use ordinary, explicit wording rather than invented controls such as `[key=E]`, `(BPM:92:1.5)`, “lock tempo”, or `[guitar:100%]`. Keep supported ABC in the app's **Custom score (ABC)** field, not in Lyrics or Style. `full` and `melody` accept external ABC; `off` does not. Supplying ABC bypasses planning, so YuE2 does not first repair a contradictory or incomplete score.

## A concrete text brief

> English-language atmospheric metal in E minor, 4/4, 92 BPM with a quarter-note pulse, resonant male baritone, syncopated distorted guitar riffs, prominent picked bass and spacious tom-driven drums. Restrained verses open into forceful melodic choruses. After the second chorus, an eight-bar lead-guitar solo develops the chorus motif over the same groove, with vocals resting, before returning to the bridge.

This is a valid musical request, not a claim that eight bars or 92 BPM are enforced. For “key of E,” distinguish E major from E minor; if choosing a default, make the choice explicit. For compound meter, identify the beat: 82 dotted-quarter beats per minute equals 123 quarter notes per minute. The bounded helper expects quarter-note tempo even in 6/8; do not silently substitute one pulse for the other.

## Minimal score-format example

This is only a two-bar instrumental-format example, not a finished song and not a score to paste over a full lyric:

```abc
X:1
T:
M:4/4
L:1/32
Q:1/4=92
V: Vocal clef=treble name="Vocal Melody" snm="Vocal"
V: Ins clef=treble name="Ins Melody" snm="Inst."
K:E
% interlude
V: Vocal
"E"z32|"B7"z32|
V: Ins
E8G8B8e8|f8e8d8B8|
```

In E major, the key signature makes these unmarked G, F and D notes sharp. An E-minor version needs `K:Em` and intentionally chosen notes/chords. Simply replacing `K:E` with `K:Em` changes accidentals; it is not a general transposition operation. Transposing an existing composition requires changing notes and chord roots while preserving the requested intervals and range.

The native two-voice format represents pitch, rhythm, rests, harmony and structure. Follow its limits: do not introduce generic ABC repeat signs, MIDI instrument directives, arbitrary extra voices, polyphonic stacks, or unsupported chord extensions and assume the shipped helper accepts them. Preserve a saved score and edit a copy. Validate its bar grid and interpreted notes before asking for audio.

## Validation evidence and limits

The official [`SongRequest` and prompt construction](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/src/yue2/protocol.py) expose `style`, `lyrics`, `cot`, `seed`, `abc`, `cfg_scale`, and `id`. There are no independent request fields for key, meter, BPM, instrument tracks, or solo start/end. The [`plan` implementation](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/src/yue2/pipeline.py) uses supplied ABC directly.

The official [ABC reference](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/abc-editing.md) specifies standard major/minor keys, fractional meters, a quarter-note tempo, chord vocabulary and the `Vocal`/`Ins` division. The official [solo workflow](https://github.com/multimodal-art-projection/YuE/blob/bd90e4ccae671d869b3ecaca6d7e893927d29442/skills/yue2-music/references/editing-workflows.md) uses this structure to condition a theme and saxophone solo. These primary sources support compositional control, not perfect timbre isolation.

The community app exposes [Custom score (ABC)](https://github.com/smittyPNW/YuE-Studio/blob/2a3b87cb81a1703b02e80acc073e9c9de725c77f/app/YuEStudio/Sources/YuEStudio/StudioInspector.swift) and passes it through the generation request. The [worker](https://github.com/smittyPNW/YuE-Studio/blob/2a3b87cb81a1703b02e80acc073e9c9de725c77f/tools/yue2_worker.py) only applies automatic vocal silencing when `instrumental` is set and custom `abc` is absent.

Published quality averages or selected demos do not provide success rates for “key of E,” 7/8, or an eight-bar guitar solo. Measure those claims separately. A source check proves the interface; score inspection proves the encoded composition; listening and musical analysis assess what the audio realizes.
