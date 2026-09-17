# Install, set up and build

## Download the app

Download the [Apple Silicon DMG](https://github.com/smittyPNW/YuE-Studio/releases/download/v0.4.0/YuE-Studio-0.4.0-Apple-Silicon.dmg), open it and drag YuE Studio to Applications. Launch the installed app, then eject the disk image. If another edition is installed, close it and preserve its bundle before replacing it. Your libraries are stored outside the application.

The download is Developer ID signed and Apple-notarized, with tickets stapled to both the app and disk image. It supports Apple Silicon and macOS 14+. The release includes a SHA-256 checksum file. The icon is bundled; pin the installed app in the Dock.

**For mastering only, no developer tools, Python or models are required.** Open the app, choose Master and import a recording. If you see a missing-generation-runtime message, dismiss it and switch to Master.

For song generation, complete the runtime setup below. A working existing runtime is used automatically. Model weights are not bundled with the download.

## Requirements for building or generation setup

- Apple Silicon Mac running macOS 14 or later.
- Xcode command-line tools (`xcode-select --install`) and Swift 5.9 or newer.
- CMake and Ninja for the mastering engine (`brew install cmake ninja`).
- `uv` for generation setup (`brew install uv` if you use Homebrew).
- Internet for dependency/model installation; enough disk for the several-GB model cache, runtime, build products, and song artifacts.
- This edition was exercised on an M4 Pro with 24 GB memory. Runtime and song length affect resource needs.

## Generation runtime

Run `bash scripts/setup-runtime.sh` from the repository root. It installs a Python 3.12 environment under `~/Library/Application Support/YuE Studio/env` and downloads the upstream YuE2 generation/listening models to the corresponding `models` folder. Read `MODEL_LICENSE` before using those weights.

If you installed the DMG and do not have a source checkout yet:

```bash
git clone --branch v0.4.0 https://github.com/smittyPNW/YuE-Studio.git
cd YuE-Studio
bash scripts/setup-runtime.sh
```

Install `uv` and the Xcode command-line tools first, as listed above. You do not need CMake, Ninja or an app rebuild when using the downloaded app. Quit and reopen YuE Studio after setup finishes.

An existing environment is not replaced. The script will say so and exit. Do not remove or repair a working runtime while the app is generating. Because the source is installed in editable mode, retain this checkout at the same location. Moving it requires reinstalling the package into the environment after all jobs finish.

If setup is interrupted after creating the environment, inspect the error. Rerun the failed dependency/download step with that environment, or move the incomplete environment aside before rerunning setup. Do not delete existing model caches or song folders as a troubleshooting shortcut.

The optional experimental Neural Engine bridge is not built by this setup script. The native UI uses full-quality GPU MLX with full composition planning. No lower-step shortcut is introduced.

## App bundle

```bash
bash custom/package-local.sh
```

Open `custom/dist/YuE Studio.app`. Copy it to Applications only after closing any running copy. If a different edition is installed, preserve that bundle before replacing it.

The icon is included in the signed bundle. A Finder alias to the installed application will keep the same icon; pin that installed application in the Dock rather than a transient build path.

This local build is ad-hoc signed by default. The separately published DMG is Developer ID signed and notarized. There is no automatic updater. To package your own disk image, see [distribution](DISTRIBUTION.md).

## Optional mastering

The default build compiles the included Studio Mastering engine and its 43-style catalog. CMake fetches the pinned JUCE revision; an optional `JUCE_ROOT` environment variable can point to an existing checkout. See `mastering/README.md`. Generation setup and model weights are not required for mastering-only use. Run the build step before the tests to generate the catalog and helper.

## Tests

```bash
swift test --package-path app/YuEStudio
python3 -m unittest discover -s custom/Tests -v
python3 scripts/check-public-tree.py
```

These interface/export/recovery checks do not download model weights or create songs. The full upstream model test suite requires its separate dependencies and resources.
