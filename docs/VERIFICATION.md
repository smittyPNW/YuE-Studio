# Verification and release boundaries

## Community edition 0.4.0

Verified on an M4 Pro Mac mini with 24 GB unified memory:

- Clean public-engine build fetched the pinned JUCE source, built the native helper and SwiftUI app, and passed deep/strict ad-hoc signature verification.
- 15 Swift tests passed, including owned-directory boundaries, symlink/root rejection, a real subprocess lock, failed-move preservation, HiFi non-stacking, custom-EQ preservation, export collision checks and generation/mastering admission gates.
- 14 Python tests passed, including engine output, cancellation, source preservation, shared locks, parameter rejection, HiFi headroom, worker submission and saved-generation recovery.
- Installed-app checks: HiFi/Undo, explicit synthetic HiFi rendering, song Trash and mastering-session Trash, confirmation cancellation, clearing the deleted session's player, and preservation of the external imported file.
- Both synthetic deleted projects were present in the Mac Trash with recovery metadata. Native Finder Put Back supplies the file restoration; the app reads the returned metadata when refreshing/activating.
- Full-song HiFi validation preserved the input FLAC SHA-256 exactly and delivered 10,481,216 frames of stereo 48 kHz, 24-bit WAV (218.3587 seconds). From neutral controls, the example measured -14.0001 LUFS / -1.1200 dBTP. Applying HiFi over an existing Smart Master retained its other controls and measured about -14.0 LUFS / -2.2 dBTP. These are different settings, not contradictory measurements.
- Real light/dark screenshots show the installed community UI. Campaign art is identified separately.

The tests establish behavior, format and measured headroom, not a guarantee that HiFi improves every mix. Listen at matched level and retain the original when it sounds better.

## Preserved generation quality

New generation still requests full composition planning, GPU MLX, 32 synthesis steps and lossless output. This release does not change model precision or generation DSP. The earlier full-quality generation comparison used the complete 218.36-second reference recording and found identical FLAC and latent bytes with the custom worker. No fresh model generation was required for this UI/mastering release, and the full upstream model suite/fresh multi-GB runtime install were not rerun.

## Publication boundary

Studio Mastering source and presets are now intentionally included under AGPL-3.0-only. The commercial app's remaining source, private development history, personal libraries, audio, model weights, credentials and signing assets are excluded. A public-tree guard and a separate Gitleaks scan run before publishing. Automated scans are one check, not a mathematical guarantee of absence.

Local bundles are ad-hoc signed. No notarized installer or automatic updater is supplied.
