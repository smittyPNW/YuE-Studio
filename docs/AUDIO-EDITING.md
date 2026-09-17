# Edit existing recordings

YuE Studio's **Edit** workspace works on an existing recording. It does not call YuE2, generate performances, download another model, or require a cloud service.

Choose **Edit** from Create, choose **Edit recording** in Master, or open/drop a WAV, AIFF, FLAC, MP3, M4A, or CAF. Opened audio is copied into its own project under `~/Music/YuE Studio Edits`. A lossy input is decoded for editing; this cannot recover information lost in its original encoding.

## Select and listen

Click the waveform to position the playhead. Drag to select audio. Enter exact selection boundaries in seconds or samples. Zoom In, Zoom Out, Selection, and Fit control the view; a horizontal slider pans a zoomed waveform. At close zoom, Studio reads the actual samples, rather than enlarging a thumbnail.

Play auditions the selected passage; with no selection, it plays the song from the playhead. Loop repeats that audition range. Listening volume changes monitoring only. Clearing a selection restores whole-song audition.

## Arrange

- Split at the playhead. Cuts and splits use integer sample positions.
- Copy, cut, paste at the playhead, duplicate after the selection, delete and close the gap, or keep only the selection.
- Select arrangement clips and use their context menus to move them earlier or later. Markers follow their content when reordered.
- Add another recording as an alternate take. Its sample rate and channel count must match; Studio rejects incompatible takes rather than silently resampling.
- Select an arrangement clip, choose an overlap length, then **Crossfade to next clip**. A linear, complementary overlap shortens the timeline by the overlap length. It is not automatic beat matching.
- **Snap to quiet crossings** searches nearby left-channel zero crossings, minimizing combined channel amplitude. Audition the result: stereo channels may not share a zero crossing, and some edits still need a crossfade.

## Shape a selection

All processing tools require an explicit selection; use **All** for whole-song processing.

- Gain in dB and a dB-linear volume ramp.
- Linear fade in / fade out over the selection.
- Peak normalization to a chosen sample-peak target. This is gain only, not a limiter or LUFS target. Use Master for final loudness and true-peak control.
- Silence the selection, insert silence at the playhead, or reverse the selection.
- Invert polarity, swap stereo channels, or put the stereo average into both channels (mono fold-down).
- Remove the selected audio's mean DC offset per channel.
- Second-order Butterworth high-pass / low-pass filtering. Filters start with zero state at the selection boundary; audition boundaries and use fades when appropriate.
- Tiny click repair: linear interpolation across **1–128 samples**, using intact samples immediately on either side. It rejects longer selections and the file endpoints. It is not broadband denoising or automatic whole-track restoration.

## Inspect

Analyze the selection or entire recording for sample peak, RMS, mean DC, and samples at/above full scale. Frequency analysis is an averaged, Hann-windowed spectrum with logarithmic frequency display. Stereo channel powers are averaged so out-of-phase audio does not disappear from the measurement. It is an average spectrum, **not a time-frequency spectrogram**, LUFS measurement, or true-peak meter.

The editor does not silently limit float audio that exceeds full scale. Lower gain or master the recording before fixed-point delivery.

## Save, compare, deliver

Each successful edit atomically saves the project with up to 60 undo steps and a redo branch, including across app restarts. Use Undo/Redo to compare an operation; a new edit clears redo. Changes render into new 32-bit float PCM working assets. Unprocessed sections retain their decoded Float32 samples; editing a lossy source does not restore its missing fidelity. The original imported file remains separate and unchanged. No intermediate MP3/AAC encoding is used. PCM sources above 24-bit integer or 32-bit float are rejected rather than silently reduced to workspace precision.

The same rendered file is used for playback and whole-song export. Export the song or selection as WAV 24-bit, WAV 32-bit float, FLAC, AIFF, Apple Lossless, AAC, or MP3. Export refuses to overwrite existing files. **Master** sends a copied edited recording into a separate mastering session.

Heavy editor operations reserve the same workstation gate and operating-system file lock as generation and mastering. The generation worker exits before editing work starts. No additional AI model is involved.

Project folders retain source copies and effect assets needed by history. Back up the entire folder, including `edit-project.json`; the generated `preview-*.wav` file is disposable and rebuilt on opening. Projects support mono/stereo, 8–384 kHz, and at most four hours or 4.29 billion frames, whichever is smaller.

## Keyboard shortcuts

- Command–O: open a recording.
- Command–T: split at the playhead.
- Command–Shift–P: play/pause.
- Command–Option–Z: undo audio edit; add Shift for redo.
- Command–Option–A/C/X/V: select all, copy, cut, paste audio.

Audio editing shortcuts deliberately use Option for clipboard/history operations, keeping normal text editing shortcuts available in fields.

This release does not include stem separation, time stretching, pitch correction, plug-in hosting, or audio inpainting. Those require their own quality and integration validation. Ordinary edits do not invoke song generation.
