# Verification and release boundaries

## Public edition, 0.3.1

- Release Swift build and ad-hoc bundle signature verification passed on Apple Silicon.
- 10 Swift tests passed: library/input behavior, sparse interface patches, export preservation, settings/version identity, and both directions of generation/mastering exclusion.
- 6 Python worker-support tests passed: recoverable failures, saved artifacts, locks, and source preservation.
- Shell setup/build scripts passed syntax checks.
- The default public bundle contains no ReSoul helper, catalog, private DSP, JUCE binary or model weights.
- A separate public-tree guard checks private file paths, personal paths, key files, audio/model blobs, and oversized files. Gitleaks is run separately before publication.

Tests use synthetic interface fixtures. Private ReSoul preset/DSP regression tests and their inputs are intentionally not published. The full upstream model suite and fresh multi-GB runtime download were not rerun for this packaging change. Existing runtime setup exits without replacing it.

## Private development observations

The previous full-quality generation comparison used the complete 218.36-second reference recording and found identical FLAC and latent bytes with the custom worker. The private ReSoul integration passed 7 additional engine checks and a full-song offline render. Source audio was unchanged; exported WAV matched the rendered master. The measured example was approximately -14.1 LUFS and -2.1 dBTP at 48 kHz, 24-bit stereo.

The current Quick fixes row was checked in the installed app: More Bass changes editable settings and labels the saved audio as unchanged; Undo restores the previous settings. It never starts rendering. Actual light/dark screenshots are included separately from imagegen marketing artwork.

Those observations apply to the private development installation. The public repository does not contain the engine needed to reproduce its mastering results. No broad minimum-memory, speed, or best-in-class audio claim is made.
