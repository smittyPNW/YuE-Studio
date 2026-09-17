# Verification and release boundaries

## Audio delivery update 0.4.1

Verified locally on the same M4 Pro Mac mini with 24 GB unified memory:

- Release build completed. Installed MP3 bundle passed deep/strict ad-hoc signature verification and reopened the existing library at the established app path, retaining its icon and bundle identifier. The previous Developer ID signed app bundle was backed up. Code-signing key access required a macOS prompt, so the final local MP3 build uses development signing; no keychain permissions were changed.
- 19 Swift tests passed. The audio-delivery matrix converts real 24-bit WAV and FLAC sources at 44.1 kHz stereo, 48 kHz mono, and 96 kHz stereo. Lossless outputs preserve decoded samples, rate, channels and frame count; AAC checks its codec and bounded encoding padding. Source/destination collision, invalid extension, damaged input and temporary-file cleanup are covered.
- AAC is explicitly a compressed sharing copy: 256 kbps stereo or 128 kbps mono. The app refuses source rates outside 8–48 kHz for AAC instead of silently resampling; use a lossless format for higher rates. MP3 is supplied by a bundled LAME 4.0 encoder at 320 kbps. MP3 retains 32, 44.1 and 48 kHz sources; other source rates convert to 48 kHz, as disclosed in its export dialog. The full source archive and build instructions ship with the encoder.
- Tests inspect actual AVPlayer assets, time and gain while switching Before/After, changing saved versions, rapidly toggling during playback, pausing during a pending seek, disabling level matching and recovering from a missing master. These are functional playback checks, not a subjective listening evaluation.
- 15 Python tests passed, including a new transient-rich Max Volume render, source preservation, 24-bit duration preservation and true-peak protection. Generation/mastering exclusion checks remain intact.
- A complete existing 294.198667-second recording was mastered with Max Volume. It moved from approximately −14 LUFS to −10.185 LUFS, with −1.117 dBTP measured true peak and −1.120 dBFS sample peak. Independent FFmpeg metering agreed at −10.2 LUFS / −1.1 dBTP. The output remained stereo, 48 kHz and 24-bit; the source SHA-256 was unchanged. The result stayed below the −9 LUFS target because peak reduction is limited to 3 dB. This is an observed result, not a guarantee for every source or later lossy encoding.
- Installed-app inspection verified the prominent Fine Tune control, expanded controls, Max Volume and Undo, and Before/After at the same 1:21 playback position. Both export menus expose all seven choices.
- Real save-dialog exports produced an Apple Lossless master and an AIFF generated-song copy. Both retained all 294.198667 seconds at stereo 48 kHz / 24-bit; independent decoded-PCM SHA-256 checks matched their respective sources exactly.
- Installed-app MP3 exports from both Master and Create produced complete 294.198667-second stereo 48 kHz files at 320,000 bits per second. A separate full-song encoder check retained approximately −14 LUFS / −2 dBTP, matching source loudness. The codec matrix also verifies decoded listening level and 96-to-48 kHz MP3 conversion. The bundled helper targets macOS 14 and links only Apple system libraries; no Homebrew runtime is needed.
- Public-tree guard and whitespace checks passed. No new songs were generated, model settings were unchanged, and existing session settings were restored after UI checks.

At the time of the 0.4.1 audit, the MP3 app was a local ad-hoc signed update and public downloads still referred to 0.4.0. Version 0.5.0 includes these changes in the signed, notarized installer described below. This audit does not claim testing on another Mac or a fresh model/runtime installation.

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

Full-quality generation requests full composition planning, GPU MLX, 32 synthesis steps and lossless output. This release does not change model precision or generation DSP. The earlier full-quality generation comparison used the complete 218.36-second reference recording and found identical FLAC and latent bytes with the custom worker. No fresh model generation was required for this UI/mastering release, and the full upstream model suite/fresh multi-GB runtime install were not rerun.

## Publication boundary

Studio Mastering source and presets are now intentionally included under AGPL-3.0-only. The commercial app's remaining source, private development history, personal libraries, audio, model weights, credentials and signing assets are excluded. A public-tree guard and a separate Gitleaks scan run before publishing. Automated scans are one check, not a mathematical guarantee of absence.

Local builds remain ad-hoc signed by default. The 0.4.0 downloadable app and DMG are separately Developer ID signed, Apple-notarized and stapled. Packaging uses the existing 0.4.0 app executable and helper, then applies distribution signatures. The mounted image passed strict app-signature and staple validation; Gatekeeper accepted both app and image. All seven mastering-engine tests passed against the signed helper inside the image. The copied app opened with the existing library and its Desktop alias/icon intact. The installer layout was inspected in Finder.

