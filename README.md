<p align="center"><img src="custom/Assets/AppIcon.png" width="112" alt="YuE Studio’s orange tuning-fork icon"></p>
<h1 align="center">YuE Studio</h1>
<p align="center"><strong>A place for your songs.</strong><br>Local music creation for Apple Silicon. A native studio built around the music.</p>
<p align="center">
<a href="https://github.com/smittyPNW/YuE-Studio/actions/workflows/public-checks.yml"><img src="https://github.com/smittyPNW/YuE-Studio/actions/workflows/public-checks.yml/badge.svg" alt="Public checks"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-C34A12?logo=apple&logoColor=white" alt="macOS 14 or newer">
<img src="https://img.shields.io/badge/Apple_Silicon-native-30241C" alt="Native Apple Silicon">
<a href="LICENSE"><img src="https://img.shields.io/badge/public_code-Apache_2.0-EADFCC" alt="Public code: Apache 2.0"></a>
</p>

![YuE Studio campaign artwork](docs/marketing/hero.png)

**Give a song its words and musical direction. YuE2 turns them into a composition and full stereo audio, locally on your Mac.** Keep your lyrics, versions, playback, and exports together in a warm native SwiftUI workspace.

[Build & setup](docs/SETUP.md) · [Prompting, breaks & solos](docs/PROMPTING.md) · [Mastering integration](mastering/README.md) · [Releases](https://github.com/smittyPNW/YuE-Studio/releases)

> **Public edition:** song creation and the mastering interface are included. ReSoul’s proprietary DSP engine, Smart Master implementation, and style/repair catalog are **not** included. Mastering screenshots demonstrate a separately integrated private engine; they do not imply the public download can master audio out of the box. YuE2 model weights download separately and have their own [noncommercial license](MODEL_LICENSE).

## Make room for the music

- **Write with structure.** Separate musical direction from lyrics; jump between verse, chorus, bridge, and other section markers.
- **Keep the full render.** New songs use 32-step synthesis and full composition planning. The interface does not trade quality for speed.
- **Listen and keep versions.** A persistent player, waveform, favorites, and a song library keep your work close. Existing drafts can be compared with full renders.
- **Recover useful work.** Saved generation artifacts support recovery and full-quality rerendering. Failed jobs remain visible rather than disappearing.
- **Finish optionally.** With an authorized ReSoul engine installed, send a finished song to Master—or import a separate recording without generating anything.
- **One heavy job at a time.** Generation and mastering share an admission gate and file lock. The generation worker exits before mastering begins.
- **Keep your originals.** Mastering uses private source copies and separate rendered versions. Export refuses to replace existing audio.

## The actual app

### Create · dark

![Real YuE Studio song-creation screenshot](docs/screenshots/create-dark.png)

### Master · light

![Real YuE Studio mastering screenshot with private engine installed](docs/screenshots/master-light.png)

*The private integration shown above includes Smart Master, 43 starting styles, Before/After listening, and the iOS-inspired **Fix Stereo · More Bass · Clear Mids · Smooth Highs** buttons. Fixes update editable settings; they never silently process a song.*

<details><summary>Master · dark</summary>

![Real dark mastering screenshot](docs/screenshots/master-dark.png)

</details>

The screenshots are direct captures. Campaign images are imagegen artwork based on those captures and are not pixel-perfect UI documentation.

## Build it

Apple Silicon Mac, macOS 14+, Xcode command-line tools with Swift, and [uv](https://docs.astral.sh/uv/) for the optional generation runtime. Development and full-song validation used an **M4 Pro Mac mini with 24 GB unified memory**. Other machines and minimum-memory limits have not been validated for this edition.

```bash
git clone https://github.com/smittyPNW/YuE-Studio.git
cd YuE-Studio
bash scripts/setup-runtime.sh
bash custom/package-local.sh
```

The bundle is written to `custom/dist/YuE Studio.app`. Runtime setup downloads Python dependencies and several GB of model weights. An existing YuE runtime is left untouched. Keep this checkout in place because setup installs the Python package in editable mode. Read [the setup guide](docs/SETUP.md) before installing alongside another YuE Studio edition.

This release is source-first. Local builds are ad-hoc signed; no notarized installer is supplied. No model weights, private mastering binary, generated songs, or personal libraries are distributed.

## Mastering, by choice

The public app includes the integration UI and the [JSON process contract](mastering/README.md). An authorized engine can supply analysis, Smart Master recommendations, presets, and full offline rendering. Without it, Master explains what is missing; Create remains independent.

The private integration renders **24-bit WAV at the source sample rate**, supports input through file selection and drag-and-drop, and offers listening-level matching that does not alter the exported file. A mastering pass changes a mix’s sound; it is always optional.

## Quality and verification

The original custom edition was checked against a complete 218.36-second reference song: full-quality audio and latent bytes matched the preceding generation pipeline. The private ReSoul integration passed a full-song render, source-preservation, export, cancellation, and mutual-exclusion checks. Those are development observations, not speed or quality guarantees for every prompt or Mac.

The public tree has its own independent build and tests. See [verification and boundaries](docs/VERIFICATION.md). No new songs are generated by CI.

## Credits and licenses

This edition builds on **[Tony Weston’s YuE Studio Apple Silicon fork](https://github.com/tonywestonuk/YuE-Studio)**, based on **[YuE2 by M·A·P and collaborators](https://github.com/multimodal-art-projection/YuE)**. Their model, research, inference implementation, and acceleration work make this project possible. Original notices and upstream documentation are preserved.

- Public source: [Apache-2.0](LICENSE), with [third-party notices](THIRD_PARTY_NOTICES.md).
- YuE2 weights: [separate model license](MODEL_LICENSE); they are not covered by the code license.
- ReSoul: proprietary, separately supplied; no DSP or preset source is published here.
- YuE Studio and ReSoul names/artwork do not grant trademark rights or imply endorsement by upstream researchers.

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)
