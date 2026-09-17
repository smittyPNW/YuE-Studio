# Changelog

## 0.5.0 — Edit the recording

- Added a native Edit workspace between Create and Master with detailed stereo waveforms, exact sample/second selections, selection looping, arrangement clips, markers and saved projects.
- Reversible cut/copy/paste, split, duplicate, ripple delete, trim, reorder and alternate-take import; crossfades, gain/ramp/fade/normalization, silence, reverse, tiny click repair, DC removal, polarity, channel and filter tools.
- Sample-peak/RMS/DC analysis and an average frequency spectrum. Imported originals are preserved; preview and export share a float PCM render; undo/redo history survives reopening.
- Selection/whole-song export in all existing delivery formats and direct handoff between Create, Edit and Master.
- Audio processing uses the same exclusive resource gate and file lock as generation/mastering. No new song generation or model is required.
- See [editing](docs/AUDIO-EDITING.md) for exact behavior, limits and shortcuts. The app and Apple Silicon DMG are Developer ID signed, Apple-notarized and stapled.

## 0.4.1 — Audio delivery and comparison (local build)

- Both Create and Master export 24-bit WAV, 32-bit float WAV, lossless FLAC, 24-bit AIFF, Apple Lossless M4A, AAC M4A sharing copies, and 320 kbps MP3. Lossless delivery preserves the source sample rate; exports never overwrite existing audio.
- Fine Tune Your Master is a prominent, full-width control directly below the master style.
- Max Volume quick fix requests a measured, whole-song −9 LUFS pass with a −1 dBTP ceiling (or a stricter existing ceiling). The renderer retains its 3 dB peak-reduction budget, so dynamic songs may finish quieter. Render to hear the change; Undo restores prior settings.
- Before/After and saved-version changes preserve playback position and transport intent, apply level matching before playback resumes, and reject missing files instead of continuing the wrong track.
- Verified with 19 Swift tests, 15 Python tests, a complete existing-song mastering pass, and installed-app exports. No songs were generated. See [verification](docs/VERIFICATION.md#audio-delivery-update-041).

The 0.4.1 development build was ad-hoc signed locally; it was superseded by the signed and notarized 0.5.0 release above.

## 0.4.0 — Community mastering

- Added a Developer ID signed, notarized Apple Silicon DMG with a branded drag-to-Applications layout and getting-started guide. Generation models remain a separate setup.
- Studio Mastering engine, DSP and 43-style catalog now included under AGPL-3.0-only, with pinned JUCE build.
- HiFi quick fix: restrained bass weight, clarity and air, with non-stacking settings and Undo.
- Move song projects and mastering sessions to the Mac Trash; preserve external originals and exports, recover settings with Put Back.
- Refreshed app screenshots, repository description and community release documentation.
- Includes the song-queue JSON writer fix from main.

Earlier entries describe their historical release contents.


## 0.3.1 — Public preview

- Native orange/ivory and charcoal song workspace with persistent tuning-fork icon.
- Full-quality local YuE2 generation, library, structured lyric editing, player and export.
- Optional mastering interface and documented process contract; private ReSoul code and catalog excluded.
- iOS-inspired Quick fixes: Fix Stereo, More Bass, Clear Mids, Smooth Highs, with Undo.
- Generation/mastering mutual exclusion and source-preserving export.
- Source-first build instructions, public-tree checks, prompting guidance, screenshots and campaign artwork.

The private-engine development build and public source build have distinct contents. This release does not bundle model weights, ReSoul, or a notarized installer.