Generation runtime/models are still separate; no fresh runtime installation on a different Mac was performed. There is no automatic updater. See [distribution](DISTRIBUTION.md) for the repeatable packaging and verification steps.

## Native audio editing — 0.5.0

Local verification on Apple Silicon, 2026-09-17:

- 36 Swift tests passed with the existing-recording and native-view snapshot fixtures enabled; 15 Python tests passed. No song generation was used.
- GitHub Actions on macOS 14 passed the public-tree check, production app build, 15 Python tests, 36 Swift tests (two optional local-audio/snapshot fixtures skipped), and installer packaging. Explicit main-actor isolation keeps the editor views compatible with that older Swift toolchain.
- The final Developer ID signed, notarized app (0.5.0, build 20260917.2) was installed at the established application path. Strict signature, staple validation and Gatekeeper checks passed; the Desktop alias and Dock destination were preserved.
- Full 294.199-second stereo recording round trip: every decoded Float32 sample and the original source bytes were unchanged.
- Cut/split/paste/trim/reorder, ripple marker positions, saved undo/redo, reverse across block boundaries, fades, gain ramp, normalization, DC/silence/channel operations, click-repair bounds, crossfade duration, filter response and spectrum-channel handling were exercised with deterministic signals.
- Playback stopped at the selected frame boundary and looped within that range, using the native audio engine with monitoring muted for the test.
- A UI action in the installed build imported a preserved copy of an existing generated song. Its saved project and full-length preview were verified. The computer-use helper subsequently crashed (Studio remained running), so further native accessibility interaction checks were unavailable in this session.
- Light and dark Edit, updated Create and light Master images were captured directly from the production SwiftUI views in an offscreen native host with existing audio. These are native-view snapshots, not generated artwork; they do not substitute for a full pointer/keyboard interaction audit. The optional snapshot fixture suppresses backend startup and requires explicit environment variables.
- Public release gates additionally require source/secret scanning, Developer ID signing, Apple notarization/stapling, mounted-DMG verification, and matching public download checksums.

Run ordinary checks with `swift test --package-path app/YuEStudio`. To include an owned existing recording, set `YUE_EDITOR_TEST_AUDIO` to its path. To write native-view snapshots, also set `YUE_EDITOR_SNAPSHOT_DIR` to a local output directory. Audio and local paths are not committed.

Release 0.5.0 installer: Developer ID signing, app and DMG notarization/stapling, mounted-app signature checks, helper catalog execution, DMG verification and Gatekeeper assessments all passed. SHA-256: `ffb3baa32630b376deb70316ee53b8bcd34710780f2c849cb78ab450af18e95d`.


## Draft preview and rendering workflow — 0.5.1

- 39 Swift tests passed, including the optional real-recording and native-view fixtures; 17 Python tests passed. Migration keeps old workspaces at Full quality. Clear/Undo preserves Unicode, protects newly typed replacement text and does not carry a restore action into another composition.
- Worker admission tests confirm that Draft changes synthesis steps (8 versus 32), while the plan request, seed, lyrics, style and duration ceiling remain equal. Missing quality defaults to Full.
- An actual 12-second saved-token render compared the prior worker against Draft upgraded to Full. Final FLAC and latent files were byte-identical, the draft remained intact, and every original source hash matched. A follow-up Full render through the local-cache-first loading path produced the same bytes. See [measured timings](RENDER-MODES.md).
- Cache-hit, missing-file fallback and non-retry of corruption/error paths are covered without changing inference settings. Backend event tests cover the rendering activity assertion across queue admission, failure and idle.
- Light and dark Create snapshots use the production SwiftUI views in an isolated fixture library, including the Draft selector with the settings panel open. They are interface snapshots rather than a claim of a complete native accessibility interaction audit.

- Installed-app checks confirmed independent Style/Lyrics Clear and Undo clear, the Draft selection and synchronized settings, and restoration to Full quality. The prior input text was restored and no song was generated during these UI checks.
- App 0.5.1 (build 20260917.3) and its DMG passed Developer ID signing, Apple notarization/stapling, strict signature validation and Gatekeeper. The installed application path and icon were retained. Installer SHA-256: `f0bb4665433e9b734d95a3674a48277a16c7b9488bacd46d0c3c78cfcdd5db3c`.
