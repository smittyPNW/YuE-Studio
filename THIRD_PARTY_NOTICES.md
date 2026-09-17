# Third-party code notices

The Oobleck VAE and SnakeBeta implementation in `modeling_vae.py` is derived
from stable-audio-tools commit `a6ae0cdf8b2eb1567a4b42ceadddec3712d99d45`.
The module hierarchy, weight normalization and activation equations preserve
the checkpoint's original inference implementation.

- Oobleck / stable-audio-tools: Copyright (c) 2023 Stability AI, MIT.
  Full text: `licenses/stable-audio-tools-MIT.txt`.
- SnakeBeta / BigVGAN: Copyright (c) 2022 NVIDIA CORPORATION, MIT.
  Full text: `licenses/SnakeBeta-NVIDIA-MIT.txt`.

These notices cover the identified source code and retain its original licenses.
The YuE2 model checkpoint weights are separately licensed under CC BY-NC 4.0;
see MODEL_LICENSE for the scope and full terms. This does not relicense third-party code.

## Studio Mastering community edition

The `mastering/` source and its JUCE-based executable use AGPL-3.0-only. See `mastering/LICENSE`, `mastering/NOTICE.md` and `mastering/JUCE-LICENSE.md`. This engine-specific license does not change the YuE2 model-weight license or the retained Apache-2.0 license of upstream generation/studio source.

## MP3 export

MP3 sharing copies use an encoding-only LAME 4.0 command-line helper from the [LAME Project](https://lame.sourceforge.io/), licensed under LGPL-2.0-or-later. The helper is built from the SHA-256-pinned upstream archive by `scripts/build-mp3-encoder.sh`, without a decoder or external runtime libraries. Its complete corresponding source archive, license texts and build script are included in `YuE Studio.app/Contents/Resources/LAME/`. The app invokes this separate executable and does not link LAME into the Swift application. The source archive is unmodified; compiler flags include the standard locale header for current macOS toolchains.
